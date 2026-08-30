# frozen_string_literal: true

require "test_helper"
require "timeout"

# The log-streaming thread writes to the database, so it must be stopped by asking
# rather than by `Thread#kill` — an asynchronous kill inside ActiveRecord's
# connection setup can hand a half-configured adapter back to the pool and take out
# an unrelated thread with `undefined method 'key?' for nil` (zimmer#706).
# See AgentSessionJob::LogStream for the full mechanism.
class AgentSessionJobLogStreamingTest < ActiveSupport::TestCase
  # Reports the process as running forever, announces each poll so a test can block
  # until the streaming loop has gone round, and counts them so a test can prove
  # which flush wrote a row.
  class TickingProcessManager
    def initialize(ticks)
      @ticks = ticks
      @calls = Concurrent::AtomicFixnum.new(0)
    end

    def running?(_pid)
      @ticks << @calls.increment
      true
    end

    def calls
      @calls.value
    end
  end

  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    @tmpdir = Dir.mktmpdir("log_streaming_test")
    @stderr_log_path = File.join(@tmpdir, "claude_stderr.log")
  end

  teardown do
    FileUtils.rm_rf(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  test "stop! raises the flag but never kills a thread that overruns the timeout" do
    release = Queue.new
    flag = Concurrent::AtomicBoolean.new(false)
    # Stands in for a thread wedged inside ActiveRecord: it ignores the flag.
    thread = Thread.new { release.pop }
    stream = AgentSessionJob::LogStream.new(thread, flag, @session.id)

    assert_nil stream.stop!(timeout: 0.1),
      "stop! should give up waiting rather than escalate to Thread#kill"
    assert flag.true?, "stop! should have raised the stop flag"
    assert thread.alive?,
      "a thread that may be mid-reconnect! must be left to finish, never killed"
  ensure
    release&.<<(:done)
    thread&.join(2)
  end

  test "stop! lets the streaming thread finish its final drain and flush" do
    File.write(@stderr_log_path, "first streamed line\n")

    ticks = Queue.new
    process_manager = TickingProcessManager.new(ticks)
    job = AgentSessionJob.new(@session.id)
    job.process_manager = process_manager
    job.file_system = RealFileSystemAdapter.new

    stream = job.send(:start_log_streaming, @session, 4242, @stderr_log_path, @tmpdir)
    begin
      # Two polls means the first iteration has read the file and buffered the line.
      Timeout.timeout(10) { 2.times { ticks.pop } }
      assert_not_nil stream.stop!, "the streaming thread should stop when asked"
    ensure
      stream.stop!
    end

    assert_not stream.alive?

    # The line reached the database ONLY via the post-loop flush that a killed
    # thread would never have run — LogBuffer's periodic flush fires every
    # LOG_FLUSH_EVERY_ITERATIONS iterations and the loop never got that far. If a
    # slow machine let it, this fails loudly rather than passing for the wrong
    # reason.
    assert_operator process_manager.calls, :<, AgentSessionJob::LOG_FLUSH_EVERY_ITERATIONS,
      "the loop reached its periodic flush, so the assertion below no longer proves " \
      "the final flush is what wrote the row"
    assert @session.logs.where(level: "verbose", content: "first streamed line").exists?,
      "the buffered line should have been flushed by the thread's own final flush"
  end

  test "the thread stops reading a stderr file a replacement process has truncated" do
    File.write(@stderr_log_path, "a long first line from the first process\n")

    ticks = Queue.new
    job = AgentSessionJob.new(@session.id)
    job.process_manager = TickingProcessManager.new(ticks)
    job.file_system = RealFileSystemAdapter.new

    stream = job.send(:start_log_streaming, @session, 4242, @stderr_log_path, @tmpdir)
    begin
      # Two polls means the first iteration has read the file, so the thread now
      # holds a byte offset into it.
      Timeout.timeout(10) { 2.times { ticks.pop } }
      # A recovery respawn reopens the SAME deterministic path with mode "w". The
      # thread's offset now points past the end of a different process's output —
      # deliberately shorter here, which is what makes the check observable.
      File.write(@stderr_log_path, "second\n")
    ensure
      stream.stop!
    end

    contents = @session.logs.where(level: "verbose").pluck(:content)
    assert_includes contents, "a long first line from the first process"
    assert_empty contents.grep(/second/),
      "the thread must stop reading a file the replacement process has taken over " \
      "rather than emit a fragment of its output"
  end

  test "start_log_streaming hands back a stoppable handle rather than a raw thread" do
    ticks = Queue.new
    job = AgentSessionJob.new(@session.id)
    job.process_manager = TickingProcessManager.new(ticks)
    job.file_system = RealFileSystemAdapter.new

    stream = job.send(:start_log_streaming, @session, 4242, @stderr_log_path, @tmpdir)
    assert_kind_of AgentSessionJob::LogStream, stream
    Timeout.timeout(10) { ticks.pop }
    assert stream.alive?
    # Asserted rather than discarded: a thread left running past the end of a
    # transactional test would be querying a connection about to be unpinned.
    assert_not_nil stream.stop!, "the streaming thread should stop when asked"
  ensure
    stream&.stop!
  end
end

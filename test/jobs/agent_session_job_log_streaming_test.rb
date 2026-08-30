# frozen_string_literal: true

require "test_helper"
require "timeout"

# The log-streaming thread writes to the database, so it must be stopped by asking
# rather than by `Thread#kill` — an asynchronous kill inside ActiveRecord's
# connection setup can hand a half-configured adapter back to the pool and take out
# an unrelated thread with `undefined method 'key?' for nil` (zimmer#706).
# See AgentSessionJob::LogStream for the full mechanism.
class AgentSessionJobLogStreamingTest < ActiveSupport::TestCase
  # Reports the process as running forever, and announces each poll so a test can
  # block until the streaming loop has actually gone round.
  class TickingProcessManager
    def initialize(ticks)
      @ticks = ticks
    end

    def running?(_pid)
      @ticks << true
      true
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
    stream = AgentSessionJob::LogStream.new(thread, flag)

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
    job = AgentSessionJob.new(@session.id)
    job.process_manager = TickingProcessManager.new(ticks)
    job.file_system = RealFileSystemAdapter.new

    stream = job.send(:start_log_streaming, @session, 4242, @stderr_log_path, @tmpdir)
    begin
      # Two polls means the first iteration has read the file and buffered the
      # line. LogBuffer only flushes every fifth iteration, so at this point the
      # line exists ONLY in memory — it reaches the database solely via the
      # post-loop flush that a killed thread would never run.
      Timeout.timeout(10) { 2.times { ticks.pop } }
      assert_not_nil stream.stop!, "the streaming thread should stop when asked"
    ensure
      stream.stop!
    end

    assert_not stream.alive?
    assert @session.logs.where(level: "verbose", content: "first streamed line").exists?,
      "the buffered line should have been flushed by the thread's own final flush"
  end

  test "start_log_streaming hands back a stoppable handle rather than a raw thread" do
    ticks = Queue.new
    job = AgentSessionJob.new(@session.id)
    job.process_manager = TickingProcessManager.new(ticks)
    job.file_system = RealFileSystemAdapter.new

    stream = job.send(:start_log_streaming, @session, 4242, @stderr_log_path, @tmpdir)
    begin
      assert_kind_of AgentSessionJob::LogStream, stream
      Timeout.timeout(10) { ticks.pop }
      assert stream.alive?
    ensure
      stream.stop!
    end
  end
end

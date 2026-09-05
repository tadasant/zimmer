# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ClaudeCodeUpdateJobTest < ActiveJob::TestCase
  VERSION_CMD = [ "claude", "--version" ].freeze
  UPDATE_CMD = [ "claude", "update" ].freeze

  test "can be enqueued" do
    assert_enqueued_with(job: ClaudeCodeUpdateJob) do
      ClaudeCodeUpdateJob.perform_later
    end
  end

  test "uses the blocking maintenance queue" do
    job = ClaudeCodeUpdateJob.new
    assert_equal "maintenance", job.queue_name
  end

  test "performs without error" do
    stub_all_subprocesses

    assert_nothing_raised do
      ClaudeCodeUpdateJob.perform_now
    end
  end

  test "enqueues CliStatusRefreshJob after performing" do
    stub_all_subprocesses

    assert_enqueued_with(job: CliStatusRefreshJob) do
      ClaudeCodeUpdateJob.perform_now
    end
  end

  # Both bounds are real now (zimmer#908), so they are ENV-tunable and the test
  # pins the default rather than a literal repeated in three places.
  test "the update and version bounds have sane defaults" do
    assert_equal 600, ClaudeCodeUpdateJob::UPDATE_TIMEOUT
    assert_equal 30, ClaudeCodeUpdateJob::VERSION_TIMEOUT
  end

  test "both subprocesses run under BoundedSubprocess with their own bound" do
    stub_version("2.1.87 (Claude Code)")
    BoundedSubprocess.expects(:run)
      .with(UPDATE_CMD, timeout: ClaudeCodeUpdateJob::UPDATE_TIMEOUT)
      .returns([ "ok", "", ok_status ])

    ClaudeCodeUpdateJob.perform_now
  end

  test "logs the version transition when the update moves it" do
    BoundedSubprocess.stubs(:run)
      .with(VERSION_CMD, timeout: ClaudeCodeUpdateJob::VERSION_TIMEOUT)
      .returns([ "2.1.87 (Claude Code)", "", ok_status ])
      .then.returns([ "2.1.88 (Claude Code)", "", ok_status ])
    BoundedSubprocess.stubs(:run)
      .with(UPDATE_CMD, timeout: ClaudeCodeUpdateJob::UPDATE_TIMEOUT)
      .returns([ "", "", ok_status ])

    logs = capture_job_log { ClaudeCodeUpdateJob.perform_now }

    assert_includes logs, "Updated from 2.1.87 to 2.1.88"
  end

  # The bound is real now, so it can fire. `run_update`'s rescue has to hand back
  # the same 3-tuple `perform` destructures — a bare `nil` here would take
  # SubprocessStatus.describe_failure down with it.
  test "a watchdog kill on the update returns the tuple perform destructures" do
    stub_version("2.1.87 (Claude Code)")
    BoundedSubprocess.stubs(:run)
      .with(UPDATE_CMD, timeout: ClaudeCodeUpdateJob::UPDATE_TIMEOUT)
      .raises(BoundedSubprocess::TimeoutError, "command timed out (process group killed): claude update")

    logs = nil
    assert_nothing_raised { logs = capture_job_log { ClaudeCodeUpdateJob.perform_now } }

    assert_includes logs,
      "Update timed out after #{ClaudeCodeUpdateJob::UPDATE_TIMEOUT}s (process group killed)"
    # The composite line must not blame the #271 reaping race for a watchdog kill.
    assert_includes logs, "Update command failed"
    assert_includes logs, "process group SIGKILLed"
  end

  test "a missing claude binary is reported, not raised" do
    BoundedSubprocess.stubs(:run).raises(Errno::ENOENT, "claude")

    logs = nil
    assert_nothing_raised { logs = capture_job_log { ClaudeCodeUpdateJob.perform_now } }

    assert_includes logs, "claude binary not found in PATH"
  end

  # A hung `claude --version` used to be able to hold the maintenance thread for
  # as long as the child felt like it. Now it is killed at VERSION_TIMEOUT and the
  # job carries on with an unknown version.
  test "a watchdog kill on the version probe reports an unknown version" do
    BoundedSubprocess.stubs(:run)
      .with(VERSION_CMD, timeout: ClaudeCodeUpdateJob::VERSION_TIMEOUT)
      .raises(BoundedSubprocess::TimeoutError, "command timed out after 30s (process group killed)")
    BoundedSubprocess.stubs(:run)
      .with(UPDATE_CMD, timeout: ClaudeCodeUpdateJob::UPDATE_TIMEOUT)
      .returns([ "", "", ok_status ])

    logs = capture_job_log { ClaudeCodeUpdateJob.perform_now }

    assert_includes logs, "Starting update check (current: unknown)"
  end

  private

  def ok_status
    fake_process_status(exitstatus: 0)
  end

  def stub_version(output)
    BoundedSubprocess.stubs(:run)
      .with(VERSION_CMD, timeout: ClaudeCodeUpdateJob::VERSION_TIMEOUT)
      .returns([ output, "", ok_status ])
  end

  # `capture_log_entries` broadcasts to a sink rather than assigning Rails.logger,
  # which test/contracts/log_capture_contract_test.rb forbids.
  def capture_job_log(&block)
    capture_log_entries(&block).map(&:last).join("\n")
  end

  def stub_all_subprocesses
    BoundedSubprocess.stubs(:run).returns([ "2.1.87 (Claude Code)", "", ok_status ])
  end
end

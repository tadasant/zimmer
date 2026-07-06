# frozen_string_literal: true

require "test_helper"

# Tests for BoundedSubprocess — the shared wall-clock watchdog used by
# GitCloneService (git clone) and AirPrepareService (air prepare). These exercise
# the real popen3/process-group-kill machinery against tiny shell commands.
class BoundedSubprocessTest < ActiveSupport::TestCase
  test "kills a process that exceeds the timeout and raises TimeoutError" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(BoundedSubprocess::TimeoutError) do
      # `sleep 5` would block far past the 1s deadline; the watchdog must fire
      # and kill the process group long before 5s elapse.
      BoundedSubprocess.run([ "sleep", "5" ], timeout: 1)
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 3, "watchdog should kill the process well before the 5s sleep finishes"
    assert_includes error.message, "timed out after 1s"
    assert_includes error.message, "process group killed"
  end

  test "returns stdout, stderr, and a successful status for a fast command" do
    out, err, status = BoundedSubprocess.run(
      [ "sh", "-c", "printf hello; printf oops 1>&2" ], timeout: 10
    )

    assert_equal "hello", out
    assert_equal "oops", err
    assert status.success?
  end

  test "surfaces a non-zero exit status without raising" do
    out, _err, status = BoundedSubprocess.run([ "sh", "-c", "exit 7" ], timeout: 10)

    refute status.success?
    assert_equal 7, status.exitstatus
    assert_equal "", out
  end

  test "passes extra env to the child process" do
    out, _err, status = BoundedSubprocess.run(
      [ "sh", "-c", "printf %s \"$BOUNDED_SUBPROCESS_TEST_VAR\"" ],
      env: { "BOUNDED_SUBPROCESS_TEST_VAR" => "injected" },
      timeout: 10
    )

    assert status.success?
    assert_equal "injected", out
  end

  test "runs the child in the provided working directory" do
    Dir.mktmpdir do |dir|
      out, _err, status = BoundedSubprocess.run([ "pwd" ], cwd: dir, timeout: 10)

      assert status.success?
      # macOS symlinks /tmp → /private/tmp, so compare the realpath.
      assert_equal File.realpath(dir), File.realpath(out.strip)
    end
  end
end

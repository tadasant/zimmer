require "test_helper"

class SubprocessStatusTest < ActiveSupport::TestCase
  # A nil status is what Open3.capture3 returns when ZombieReaperJob reaps the child
  # before capture3's own waiter thread does. Every assertion below pins the rule that
  # such a status is a *failure*, never a success, and never raises.

  test "success? is true only for a status that exited zero" do
    assert SubprocessStatus.success?(fake_process_status(exitstatus: 0))
    assert_not SubprocessStatus.success?(fake_process_status(exitstatus: 1))
  end

  test "success? treats a nil status as a failure rather than raising" do
    assert_nothing_raised do
      assert_not SubprocessStatus.success?(nil)
    end
  end

  test "success? returns a boolean, not a truthy/nil tri-state" do
    # `status&.success?` would return nil here; callers that store or negate the value
    # should see false. Pins the difference from the bare-&. shape.
    assert_equal false, SubprocessStatus.success?(nil)
  end

  test "exit_code returns the exit status when known and nil when it is not" do
    assert_equal 8, SubprocessStatus.exit_code(fake_process_status(exitstatus: 8))

    assert_nothing_raised do
      assert_nil SubprocessStatus.exit_code(nil)
    end
  end

  test "exit_code comparison against a specific code is false for a nil status" do
    # The `gh pr checks` "exit 8 means pending" branch: an unknown exit code must not
    # be mistaken for the pending code.
    assert_not_equal 8, SubprocessStatus.exit_code(nil)
  end

  test "describe_failure names the exit code when it is known" do
    description = SubprocessStatus.describe_failure(fake_process_status(exitstatus: 3))

    assert_equal "exit status 3", description
  end

  test "describe_failure distinguishes a reaped child from a non-zero exit" do
    description = SubprocessStatus.describe_failure(nil)

    assert_equal SubprocessStatus::REAPED_DESCRIPTION, description
    assert_includes description, "reaped"
    # Must not read as an ordinary non-zero exit, which is the whole point.
    assert_not_includes description, "exit status"
  end

  test "describe_failure appends stderr when present" do
    assert_equal(
      "exit status 1: HTTP 502",
      SubprocessStatus.describe_failure(fake_process_status(exitstatus: 1), "HTTP 502\n")
    )
  end

  test "describe_failure keeps stderr on the reaped path where only the exit code is lost" do
    description = SubprocessStatus.describe_failure(nil, "  gh: connection reset  ")

    assert_equal "#{SubprocessStatus::REAPED_DESCRIPTION}: gh: connection reset", description
  end

  test "describe_failure omits blank stderr" do
    assert_equal SubprocessStatus::REAPED_DESCRIPTION, SubprocessStatus.describe_failure(nil, "   \n")
    assert_equal SubprocessStatus::REAPED_DESCRIPTION, SubprocessStatus.describe_failure(nil, nil)
  end

  test "describe_failure names the signal for a signaled child rather than a blank exit code" do
    # A real Process::Status for a signaled child has a nil #exitstatus, and
    # BoundedSubprocess SIGKILLs whole process groups on timeout — so interpolating
    # it blindly would print "exit status " on the very path this module exists to
    # keep readable.
    description = SubprocessStatus.describe_failure(fake_process_status(signal: 9), "killed")

    assert_equal "killed by signal 9: killed", description
    assert_not_includes description, "exit status"
    # Still a failure, and still not the reaped case.
    assert_not SubprocessStatus.success?(fake_process_status(signal: 9))
    assert_not_includes description, SubprocessStatus::REAPED_DESCRIPTION
  end

  test "a status double that reports an exit code is never asked for its signal" do
    # Existing suites stub Process::Status with bare Minitest::Mocks. Asking such a
    # double for #signaled? / #termsig on the ordinary non-zero path turns an
    # unrelated test red, so the signal branch must stay unreachable for them —
    # and #nil? is off limits for the same reason (Minitest::Mock undefines it).
    double = Minitest::Mock.new
    double.expect(:success?, false)
    double.expect(:exitstatus, 7)

    assert_not SubprocessStatus.success?(double)
    assert_equal "exit status 7", SubprocessStatus.describe_failure(double)
    assert_mock double
  end

  test "unknown? is true only when we never learned how the command ended" do
    # Retrying callers (GitCloneService, AirPrepareService) classify on this: a lost
    # race is transient, a real non-zero exit is not.
    assert SubprocessStatus.unknown?(nil)
    assert_not SubprocessStatus.unknown?(fake_process_status(exitstatus: 1))
    assert_not SubprocessStatus.unknown?(fake_process_status(exitstatus: 0))
  end
end

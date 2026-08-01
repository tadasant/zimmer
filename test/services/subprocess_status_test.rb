require "test_helper"

class SubprocessStatusTest < ActiveSupport::TestCase
  # A nil status is what Open3.capture3 returns when ZombieReaperJob reaps the child
  # before capture3's own waiter thread does. Every assertion below pins the rule that
  # such a status is a *failure*, never a success, and never raises.

  test "success? is true only for a status that exited zero" do
    assert SubprocessStatus.success?(status_double(success: true, exitstatus: 0))
    assert_not SubprocessStatus.success?(status_double(success: false, exitstatus: 1))
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
    assert_equal 8, SubprocessStatus.exit_code(status_double(success: false, exitstatus: 8))

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
    description = SubprocessStatus.describe_failure(status_double(success: false, exitstatus: 3))

    assert_equal "exit status 3", description
  end

  test "describe_failure distinguishes a reaped child from a non-zero exit" do
    description = SubprocessStatus.describe_failure(nil)

    assert_equal SubprocessStatus::REAPED_DESCRIPTION, description
    assert_includes description, "reaped"
    assert_not_includes description, "exit status "
  end

  test "describe_failure appends stderr when present" do
    assert_equal(
      "exit status 1: HTTP 502",
      SubprocessStatus.describe_failure(status_double(success: false, exitstatus: 1), "HTTP 502\n")
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

  private

  def status_double(success:, exitstatus:)
    Struct.new(:success, :exitstatus) do
      def success? = success
    end.new(success, exitstatus)
  end
end

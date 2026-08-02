# frozen_string_literal: true

# Helpers for creating mock Process::Status objects in tests.
# Provides utilities to create status objects with various exit conditions
# (success, failure, timeout, signal termination).
#
# These helpers eliminate the need to manually create Minitest::Mock objects
# for process status in every test.
#
# Usage:
#   test "process succeeds" do
#     status = mock_success_status
#     assert status.success?
#     assert_equal 0, status.exitstatus
#   end
module ProcessStatusHelpers
  # A faithful stand-in for Process::Status: answers every predicate the real
  # object answers, in the combinations the real object produces.
  #
  # Prefer this over a double that stubs only the one method the code under test
  # happens to call today. A real Process::Status never raises NoMethodError, so
  # a partial double turns any new read — a failure message that wants the exit
  # code, say — into a test failure that describes nothing about the code.
  #
  # @param exitstatus [Integer] exit code; ignored when signal is given, because
  #   a signaled child's real #exitstatus is nil
  # @param signal [Integer, nil] termsig for a child killed by a signal
  # @return [Struct] quacks like Process::Status
  def fake_process_status(exitstatus: 0, signal: nil)
    FakeProcessStatus.new(signal ? nil : exitstatus, signal)
  end

  FakeProcessStatus = Struct.new(:exitstatus, :termsig) do
    def success? = !exitstatus.nil? && exitstatus.zero?
    def signaled? = !termsig.nil?
  end

  # Create mock successful status
  # @param exit_code [Integer] Exit code (default: 0)
  # @return [Minitest::Mock] Mock status object that reports success
  #
  # Example:
  #   status = mock_success_status
  #   assert status.success?
  #   assert_equal 0, status.exitstatus
  def mock_success_status(exit_code: 0)
    status = Minitest::Mock.new
    status.expect(:success?, true)
    status.expect(:exitstatus, exit_code)
    status.expect(:signaled?, false)
    status
  end

  # Create mock failure status
  # @param exit_code [Integer] Exit code (default: 1)
  # @param signal [String, nil] Signal that terminated the process (optional)
  # @return [Minitest::Mock] Mock status object that reports failure
  #
  # Example:
  #   status = mock_failure_status(exit_code: 127)
  #   refute status.success?
  #   assert_equal 127, status.exitstatus
  def mock_failure_status(exit_code: 1, signal: nil)
    status = Minitest::Mock.new
    status.expect(:success?, false)
    status.expect(:exitstatus, exit_code)
    status.expect(:signaled?, !signal.nil?)
    status.expect(:termsig, signal) if signal
    status
  end

  # Create mock status for timeout
  # Returns a status with exit code 124 (common for timeout commands)
  # @return [Minitest::Mock] Mock status object indicating timeout
  #
  # Example:
  #   status = mock_timeout_status
  #   refute status.success?
  #   assert_equal 124, status.exitstatus
  def mock_timeout_status
    mock_failure_status(exit_code: 124)
  end

  # Create mock status for signal termination
  # @param signal [String] Signal name (default: "TERM")
  # @return [Minitest::Mock] Mock status object indicating signal termination
  #
  # Example:
  #   status = mock_signal_status(signal: "KILL")
  #   assert status.signaled?
  #   assert_equal "KILL", status.termsig
  def mock_signal_status(signal: "TERM")
    status = Minitest::Mock.new
    status.expect(:success?, false)
    status.expect(:exitstatus, nil)
    status.expect(:signaled?, true)
    status.expect(:termsig, signal)
    status
  end
end

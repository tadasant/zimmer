require "test_helper"

# Verifies the patch in
# config/initializers/action_cable_benign_socket_error_log_level.rb: a benign
# client disconnect surfaced through `Connection::Base#on_error` (a peer that
# closed the socket mid-write -> Errno::EPIPE "Broken pipe", ECONNRESET, etc.)
# must NOT emit an ERROR-level log. That single line trips the prod ERROR-logs
# alert even though nothing is broken. Every genuine, non-disconnect WebSocket
# error must still log at ERROR.
class ActionCableBenignSocketErrorLogLevelTest < ActiveSupport::TestCase
  # Records every logged message with its severity so we can assert on level,
  # not just text.
  class CapturingLogger
    attr_reader :messages

    def initialize
      @messages = []
    end

    %i[debug info warn error fatal unknown].each do |level|
      define_method(level) do |message = nil, &block|
        @messages << [ level, (message || block&.call).to_s ]
        true
      end
    end

    def errors
      messages.select { |level, _| level == :error }
    end

    def debugs
      messages.select { |level, _| level == :debug }
    end
  end

  # Minimal stand-in for ActionCable::Connection::Base that exercises only the
  # real #on_error the initializer overrides. #on_error depends solely on
  # #logger and the private #benign_socket_disconnect? added by the patch, so a
  # bare instance with a swapped-in logger is sufficient.
  def build_connection(logger)
    connection = ActionCable::Connection::Base.allocate
    connection.define_singleton_method(:logger) { logger }
    connection
  end

  def setup
    @logger = CapturingLogger.new
    @connection = build_connection(@logger)
  end

  test "broken pipe (client disconnect mid-write) logs at debug, not error" do
    @connection.on_error("Broken pipe")

    assert_empty @logger.errors, "expected no ERROR logs, got: #{@logger.messages.inspect}"
    assert @logger.debugs.any? { |_, msg| msg == "WebSocket error occurred: Broken pipe" },
      "expected a DEBUG log for the benign disconnect, got: #{@logger.messages.inspect}"
  end

  test "every benign Errno disconnect message is downgraded to debug" do
    ActionCable::Connection::Base::BENIGN_SOCKET_DISCONNECT_ERRNOS.each do |errno_class|
      logger = CapturingLogger.new
      connection = build_connection(logger)
      message = errno_class.new.message

      connection.on_error(message)

      assert_empty logger.errors,
        "#{errno_class} message #{message.inspect} should not log at ERROR, got: #{logger.messages.inspect}"
      assert logger.debugs.any? { |_, msg| msg.include?(message) },
        "#{errno_class} message #{message.inspect} should log at DEBUG, got: #{logger.messages.inspect}"
    end
  end

  test "non-Errno stream-teardown messages (EOFError / IOError) log at debug" do
    [ "end of file reached", "closed stream", "stream closed in another thread" ].each do |message|
      logger = CapturingLogger.new
      connection = build_connection(logger)

      connection.on_error(message)

      assert_empty logger.errors,
        "#{message.inspect} should not log at ERROR, got: #{logger.messages.inspect}"
      assert logger.debugs.any? { |_, msg| msg.include?(message) },
        "#{message.inspect} should log at DEBUG, got: #{logger.messages.inspect}"
    end
  end

  test "a message carrying an Errno suffix is still recognized as benign" do
    # Errno messages sometimes arrive as "Broken pipe - <syscall>"; substring
    # matching must still classify them as benign.
    @connection.on_error("Broken pipe - write(2)")

    assert_empty @logger.errors, "expected no ERROR logs, got: #{@logger.messages.inspect}"
    assert @logger.debugs.any? { |_, msg| msg.include?("Broken pipe - write(2)") },
      "expected a DEBUG log for the suffixed benign disconnect, got: #{@logger.messages.inspect}"
  end

  test "a genuine (non-disconnect) WebSocket error still logs at error" do
    @connection.on_error("Invalid frame payload data")

    assert @logger.errors.any? { |_, msg| msg == "WebSocket error occurred: Invalid frame payload data" },
      "genuine socket errors must still surface at ERROR, got: #{@logger.messages.inspect}"
    assert_empty @logger.debugs, "a genuine error must not hit the benign branch, got: #{@logger.messages.inspect}"
  end

  test "a nil message does not raise and logs at error" do
    @connection.on_error(nil)

    assert @logger.errors.any? { |_, msg| msg == "WebSocket error occurred: " },
      "a nil message must not raise and must default to ERROR, got: #{@logger.messages.inspect}"
  end
end

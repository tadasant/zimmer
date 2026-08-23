require "test_helper"

# Verifies the patch in
# config/initializers/action_cable_benign_socket_error_log_level.rb, which covers
# two benign client-disconnect races on `Connection::Base`:
#
#   * `#on_error` — a peer that closed the socket mid-write (Errno::EPIPE
#     "Broken pipe", ECONNRESET, etc.)
#   * `#dispatch_websocket_message` — an inbound frame dispatched off the async
#     worker pool after the socket had already closed
#
# Neither may emit an ERROR-level log: a single such line trips the critical
# `Zimmer backend logging errors (excludes staging)` alert even though nothing is
# broken. Every genuine, non-disconnect WebSocket error must still log at ERROR,
# and a live socket must still dispatch its frames.
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

  # --- #dispatch_websocket_message ------------------------------------------

  # Stand-in for the `websocket` a Connection::Base holds. Only #alive? matters
  # to the patched method.
  class FakeWebSocket
    def initialize(alive:)
      @alive = alive
    end

    def alive?
      @alive
    end
  end

  # Minimal stand-in exercising the real #dispatch_websocket_message the
  # initializer overrides. It depends on #websocket, #logger, #decode and
  # #handle_channel_command; we record the last two so both branches are
  # observable.
  def build_dispatch_connection(logger, alive:)
    connection = ActionCable::Connection::Base.allocate
    websocket = FakeWebSocket.new(alive: alive)
    handled = []
    decoded = []
    connection.define_singleton_method(:logger) { logger }
    connection.define_singleton_method(:websocket) { websocket }
    connection.define_singleton_method(:decode) do |message|
      decoded << message
      ActiveSupport::JSON.decode(message)
    end
    connection.define_singleton_method(:handle_channel_command) { |payload| handled << payload }
    connection.define_singleton_method(:handled) { handled }
    connection.define_singleton_method(:decoded) { decoded }
    connection
  end

  SUBSCRIBE_FRAME = { "command" => "subscribe", "identifier" => '{"channel":"Turbo::StreamsChannel"}' }.to_json

  test "a frame dispatched after the socket closed logs at debug, not error" do
    connection = build_dispatch_connection(@logger, alive: false)

    connection.dispatch_websocket_message(SUBSCRIBE_FRAME)

    assert_empty @logger.errors, "expected no ERROR logs, got: #{@logger.messages.inspect}"
    assert_empty connection.handled, "a closed socket must not dispatch the frame"
    assert @logger.debugs.any? { |_, msg| msg.include?("Ignoring message processed after the WebSocket was closed") },
      "expected a DEBUG log for the closed-socket frame, got: #{@logger.messages.inspect}"
  end

  test "the closed-socket log preserves upstream's message text verbatim" do
    # Upstream actioncable 8.1.3 emits a stray trailing `)` after the inspected
    # message. The patch changes the level only, so the text — parenthesis and
    # all — must match byte for byte.
    connection = build_dispatch_connection(@logger, alive: false)

    connection.dispatch_websocket_message(SUBSCRIBE_FRAME)

    expected = "Ignoring message processed after the WebSocket was closed: #{SUBSCRIBE_FRAME.inspect})"
    assert @logger.debugs.any? { |_, msg| msg == expected },
      "expected #{expected.inspect}, got: #{@logger.messages.inspect}"
  end

  test "a frame on a live socket is still decoded and dispatched, with no log" do
    connection = build_dispatch_connection(@logger, alive: true)

    connection.dispatch_websocket_message(SUBSCRIBE_FRAME)

    assert_equal [ SUBSCRIBE_FRAME ], connection.decoded, "the frame must be decoded on the happy path"
    assert_equal [ ActiveSupport::JSON.decode(SUBSCRIBE_FRAME) ], connection.handled,
      "a live socket must dispatch the decoded payload to handle_channel_command"
    assert_empty @logger.messages, "the happy path must not log at all, got: #{@logger.messages.inspect}"
  end

  # --- upstream drift guard --------------------------------------------------

  # Every ActionCable override in config/initializers/ reproduces a method body
  # copied from a specific actioncable release, and a test can only assert the
  # contract it knows about — it cannot notice that upstream grew a new side
  # effect on a path the override replaced. This guard is what turns that silent
  # risk into a red test on the upgrade PR, which is where the prompt to
  # re-read the upstream source belongs.
  test "the actioncable version the overrides were verified against has not moved" do
    assert_equal "8.1.3", ActionCable::VERSION::STRING,
      "actioncable was bumped — re-read the upstream bodies of " \
      "Connection::Base#on_error, Connection::Base#dispatch_websocket_message and " \
      "Connection::Subscriptions#remove, confirm the overrides in " \
      "config/initializers/action_cable_*.rb still reproduce them, then update this guard " \
      "and the version named in those files' comments."
  end
end

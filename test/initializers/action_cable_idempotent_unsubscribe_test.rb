require "test_helper"

# Verifies the patch in
# config/initializers/action_cable_idempotent_unsubscribe.rb: an `unsubscribe`
# command for a subscription the connection no longer holds must NOT emit an
# ERROR-level log (that benign client/server race was tripping the prod Grafana
# `Rails ERROR logs present` alert — see issue #4285). Every other command error
# must still log at ERROR.
class ActionCableIdempotentUnsubscribeTest < ActiveSupport::TestCase
  # Records every logged message with its severity so we can assert on level,
  # not just text. We capture all standard severities (Subscriptions itself
  # only uses info/debug/error) so an unexpected level never goes unrecorded.
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
  end

  # Minimal stand-in for ActionCable::Connection::Base. Subscriptions only needs
  # #logger and #rescue_with_handler. The real Base#rescue_with_handler returns
  # nil when no handler is registered, letting the error fall through to
  # execute_command's logger.error — we mirror that here.
  class FakeConnection
    attr_reader :logger

    def initialize(logger)
      @logger = logger
    end

    def rescue_with_handler(_error)
      nil
    end
  end

  # Stand-in for a channel subscription (an external collaborator of
  # Subscriptions). remove_subscription only calls #unsubscribe_from_channel and
  # #identifier on it, so we record the former and expose the latter.
  class FakeSubscription
    attr_reader :identifier

    def initialize(identifier)
      @identifier = identifier
      @unsubscribed = false
    end

    def unsubscribe_from_channel
      @unsubscribed = true
    end

    def unsubscribed?
      @unsubscribed
    end
  end

  def setup
    @logger = CapturingLogger.new
    @subscriptions = ActionCable::Connection::Subscriptions.new(FakeConnection.new(@logger))
  end

  def turbo_identifier
    { channel: "Turbo::StreamsChannel", signed_stream_name: "session_8025_enqueued_messages" }.to_json
  end

  test "unsubscribe for unknown subscription does not log at error" do
    @subscriptions.execute_command("command" => "unsubscribe", "identifier" => turbo_identifier)

    assert_empty @logger.errors, "expected no ERROR logs, got: #{@logger.errors.inspect}"
    refute @logger.messages.any? { |_, msg| msg.include?("Unable to find subscription") },
      "the raised RuntimeError must not be logged"
    assert @logger.messages.any? { |level, msg|
      level == :debug && msg.include?("Ignoring unsubscribe for unknown subscription")
    }, "expected a DEBUG log for the idempotent no-op, got: #{@logger.messages.inspect}"
  end

  test "unrecognized command still logs at error" do
    @subscriptions.execute_command("command" => "bogus", "identifier" => turbo_identifier)

    assert @logger.errors.any? { |_, msg| msg.include?("Received unrecognized command") },
      "expected an ERROR log for the unrecognized command, got: #{@logger.messages.inspect}"
  end

  test "unsubscribe for a present subscription still removes it and logs at info, not debug" do
    subscription = FakeSubscription.new(turbo_identifier)
    # Inject into the real subscriptions collection (private reader, mutable Hash)
    # so the genuine remove -> remove_subscription path runs against a live entry.
    @subscriptions.send(:subscriptions)[turbo_identifier] = subscription

    @subscriptions.execute_command("command" => "unsubscribe", "identifier" => turbo_identifier)

    assert subscription.unsubscribed?, "a present subscription must be unsubscribed from its channel"
    assert_empty @subscriptions.identifiers, "the subscription must be removed from the collection"
    assert_empty @logger.errors, "expected no ERROR logs, got: #{@logger.errors.inspect}"
    assert @logger.messages.any? { |level, msg|
      level == :info && msg.include?("Unsubscribing from channel")
    }, "expected the INFO log for a real unsubscribe, got: #{@logger.messages.inspect}"
    refute @logger.messages.any? { |_, msg| msg.include?("Ignoring unsubscribe for unknown subscription") },
      "a present subscription must not hit the idempotent no-op branch"
  end

  test "message command for unknown subscription still logs at error" do
    @subscriptions.execute_command(
      "command" => "message", "identifier" => turbo_identifier, "data" => "{}"
    )

    assert @logger.errors.any? { |_, msg| msg.include?("Unable to find subscription") },
      "non-unsubscribe find failures must still surface at ERROR, got: #{@logger.messages.inspect}"
  end
end

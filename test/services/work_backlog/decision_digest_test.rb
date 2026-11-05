# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The digest that carries owed decisions to their owner. The load-bearing rule is
# that a hold is renewed by a delivery and by nothing else, so anything that stops
# delivery lands on the lapse page. liveness_sweep_test.rb proves that last step.
class WorkBacklog::DecisionDigestTest < ActiveSupport::TestCase
  include WorkBacklogHelpers
  include ActiveSupport::Testing::TimeHelpers

  # A push channel that answers as WebPushService and ApnsService do, and records
  # what it was asked to send.
  class FakeChannel
    attr_reader :payloads

    def initialize(result = { sent: 1, failed: 0, expired: 0 }, &on_send)
      @result = result
      @on_send = on_send
      @payloads = []
    end

    def send_to_all(**payload)
      @payloads << payload
      @on_send&.call
      raise @result if @result.is_a?(Exception)

      @result
    end

    def as_channels = { fake: -> { self } }
  end

  setup do
    @dead_session = sessions(:archived)
    @dead_session.update_columns(archived_at: 3.days.ago)
    # `Rails.logger` writes here for the digest's own lines.
    @log = StringIO.new
  end

  test "a delivery carries each reason, renews the hold and records when it went out" do
    held = held_row(reason: "Tadas to pick #79/#141/#217")
    original_until = held.held_until
    channel = FakeChannel.new

    travel 3.days do
      result = deliver(channel)

      assert_equal :delivered, result.outcome
      assert_equal 1, result.renewed
      payload = channel.payloads.sole
      assert_equal "1 decision waiting on you", payload[:title]
      assert_includes payload[:body], "#{held.key}: Tadas to pick #79/#141/#217"
      assert_equal "/issues", payload[:url]
      assert_equal "decision_digest", payload[:data][:notification_type]

      held.reload
      assert_in_delta Time.current.to_f, held.hold_digested_at.to_f, 2
      assert_in_delta (Time.current + WorkBacklogItem::HOLD_DURATION).to_f, held.held_until.to_f, 2
      assert_operator held.held_until, :>, original_until
      assert_equal "Tadas to pick #79/#141/#217", held.hold_reason, "the decision itself is untouched"
      assert_includes WorkBacklogItem.awaiting_decision.pluck(:id), held.id
    end
  end

  test "a decision is re-sent every cadence until it is answered, and not between" do
    held_row
    channel = FakeChannel.new

    assert_equal :delivered, deliver(channel).outcome

    travel WorkBacklog::DecisionDigest::CADENCE - 2.hours do
      assert_equal :not_due, deliver(channel).outcome
    end
    assert_equal 1, channel.payloads.size

    travel WorkBacklog::DecisionDigest::CADENCE + 1.hour do
      assert_equal :delivered, deliver(channel).outcome
    end
    assert_equal 2, channel.payloads.size
  end

  test "a new hold goes out on the next tick and brings the rest of the list with it" do
    first = held_row(key: "zimmer#1", number: 1, reason: "the first decision")
    channel = FakeChannel.new
    deliver(channel)

    travel 1.day do
      second = held_row(key: "zimmer#2", number: 2, reason: "the second decision")

      assert_equal :delivered, deliver(channel).outcome
      assert_equal "2 decisions waiting on you", channel.payloads.last[:title]
      assert_includes channel.payloads.last[:body], "#{first.key}: the first decision"
      assert_includes channel.payloads.last[:body], "#{second.key}: the second decision"
    end
  end

  test "nothing owed sends nothing and is not a failure" do
    channel = FakeChannel.new

    assert_equal :nothing_owed, deliver(channel).outcome
    assert_empty channel.payloads
    assert_empty @log.string
  end

  test "a stranded row nobody has held is not in the digest" do
    row = started_row(key: "zimmer#5", number: 5)
    row.record_liveness!(WorkBacklogItem::LIVENESS_NO_PR)
    channel = FakeChannel.new

    assert_equal :nothing_owed, deliver(channel).outcome
    assert_includes WorkBacklogItem.stranded.pluck(:id), row.id
  end

  # Hard requirement: a failed delivery reaches a human. Each of these is a way
  # the digest could otherwise have failed silent.
  {
    "no device is subscribed" => { sent: 0, failed: 0, expired: 0 },
    "the channel is not configured" => { sent: 0, failed: 0, expired: 0, skipped: true },
    "every device refused" => { sent: 0, failed: 2, expired: 0 },
    "every subscription had expired" => { sent: 0, failed: 0, expired: 2 },
    "the channel raised" => RuntimeError.new("push service unreachable")
  }.each do |name, outcome|
    test "when #{name}, nothing is renewed and an ERROR says so" do
      held = held_row
      original_until = held.held_until

      result = deliver(FakeChannel.new(outcome))

      assert_equal :failed, result.outcome
      held.reload
      assert_equal original_until.to_i, held.held_until.to_i, "a hold is renewed by a delivery and nothing else"
      assert_nil held.hold_digested_at
      assert_match(/ERROR.*1 owed decision\(s\) reached no device/, @log.string)
      assert_match(/fake: /, @log.string, "the ERROR names what failed")
    end
  end

  test "a channel that cannot even be built is a failed channel, not a crash" do
    held = held_row

    result = deliver_through(broken: -> { raise ArgumentError, "bad key" })

    assert_equal :failed, result.outcome
    assert_nil held.reload.hold_digested_at
    assert_match(/ERROR.*broken: ArgumentError: bad key/, @log.string)
  end

  test "a failed delivery stays due, so the next tick tries again" do
    held_row
    assert_equal :failed, deliver(FakeChannel.new({ sent: 0, failed: 1, expired: 0 })).outcome

    travel 1.day do
      assert_equal :delivered, deliver(FakeChannel.new).outcome
    end
  end

  test "one channel reaching a device is a delivery, whatever the other did" do
    held = held_row
    dead = FakeChannel.new(RuntimeError.new("apns down"))

    result = deliver_through(ios: -> { dead }, web_push: -> { FakeChannel.new })

    assert_equal :delivered, result.outcome
    assert_not_nil held.reload.hold_digested_at
    assert_no_match(/ERROR/, @log.string)
  end

  test "the real channels with nobody subscribed count as nobody reached" do
    held_row
    assert_empty PushSubscription.all
    assert_empty ApnsDevice.deliverable

    WebpushConfig.stub(:configured?, true) do
      result = with_log { WorkBacklog::DecisionDigest.deliver! }

      assert_equal :failed, result.outcome
    end
    assert_match(/ERROR.*reached no device.*web_push.*ios/, @log.string)
  end

  # A renewal says the evidence was read and has not changed. Nobody read this
  # one, so it is delivered but its clock keeps running.
  test "a row whose evidence could not be read is delivered but not renewed" do
    held = held_row
    original_until = held.held_until
    held.record_liveness!(WorkBacklogItem::LIVENESS_UNKNOWN)
    channel = FakeChannel.new

    result = deliver(channel)

    assert_equal :delivered, result.outcome
    assert_equal 0, result.renewed
    assert_includes channel.payloads.sole[:body], held.key
    held.reload
    assert_equal original_until.to_i, held.held_until.to_i
    assert_not_nil held.hold_digested_at
  end

  # #1421 keeps a hold across a moving PR and takes the row off the Issues page.
  # The decision is still owed, so it stays delivered.
  test "a hold suspended by a moving open PR stays delivered and renewed" do
    held = held_row(state: WorkBacklogItem::LIVENESS_PR_MERGED_ISSUE_OPEN)
    held.record_liveness!(WorkBacklogItem::LIVENESS_PR_OPEN)
    original_until = held.held_until
    assert_not held.reload.awaiting_decision?
    channel = FakeChannel.new

    travel 1.day do
      assert_equal 1, deliver(channel).renewed
    end

    assert_includes channel.payloads.sole[:body], held.key
    assert_operator held.reload.held_until, :>, original_until
  end

  test "a hold voided while the push was on its way is not renewed back to life" do
    held = held_row
    channel = FakeChannel.new { held.record_liveness!(WorkBacklogItem::LIVENESS_ISSUE_CLOSED) }

    assert_equal 0, deliver(channel).renewed

    held.reload
    assert_nil held.held_until
    assert_nil held.hold_digested_at
  end

  test "a voided hold leaves no digest stamp for the next hold to inherit" do
    held = held_row
    deliver(FakeChannel.new)
    assert_not_nil held.reload.hold_digested_at

    held.record_liveness!(WorkBacklogItem::LIVENESS_PR_MERGED_ISSUE_OPEN)

    assert_nil held.reload.hold_digested_at
  end

  test "a lapsed hold is not renewed: that page belongs to the sweep" do
    held = held_row
    channel = FakeChannel.new

    travel WorkBacklogItem::HOLD_DURATION + 1.hour do
      assert_equal :nothing_owed, deliver(channel).outcome
      assert held.reload.hold_lapsed?
    end
    assert_empty channel.payloads
  end

  test "a long list stays inside a web push payload, however wide its characters" do
    25.times do |n|
      held_row(key: "zimmer##{n + 1}", number: n + 1, reason: "決定" * 900)
    end
    channel = FakeChannel.new

    deliver(channel)

    payload = channel.payloads.sole
    assert_equal "25 decisions waiting on you", payload[:title]
    assert_operator payload[:body].bytesize, :<=, WorkBacklog::DecisionDigest::BODY_MAX_BYTES
    assert payload[:body].valid_encoding?
    assert_equal 25, WorkBacklogItem.where.not(hold_digested_at: nil).count,
                 "a row cut from the text is still on the page the push opens"
  end

  test "a multi-line reason stays on its own line" do
    held = held_row(reason: "pick one\n\n  of these   three")
    channel = FakeChannel.new

    deliver(channel)

    assert_equal "#{held.key}: pick one of these three", channel.payloads.sole[:body]
  end

  # The margin the whole design leans on: one missed digest must not cost a page.
  test "a hold outlasts a missed digest" do
    assert_operator WorkBacklog::DecisionDigest::CADENCE * 2, :<=, WorkBacklogItem::HOLD_DURATION
  end

  test "the job delivers the digest" do
    calls = 0
    WorkBacklog::DecisionDigest.stub(:deliver!, -> { calls += 1 }) do
      WorkBacklogDecisionDigestJob.perform_now
    end

    assert_equal 1, calls
  end

  # Through the real WebPushService, with only the HTTP call replaced: what a phone
  # is actually handed, and that the service worker gets the link it opens.
  test "the push a browser receives names the decision and opens the Issues page" do
    held = held_row(reason: "Tadas to pick #79/#141/#217")
    PushSubscription.create!(endpoint: "https://push.example/1", p256dh_key: "p", auth_key: "a")
    sent = []
    client = Object.new
    client.define_singleton_method(:payload_send) { |**args| sent << args }

    result = WebpushConfig.stub(:configured?, true) do
      WebpushConfig.stub(:vapid_keys, { subject: "mailto:a@example.com" }) do
        deliver_through(web_push: -> { WebPushService.new(webpush_client: client) })
      end
    end

    assert_equal :delivered, result.outcome
    message = JSON.parse(sent.sole[:message])
    assert_equal "1 decision waiting on you", message["title"]
    assert_equal "#{held.key}: Tadas to pick #79/#141/#217", message["body"]
    assert_equal "/issues", message.dig("data", "url")
  end

  test "the iOS alert says what kind of thing happened and carries no reason to Apple" do
    held_row(reason: "seed the secret sk_live_123")
    bodies = []
    transport = Object.new
    transport.define_singleton_method(:post) do |_url, headers:, body:|
      bodies << body
      ApnsService::Transport::Response.new(status: 200, body: "")
    end
    ApnsDevice.create!(token: "a" * 64, environment: ApnsDevice::PRODUCTION, last_registered_at: Time.current)
    config = Struct.new(:configured?, :topic, :key_id, :team_id, :signing_key)
                   .new(true, "com.example", "KEY", "TEAM", OpenSSL::PKey::EC.generate("prime256v1"))

    result = deliver_through(ios: -> { ApnsService.new(config: config, transport: transport) })

    assert_equal :delivered, result.outcome
    assert_equal "Decisions are waiting on you.", JSON.parse(bodies.sole).dig("aps", "alert", "body")
    assert_no_match(/sk_live_123/, bodies.sole)
  end

  private

  def deliver(channel) = deliver_through(channel.as_channels)

  def deliver_through(channels)
    with_log { WorkBacklog::DecisionDigest.deliver!(channels: channels) }
  end

  def with_log(&block)
    Rails.stub(:logger, Logger.new(@log), &block)
  end

  def started_row(key: "zimmer#1", number: 1, **overrides)
    backlog_item(**{ key: key, issue_url: "https://github.com/tadasant/zimmer/issues/#{number}",
                     status: WorkBacklogItem::STARTED, started_session_id: @dead_session.id,
                     started_at: 20.days.ago }.merge(overrides))
  end

  def held_row(key: "zimmer#1", number: 1, reason: "pick one", state: WorkBacklogItem::LIVENESS_NO_PR)
    row = started_row(key: key, number: number)
    row.record_liveness!(state)
    row.hold_for_decision!(reason: reason, by: "fleet-maintenance")
    row
  end
end

# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# POST /webhooks/slack, driven through the whole stack: routing, the controller's checks, the
# delivery record, SlackEventJob, and Trigger#create_session! — with bodies signed the way Slack
# signs them, and bodies that are not.
class Webhooks::SlackControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include SlackWebhookTestHelpers

  setup { setup_slack_webhook }
  teardown { teardown_slack_webhook }

  # Slack's v0 scheme, computed independently of Webhooks::SlackSignature.
  def slack_signature(body, timestamp, secret: SIGNING_SECRET)
    "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}"
  end

  def deliver(payload, timestamp: Time.current.to_i, signature: :sign, secret: SIGNING_SECRET, headers: {})
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    signature = slack_signature(body, timestamp, secret: secret) if signature == :sign
    signed = { "X-Slack-Request-Timestamp" => timestamp&.to_s, "X-Slack-Signature" => signature }.compact

    perform_enqueued_jobs(only: SlackEventJob) do
      post webhooks_slack_path, params: body, headers: { "Content-Type" => "application/json" }.merge(signed).merge(headers)
    end
  end

  def new_message(ts = "1756500000.000100", event_id: nil, **attrs)
    event_callback(slack_event(ts: ts, **attrs), **{ event_id: event_id }.compact)
  end

  # --- the one that fires ---------------------------------------------------------

  test "a valid signed event for an enabled source creates exactly one session through the trigger" do
    assert_difference -> { Session.for_trigger(@trigger.id).count }, 1 do
      assert_difference -> { Session.count }, 1 do
        deliver(new_message(text: "deploy failed on main"))
      end
    end

    assert_response :ok
    assert_equal({ "ok" => true, "duplicate" => false }, response.parsed_body)

    session = Session.order(:id).last
    # Rendered from the trigger's own template, the way the poller renders it.
    assert_includes session.prompt, "There is a new message in Slack, channel #eng-ci."
    assert_includes session.prompt, "https://slack.example/archives/#{CHANNEL}/p1"

    claim = TriggerEventClaim.sole
    assert_equal [ @condition.id, "slack:#{CHANNEL}:1756500000.000100", "webhook", session.id ],
      [ claim.trigger_condition_id, claim.event_key, claim.claimed_via, claim.session_id ]
    assert_equal 1, WebhookDelivery.where(source: "slack").count
    assert_not_nil @condition.reload.last_triggered_at
  end

  test "an event no condition matches is acknowledged and fires nothing" do
    assert_no_difference -> { Session.count } do
      deliver(new_message(channel: "C_SOMEWHERE_ELSE"))
    end

    assert_response :ok
    assert_equal 1, WebhookDelivery.count
    assert_equal 0, TriggerEventClaim.count
  end

  # --- rejected before the payload is used for anything -----------------------------

  test "a body signed with the wrong secret is rejected and creates nothing" do
    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(new_message, secret: "somebody-elses-secret")
    end

    assert_response :unauthorized
    assert_no_enqueued_jobs only: SlackEventJob
  end

  test "a body altered after signing is rejected" do
    body = JSON.generate(new_message(text: "harmless"))
    timestamp = Time.current.to_i
    signature = slack_signature(body, timestamp)

    assert_no_difference -> { Session.count } do
      perform_enqueued_jobs(only: SlackEventJob) do
        post webhooks_slack_path, params: body.sub("harmless", "rm -rf"),
          headers: { "Content-Type" => "application/json", "X-Slack-Request-Timestamp" => timestamp.to_s, "X-Slack-Signature" => signature }
      end
    end

    assert_response :unauthorized
  end

  test "a request with no signature headers is rejected" do
    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(new_message, timestamp: nil, signature: nil)
    end

    assert_response :unauthorized
  end

  test "a correctly signed request with a stale timestamp is rejected" do
    stale = 10.minutes.ago.to_i

    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(new_message, timestamp: stale)
    end

    assert_response :unauthorized
  end

  test "a url_verification with a bad signature is rejected, not answered" do
    deliver({ "type" => "url_verification", "challenge" => "abc" }, secret: "wrong")

    assert_response :unauthorized
    assert_empty response.body
  end

  test "a correctly signed body that is not JSON is a bad request" do
    deliver("not json at all")

    assert_response :bad_request
    assert_equal 0, WebhookDelivery.count
  end

  test "Rails never parses the body into params, signed or not" do
    deliver(new_message(text: "parsed only after the signature checks out"))

    assert_response :ok
    assert_equal({}, request.request_parameters)

    ENV.delete("SLACK_TRIGGER_INGEST_MODE")
    deliver("{not json")

    assert_response :not_found
    assert_equal({}, request.request_parameters)
  end

  test "a body over the size cap is refused before it is verified" do
    Webhooks::SlackSignature.expects(:verify).never

    deliver(new_message(text: "x" * (Webhooks::BaseController::MAX_BODY_BYTES + 1)))

    assert_response 413
  end

  # --- inert ------------------------------------------------------------------------

  test "with no configuration the endpoint is inert: 404, even for a correctly signed event" do
    ENV.delete("SLACK_TRIGGER_INGEST_MODE")
    ENV.delete("SLACK_SIGNING_SECRET")

    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count }, -> { TriggerEventClaim.count } ] do
      deliver(new_message)
    end

    assert_response :not_found
  end

  test "switched on but with no signing secret, the endpoint is inert" do
    ENV.delete("SLACK_SIGNING_SECRET")

    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(new_message)
    end

    assert_response :not_found
  end

  test "a secret with the mode left at poll is inert" do
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "poll"

    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(new_message)
    end

    assert_response :not_found
  end

  test "`webhook` alone is not a mode, so it is inert too" do
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "webhook"

    assert_no_difference -> { Session.count } do
      deliver(new_message)
    end

    assert_response :not_found
  end

  # --- the handshake ------------------------------------------------------------------

  test "a signed url_verification echoes its challenge" do
    deliver({ "token" => "legacy", "challenge" => "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P", "type" => "url_verification" })

    assert_response :ok
    assert_equal({ "challenge" => "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P" }, response.parsed_body)
  end

  # --- dedup ------------------------------------------------------------------------

  test "a redelivered event with the same event_id creates one session, not two" do
    payload = new_message(event_id: "Ev0REDELIVER")

    assert_difference -> { Session.count }, 1 do
      deliver(payload)
      deliver(payload, headers: { "X-Slack-Retry-Num" => "1", "X-Slack-Retry-Reason" => "http_timeout" })
    end

    assert_response :ok
    assert_equal({ "ok" => true, "duplicate" => true }, response.parsed_body)
    assert_equal 1, WebhookDelivery.where(delivery_id: "Ev0REDELIVER").count
  end

  test "an app_mention delivery is acknowledged and ignored, so a mention fires once, from its message event" do
    event = slack_event(ts: "1756500000.000100")

    assert_difference -> { Session.count }, 1 do
      deliver(event_callback(event))
      deliver(event_callback(event.merge("type" => "app_mention").except("channel_type")))
    end

    assert_equal 2, WebhookDelivery.count
  end

  test "the same message seen by the webhook and then by the poller creates one session" do
    assert_difference -> { Session.count }, 1 do
      deliver(new_message("1756500000.000100", text: "deploy failed"))
      poll_channel([ polled_message(ts: "1756500000.000100", text: "deploy failed") ])
    end

    assert_equal "webhook", TriggerEventClaim.sole.claimed_via
    # The poller still owns its cursor, and advanced it past the message it skipped.
    assert_equal "1756500000.000100", @condition.reload.last_message_ts
  end

  test "the same message seen by the poller and then by the webhook creates one session" do
    assert_difference -> { Session.count }, 1 do
      poll_channel([ polled_message(ts: "1756500000.000100") ])
      deliver(new_message("1756500000.000100"))
    end

    assert_response :ok
    assert_equal "poll", TriggerEventClaim.sole.claimed_via
  end

  test "a message the webhook missed is still fired by the poller" do
    assert_difference -> { Session.count }, 2 do
      deliver(new_message("1756500000.000100", text: "first"))
      poll_channel([
        polled_message(ts: "1756500000.000100", text: "first"),
        polled_message(ts: "1756500900.000100", text: "the one Slack never delivered")
      ])
    end

    assert_equal %w[poll webhook], TriggerEventClaim.order(:claimed_via).pluck(:claimed_via)
    assert_includes Session.order(:id).last.prompt, "channel #eng-ci"
  end

  # --- coalescing (#979) ---------------------------------------------------------------

  test "a burst from one author across three deliveries is one session, with the rest folded into it" do
    assert_difference -> { Session.count }, 1 do
      deliver(new_message("1756500000.000100", user: "U_ALERTS", text: "[production] alert 1"))
      deliver(new_message("1756500000.600100", user: "U_ALERTS", text: "[production] alert 2"))
      deliver(new_message("1756500001.200100", user: "U_ALERTS", text: "[production] alert 3"))
    end

    session = Session.order(:id).last
    folded = session.enqueued_messages.order(:position)
    assert_equal 2, folded.size
    assert_includes folded.first.content, "[production] alert 2"
    assert_includes folded.last.content, "[production] alert 3"
    assert_includes folded.first.content, "folded it into this session"

    assert_equal [ session.id ], TriggerEventClaim.distinct.pluck(:session_id)
    assert_equal 3, TriggerEventClaim.count
  end

  test "a burst the webhook folded is not re-fired by the poller" do
    deliver(new_message("1756500000.000100", user: "U_ALERTS"))
    deliver(new_message("1756500000.600100", user: "U_ALERTS"))

    assert_no_difference -> { Session.count } do
      poll_channel([
        polled_message(ts: "1756500000.000100", user: "U_ALERTS"),
        polled_message(ts: "1756500000.600100", user: "U_ALERTS")
      ])
    end
  end

  test "two authors inside the window are two events and two sessions" do
    assert_difference -> { Session.count }, 2 do
      deliver(new_message("1756500000.000100", user: "U_ALICE"))
      deliver(new_message("1756500005.000100", user: "U_BOB"))
    end
  end

  test "one author further apart than the window is two sessions" do
    assert_difference -> { Session.count }, 2 do
      deliver(new_message("1756500000.000100", user: "U_ALERTS"))
      deliver(new_message("1756500300.000100", user: "U_ALERTS"))
    end
  end

  test "a window of 0 turns coalescing off for the webhook as it does for the poller" do
    @trigger.update!(coalesce_window_seconds: 0)

    assert_difference -> { Session.count }, 2 do
      deliver(new_message("1756500000.000100", user: "U_ALERTS"))
      deliver(new_message("1756500000.600100", user: "U_ALERTS"))
    end
  end

  # --- poll mode is unchanged ----------------------------------------------------------

  test "with Slack on poll, the poller claims nothing and fires exactly as before" do
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "poll"

    assert_difference -> { Session.count }, 1 do
      poll_channel([ polled_message(ts: "1756500000.000100") ])
    end

    assert_equal 0, TriggerEventClaim.count
  end
end

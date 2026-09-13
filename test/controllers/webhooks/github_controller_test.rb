# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# POST /webhooks/github, driven through the whole stack: routing, the controller's checks, the
# delivery record, GithubEventJob, and Trigger#create_session! — with bodies signed the way GitHub
# signs them, and bodies that are not.
class Webhooks::GithubControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include GithubWebhookTestHelpers

  setup { setup_github_webhook }
  teardown { teardown_github_webhook }

  # GitHub's scheme, computed independently of Webhooks::GithubSignature.
  def github_signature(body, secret: WEBHOOK_SECRET)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
  end

  def deliver(payload, event: "issues", delivery: SecureRandom.uuid, signature: :sign, secret: WEBHOOK_SECRET, headers: {})
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    signature = github_signature(body, secret: secret) if signature == :sign
    signed = { "X-GitHub-Event" => event, "X-GitHub-Delivery" => delivery, "X-Hub-Signature-256" => signature }.compact

    perform_enqueued_jobs(only: GithubEventJob) do
      post webhooks_github_path, params: body, headers: { "Content-Type" => "application/json" }.merge(signed).merge(headers)
    end
  end

  def opened(number = 4242, **attrs)
    issues_payload(github_issue(number: number, **attrs))
  end

  # --- the one that fires ---------------------------------------------------------

  test "a valid signed issues.opened for an enabled source creates exactly one session through the trigger" do
    assert_difference -> { Session.for_trigger(@trigger.id).count }, 1 do
      assert_difference -> { Session.count }, 1 do
        deliver(opened(4242, title: "Build is red on main"), delivery: "72d3162e-cc78-11e3-81ab-4c9367dc0958")
      end
    end

    assert_response :ok
    assert_equal({ "ok" => true, "duplicate" => false }, response.parsed_body)

    session = Session.order(:id).last
    # Rendered from the trigger's template, with the item appended the way the poller appends it.
    assert_includes session.prompt, "Triage this issue."
    assert_includes session.prompt, "## GitHub issue (issue opened)"
    assert_includes session.prompt, "- **URL:** https://github.com/tadasant/zimmer/issues/4242"
    assert_includes session.prompt, "Build is red on main"

    claim = TriggerEventClaim.sole
    assert_equal [ @condition.id, "github:tadasant/zimmer#4242:opened", "webhook", session.id ],
      [ claim.trigger_condition_id, claim.event_key, claim.claimed_via, claim.session_id ]

    delivery = WebhookDelivery.sole
    assert_equal [ "github", "72d3162e-cc78-11e3-81ab-4c9367dc0958", "issues.opened" ],
      [ delivery.source, delivery.delivery_id, delivery.event_type ]

    # The poller owns the cursor.
    assert_equal @cursor, @condition.reload.github_last_issue_at
  end

  test "an issue no condition watches is acknowledged, recorded, and fires nothing" do
    assert_no_difference -> { Session.count } do
      deliver(opened(1, repo: "someone/else"))
    end

    assert_response :ok
    assert_equal 1, WebhookDelivery.count
    assert_equal 0, TriggerEventClaim.count
  end

  # --- signatures -------------------------------------------------------------------

  test "a body signed with the wrong secret is rejected and creates nothing" do
    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(opened, secret: "not-the-secret")
    end

    assert_response :unauthorized
  end

  test "a body altered after signing is rejected" do
    body = JSON.generate(opened(title: "harmless"))
    signature = github_signature(body)

    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(body.sub("harmless", "tampered"), signature: signature)
    end

    assert_response :unauthorized
  end

  test "a request with no signature header is rejected" do
    assert_no_difference -> { WebhookDelivery.count } do
      deliver(opened, signature: nil)
    end

    assert_response :unauthorized
  end

  test "a correctly keyed sha1 signature is rejected, because only sha256 is accepted" do
    body = JSON.generate(opened)

    assert_no_difference -> { WebhookDelivery.count } do
      deliver(body, signature: "sha1=#{OpenSSL::HMAC.hexdigest('SHA1', WEBHOOK_SECRET, body)}")
    end

    assert_response :unauthorized
  end

  test "a signed request with no X-GitHub-Delivery is a bad request and records nothing" do
    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(opened, delivery: nil)
    end

    assert_response :bad_request
  end

  test "a correctly signed body that is not JSON is a bad request" do
    deliver("payload=%7B%22action%22%3A%22opened%22%7D")

    assert_response :bad_request
    assert_equal 0, WebhookDelivery.count
  end

  test "Rails never parses the body into params, signed or not" do
    deliver(opened(title: "parsed only after the signature checks out"))

    assert_response :ok
    assert_equal({}, request.request_parameters)

    ENV.delete("GITHUB_TRIGGER_INGEST_MODE")
    deliver("{not json")

    assert_response :not_found
    assert_equal({}, request.request_parameters)
  end

  test "a body over the size cap is refused before it is verified" do
    Webhooks::GithubSignature.expects(:verify).never

    deliver(opened(body: "x" * (Webhooks::BaseController::MAX_BODY_BYTES + 1)))

    assert_response 413
  end

  # --- inert ------------------------------------------------------------------------

  test "with no configuration the endpoint is inert: 404, even for a correctly signed delivery" do
    ENV.delete("GITHUB_TRIGGER_INGEST_MODE")
    ENV.delete("GITHUB_WEBHOOK_SECRET")

    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count }, -> { TriggerEventClaim.count } ] do
      deliver(opened)
    end

    assert_response :not_found
  end

  test "switched on but with no webhook secret, the endpoint is inert" do
    ENV.delete("GITHUB_WEBHOOK_SECRET")

    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(opened)
    end

    assert_response :not_found
  end

  test "a secret with the mode left at poll is inert" do
    ENV["GITHUB_TRIGGER_INGEST_MODE"] = "poll"

    assert_no_difference [ -> { Session.count }, -> { WebhookDelivery.count } ] do
      deliver(opened)
    end

    assert_response :not_found
  end

  test "`webhook` alone is not a mode, so it is inert too" do
    ENV["GITHUB_TRIGGER_INGEST_MODE"] = "webhook"

    assert_no_difference -> { Session.count } do
      deliver(opened)
    end

    assert_response :not_found
  end

  test "the Slack switch does not open the GitHub endpoint" do
    ENV_KEYS.each { |key| ENV.delete(key) }
    saved = %w[SLACK_TRIGGER_INGEST_MODE SLACK_SIGNING_SECRET].to_h { |key| [ key, ENV[key] ] }
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "webhook_with_poll_fallback"
    ENV["SLACK_SIGNING_SECRET"] = WEBHOOK_SECRET

    deliver(opened)

    assert_response :not_found
  ensure
    saved&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # --- events that fire nothing -------------------------------------------------------

  test "a signed ping is acknowledged and recorded, and fires nothing" do
    assert_no_difference -> { Session.count } do
      deliver({ "zen" => "Keep it logically awesome.", "hook_id" => 1 }, event: "ping")
    end

    assert_response :ok
    assert_equal "ping", WebhookDelivery.sole.event_type
  end

  test "an issues.labeled delivery is acknowledged and fires nothing" do
    assert_no_difference -> { Session.count } do
      deliver(issues_payload(github_issue(labels: [ "bug" ]), action: "labeled"))
    end

    assert_response :ok
    assert_equal "issues.labeled", WebhookDelivery.sole.event_type
  end

  test "a pull_request delivery is acknowledged and fires nothing" do
    assert_no_difference -> { Session.count } do
      deliver({ "action" => "opened", "pull_request" => { "number" => 9 } }, event: "pull_request")
    end

    assert_response :ok
  end

  # --- dedup ------------------------------------------------------------------------

  test "a redelivery with the same X-GitHub-Delivery creates one session, not two" do
    payload = opened

    assert_difference -> { Session.count }, 1 do
      deliver(payload, delivery: "redelivered-guid")
      deliver(payload, delivery: "redelivered-guid")
    end

    assert_response :ok
    assert_equal({ "ok" => true, "duplicate" => true }, response.parsed_body)
    assert_equal 1, WebhookDelivery.where(delivery_id: "redelivered-guid").count
  end

  # GitHub signs no timestamp, so a captured request stays correctly signed forever. Once its
  # delivery row has been pruned, the claim is what keeps it from firing the issue again.
  test "a replay after its delivery row has been pruned still fires nothing, because the issue is claimed" do
    payload = opened

    assert_difference -> { Session.count }, 1 do
      deliver(payload, delivery: "captured-guid")
      WebhookDelivery.delete_all
      deliver(payload, delivery: "captured-guid")
    end

    assert_response :ok
    assert_equal({ "ok" => true, "duplicate" => false }, response.parsed_body)
  end

  # --- webhook and poller together ------------------------------------------------------

  test "the same issue seen by the webhook and then by the poller creates one session" do
    issue = github_issue(number: 77)

    assert_difference -> { Session.count }, 1 do
      deliver(issues_payload(issue))
      poll_issues([ searched_issue(issue) ])
    end

    assert_equal "webhook", TriggerEventClaim.sole.claimed_via
    # The poller recorded the issue as fired and moved its cursor past it.
    @condition.reload
    assert_includes @condition.github_seen_issue_keys, "tadasant/zimmer#77"
    assert_equal issue["created_at"], @condition.github_last_issue_at
  end

  test "the same issue seen by the poller and then by the webhook creates one session" do
    issue = github_issue(number: 78)

    assert_difference -> { Session.count }, 1 do
      poll_issues([ searched_issue(issue) ])
      deliver(issues_payload(issue))
    end

    assert_response :ok
    assert_equal "poll", TriggerEventClaim.sole.claimed_via
  end

  test "an issue the webhook never received is still fired by the poller" do
    delivered = github_issue(number: 79, created_at: 5.minutes.ago.utc.iso8601)
    missed = github_issue(number: 80, title: "the one GitHub never delivered")

    assert_difference -> { Session.count }, 2 do
      deliver(issues_payload(delivered))
      poll_issues([ searched_issue(delivered), searched_issue(missed) ])
    end

    assert_equal [ [ "github:tadasant/zimmer#79:opened", "webhook" ], [ "github:tadasant/zimmer#80:opened", "poll" ] ],
      TriggerEventClaim.order(:event_key).pluck(:event_key, :claimed_via)
    assert_includes Session.order(:id).last.prompt, "the one GitHub never delivered"
  end

  test "with GitHub on poll, the poller claims nothing and fires exactly as before" do
    ENV["GITHUB_TRIGGER_INGEST_MODE"] = "poll"

    assert_difference -> { Session.count }, 1 do
      poll_issues([ searched_issue(github_issue(number: 81)) ])
    end

    assert_equal 0, TriggerEventClaim.count
  end

  # A repository hook and an organization hook both installed deliver one issue twice, under two
  # delivery ids. The delivery record cannot tell them apart; the claim does.
  test "one issue delivered under two different X-GitHub-Delivery ids creates one session" do
    payload = opened(4343)

    assert_difference -> { Session.count }, 1 do
      deliver(payload, delivery: "repo-hook-guid")
      deliver(payload, delivery: "org-hook-guid")
    end

    assert_response :ok
    assert_equal({ "ok" => true, "duplicate" => false }, response.parsed_body)
    assert_equal 2, WebhookDelivery.count
    assert_equal 1, TriggerEventClaim.count
  end
end

# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# `GITHUB_TRIGGER_INGEST_MODE=webhook_shadow`, end to end: a signed delivery through the real
# endpoint and GithubEventJob, the real poller, and the comparison over what both recorded. The
# webhook must fire nothing and claim nothing; the poller must fire exactly as it does on `poll`.
class Webhooks::GithubShadowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include GithubWebhookTestHelpers

  teardown { teardown_github_webhook }

  def deliver(payload, event:, delivery: SecureRandom.uuid)
    body = JSON.generate(payload)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', WEBHOOK_SECRET, body)}"
    perform_enqueued_jobs(only: GithubEventJob) do
      post webhooks_github_path, params: body, headers: {
        "Content-Type" => "application/json", "X-GitHub-Event" => event,
        "X-GitHub-Delivery" => delivery, "X-Hub-Signature-256" => signature
      }
    end
  end

  def comparison(now: Time.current)
    Webhooks::GithubShadowComparison.report(now: now)
  end

  # --- github_issue ---------------------------------------------------------------

  test "an issue delivery in shadow is accepted and recorded as would-fire, and fires and claims nothing" do
    setup_github_webhook(mode: "webhook_shadow")

    assert_no_difference -> { Session.count } do
      deliver(issues_payload(github_issue(number: 101)), event: "issues", delivery: "d-101")
    end

    assert_response :ok
    assert_equal 1, WebhookDelivery.where(source: "github", delivery_id: "d-101").count
    assert_equal 0, TriggerEventClaim.count
    observation = TriggerShadowObservation.sole
    assert_equal [ @condition.id, "github:tadasant/zimmer#101:opened", "webhook", "d-101" ],
      [ observation.trigger_condition_id, observation.event_key, observation.path, observation.delivery_id ]
  end

  test "the poller in shadow fires the issue exactly as on poll, claims nothing, and records the fire" do
    setup_github_webhook(mode: "webhook_shadow")
    issue = github_issue(number: 102)

    deliver(issues_payload(issue), event: "issues")
    travel 40.seconds do
      assert_difference -> { Session.count }, 1 do
        poll_issues([ searched_issue(issue) ])
      end
    end

    assert_equal 0, TriggerEventClaim.count
    assert_equal %w[poll webhook], TriggerShadowObservation.order(:path).pluck(:path)
    assert_includes @condition.reload.github_seen_issue_keys, "tadasant/zimmer#102"

    report = comparison(now: 1.minute.from_now)
    assert_equal({ matched: 1, webhook_only: 0, poll_only: 0, pending: 0 }, report[:totals])
    assert_in_delta 40, report[:latency][:median_seconds], 2
  end

  test "an issue no condition would fire records nothing" do
    setup_github_webhook(mode: "webhook_shadow")

    deliver(issues_payload(github_issue(number: 103, repo: "someone/else")), event: "issues")

    assert_equal 0, TriggerShadowObservation.count
  end

  test "an issue the webhook never delivered is poll-only once the grace has passed" do
    setup_github_webhook(mode: "webhook_shadow")

    poll_issues([ searched_issue(github_issue(number: 104)) ])

    assert_equal({ matched: 0, webhook_only: 0, poll_only: 0, pending: 1 }, comparison[:totals])
    assert_equal({ matched: 0, webhook_only: 0, poll_only: 1, pending: 0 }, comparison(now: 20.minutes.from_now)[:totals])
  end

  test "a retried webhook job records its delivery's verdict once" do
    setup_github_webhook(mode: "webhook_shadow")
    item = GithubEventJob.item_arguments(github_issue(number: 105))

    2.times { GithubEventJob.perform_now("d-105", GithubEventJob::ISSUE_OPENED, item) }

    assert_equal 1, TriggerShadowObservation.count
  end

  # --- github_label ---------------------------------------------------------------

  test "a label delivery in shadow records would-fire; the poller fires the merge gate once, unclaimed" do
    setup_github_label_webhook(mode: "webhook_shadow")
    pull_request = github_pull_request(number: 106, labels: [ LABEL ])

    assert_no_difference -> { Session.count } do
      deliver(pull_request_payload(pull_request, action: "labeled", label: LABEL), event: "pull_request")
    end
    assert_difference -> { Session.count }, 1 do
      poll_label_items([ searched_pull_request(pull_request) ])
    end

    assert_equal 0, TriggerEventClaim.count
    assert_equal [ [ "github:tadasant/zimmer#106:label:ready to merge", "poll" ], [ "github:tadasant/zimmer#106:label:ready to merge", "webhook" ] ],
      TriggerShadowObservation.order(:path).pluck(:event_key, :path)
    assert_equal 1, comparison(now: 1.minute.from_now)[:totals][:matched]
  end

  test "a label removed and added back is two events, and each pairs with its own poll" do
    setup_github_label_webhook(mode: "webhook_shadow")
    pull_request = github_pull_request(number: 107, labels: [ LABEL ])

    deliver(pull_request_payload(pull_request, action: "labeled", label: LABEL), event: "pull_request")
    poll_label_items([ searched_pull_request(pull_request) ])
    GithubTriggerPollCadence.new.removal_grace_misses.times { poll_label_items([]) }
    deliver(pull_request_payload(pull_request, action: "labeled", label: LABEL), event: "pull_request")

    report = comparison
    assert_equal({ matched: 1, webhook_only: 0, poll_only: 0, pending: 1 }, report[:totals])

    poll_label_items([ searched_pull_request(pull_request) ])
    assert_equal({ matched: 2, webhook_only: 0, poll_only: 0, pending: 0 }, comparison[:totals])
  end

  # --- the other modes are untouched ------------------------------------------------

  test "on poll the endpoint is inert and the poller records no shadow observation" do
    setup_github_webhook(mode: "poll")

    deliver(issues_payload(github_issue(number: 108)), event: "issues")
    assert_response :not_found

    assert_difference -> { Session.count }, 1 do
      poll_issues([ searched_issue(github_issue(number: 108)) ])
    end
    assert_equal 0, TriggerShadowObservation.count
    assert_equal 0, TriggerEventClaim.count
  end

  test "in webhook_with_poll_fallback the webhook fires and claims, and nothing is shadowed" do
    setup_github_webhook(mode: "webhook_with_poll_fallback")
    issue = github_issue(number: 109)

    assert_difference -> { Session.count }, 1 do
      deliver(issues_payload(issue), event: "issues")
      poll_issues([ searched_issue(issue) ])
    end

    assert_equal "webhook", TriggerEventClaim.sole.claimed_via
    assert_equal 0, TriggerShadowObservation.count
  end

  test "shadow without a webhook secret is inert" do
    setup_github_webhook(mode: "webhook_shadow", secret: nil)

    post webhooks_github_path, params: "{}", headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "ping", "X-GitHub-Delivery" => "x" }

    assert_response :not_found
  end
end

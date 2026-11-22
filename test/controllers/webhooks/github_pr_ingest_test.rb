# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# `GITHUB_PR_INGEST_MODE`, through the real endpoint: a verified delivery becomes GithubPrSignal
# rows for the per-session PR pollers, whatever the trigger side's mode is.
class Webhooks::GithubPrIngestTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include GithubWebhookTestHelpers

  teardown do
    teardown_github_webhook
    @saved_pr_mode.nil? ? ENV.delete("GITHUB_PR_INGEST_MODE") : ENV["GITHUB_PR_INGEST_MODE"] = @saved_pr_mode
  end

  def configure(trigger_mode:, pr_mode:)
    setup_github_webhook(mode: trigger_mode)
    @saved_pr_mode = ENV["GITHUB_PR_INGEST_MODE"]
    pr_mode ? ENV["GITHUB_PR_INGEST_MODE"] = pr_mode : ENV.delete("GITHUB_PR_INGEST_MODE")
  end

  def deliver(payload, event:, delivery: SecureRandom.uuid)
    body = JSON.generate(payload)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', WEBHOOK_SECRET, body)}"
    post webhooks_github_path, params: body, headers: {
      "Content-Type" => "application/json", "X-GitHub-Event" => event,
      "X-GitHub-Delivery" => delivery, "X-Hub-Signature-256" => signature
    }
  end

  def comment_payload(number)
    {
      "action" => "created",
      "issue" => { "number" => number, "pull_request" => { "url" => "https://api.github.com/repos/#{REPO}/pulls/#{number}" } },
      "comment" => { "id" => 1, "body" => "Looks good" },
      "repository" => { "full_name" => REPO, "default_branch" => "main" }
    }
  end

  test "with only the PR side listening, the endpoint accepts a delivery, signals it, and enqueues no trigger job" do
    configure(trigger_mode: nil, pr_mode: "webhook_with_poll_fallback")

    assert_no_enqueued_jobs(only: GithubEventJob) do
      deliver(pull_request_payload(github_pull_request(number: 12), action: "labeled", label: "ready to merge"), event: "pull_request")
    end

    assert_response :ok
    assert_equal 1, WebhookDelivery.count
    assert GithubPrSignal.exists?(subject: "https://github.com/#{REPO}/pull/12", kind: "status")
    assert GithubPrSignal.exists?(subject: REPO, kind: "delivery")
  end

  test "a comment on a pull request is signalled for the comment poller" do
    configure(trigger_mode: nil, pr_mode: "webhook_shadow")

    deliver(comment_payload(12), event: "issue_comment")

    assert_response :ok
    assert GithubPrSignal.exists?(subject: "https://github.com/#{REPO}/pull/12", kind: "comments")
  end

  test "a redelivery is not signalled again" do
    configure(trigger_mode: nil, pr_mode: "webhook_with_poll_fallback")
    deliver(comment_payload(12), event: "issue_comment", delivery: "same")
    GithubPrSignal.update_all(signaled_at: 1.hour.ago)

    deliver(comment_payload(12), event: "issue_comment", delivery: "same")

    assert_equal({ "ok" => true, "duplicate" => true }, response.parsed_body)
    assert_operator GithubPrSignal.maximum(:signaled_at), :<, 59.minutes.ago
  end

  test "with the PR side on poll, deliveries the trigger side accepts write no signal" do
    configure(trigger_mode: "webhook_with_poll_fallback", pr_mode: nil)

    deliver(comment_payload(12), event: "issue_comment")

    assert_response :ok
    assert_equal 0, GithubPrSignal.count
  end

  test "with both sides on poll the endpoint stays inert" do
    configure(trigger_mode: nil, pr_mode: "poll")

    deliver(comment_payload(12), event: "issue_comment")

    assert_response :not_found
    assert_equal 0, GithubPrSignal.count
  end
end

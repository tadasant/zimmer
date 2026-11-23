# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Github::PrWebhookIngestTest < ActiveSupport::TestCase
  REPO = { "full_name" => "Tadasant/Zimmer", "default_branch" => "main" }.freeze
  PR = "https://github.com/tadasant/zimmer/pull/7"

  setup do
    @saved_mode = ENV["GITHUB_PR_INGEST_MODE"]
    ENV["GITHUB_PR_INGEST_MODE"] = "webhook_with_poll_fallback"
  end

  teardown do
    @saved_mode.nil? ? ENV.delete("GITHUB_PR_INGEST_MODE") : ENV["GITHUB_PR_INGEST_MODE"] = @saved_mode
  end

  def signals(event, payload)
    Github::PrWebhookIngest.signals_for(event, { "repository" => REPO }.merge(payload))
  end

  def ref(url = PR)
    Github::PrRef.parse(url)
  end

  # ---- which deliveries signal what ----

  test "every delivery marks its repository live, lower-cased" do
    assert_equal [ %w[tadasant/zimmer delivery] ], signals("ping", {})
  end

  test "pull_request lifecycle and label actions signal status; a new head also signals merge_conflict" do
    assert_includes signals("pull_request", "action" => "closed", "pull_request" => { "number" => 7 }), [ PR, "status" ]
    assert_includes signals("pull_request", "action" => "labeled", "pull_request" => { "number" => 7 }), [ PR, "status" ]

    pushed = signals("pull_request", "action" => "synchronize", "pull_request" => { "number" => 7 })
    assert_includes pushed, [ PR, "status" ]
    assert_includes pushed, [ PR, "merge_conflict" ]

    assert_not_includes signals("pull_request", "action" => "edited", "pull_request" => { "number" => 7 }), [ PR, "merge_conflict" ]
    assert_includes signals("pull_request", "action" => "edited", "pull_request" => { "number" => 7 }, "changes" => { "base" => { "ref" => { "from" => "x" } } }),
      [ PR, "merge_conflict" ]
    assert_equal [ %w[tadasant/zimmer delivery] ], signals("pull_request", "action" => "review_requested", "pull_request" => { "number" => 7 })
  end

  test "a new comment on a pull request signals comments; one on an issue does not" do
    assert_includes signals("issue_comment", "action" => "created", "issue" => { "number" => 7, "pull_request" => { "url" => "x" } }), [ PR, "comments" ]
    assert_equal [ %w[tadasant/zimmer delivery] ], signals("issue_comment", "action" => "created", "issue" => { "number" => 7 })
    assert_includes signals("pull_request_review_comment", "action" => "created", "pull_request" => { "number" => 7 }), [ PR, "comments" ]
    assert_includes signals("pull_request_review", "action" => "submitted", "pull_request" => { "number" => 7 }), [ PR, "comments" ]
  end

  test "check suites and runs signal status for every pull request they name; commit statuses signal the repository" do
    suite = signals("check_suite", "action" => "completed", "check_suite" => { "pull_requests" => [ { "number" => 7 }, { "number" => 8 } ] })
    assert_includes suite, [ PR, "status" ]
    assert_includes suite, [ "https://github.com/tadasant/zimmer/pull/8", "status" ]
    assert_includes signals("check_run", "action" => "completed", "check_run" => { "pull_requests" => [ { "number" => 7 } ] }), [ PR, "status" ]
    assert_includes signals("status", "state" => "success"), %w[tadasant/zimmer ci]
  end

  test "only a push to the default branch signals base_push" do
    assert_includes signals("push", "ref" => "refs/heads/main"), %w[tadasant/zimmer base_push]
    assert_equal [ %w[tadasant/zimmer delivery] ], signals("push", "ref" => "refs/heads/feature")
  end

  test "a delivery with no usable repository or number signals nothing for it" do
    assert_empty Github::PrWebhookIngest.signals_for("pull_request", "action" => "closed", "pull_request" => { "number" => 7 })
    assert_equal [ %w[tadasant/zimmer delivery] ], signals("pull_request", "action" => "closed", "pull_request" => { "number" => "7/../x" })
  end

  test "record_delivery! keeps the newest time for a repeated signal" do
    payload = { "repository" => REPO, "action" => "completed", "check_run" => { "pull_requests" => [ { "number" => 7 } ] } }
    Github::PrWebhookIngest.record_delivery!("check_run", payload, at: 1.minute.ago)
    Github::PrWebhookIngest.record_delivery!("check_run", payload, at: 5.minutes.ago)

    assert_equal 2, GithubPrSignal.count
    assert_in_delta 1.minute.ago, GithubPrSignal.find_by(subject: PR, kind: "status").signaled_at, 2
  end

  # ---- the reading the pass takes ----

  test "in poll there is no reading at all" do
    ENV["GITHUB_PR_INGEST_MODE"] = "poll"
    GithubPrSignal.signal!([ %w[tadasant/zimmer delivery] ])

    assert_nil Github::PrWebhookIngest::Reading.for([ ref ])
  end

  test "a repository is covered only while it keeps delivering" do
    assert_not Github::PrWebhookIngest::Reading.for([ ref ]).driving?

    GithubPrSignal.signal!([ %w[tadasant/zimmer delivery] ], at: Github::PrWebhookIngest::COVERAGE_WINDOW.ago - 1.minute)
    assert_not Github::PrWebhookIngest::Reading.for([ ref ]).covered?

    GithubPrSignal.signal!([ %w[tadasant/zimmer delivery] ])
    assert Github::PrWebhookIngest::Reading.for([ ref ]).driving?

    # Every repository has to be covered, not just one.
    assert_not Github::PrWebhookIngest::Reading.for([ ref, ref("https://github.com/pulsemcp/air/pull/1") ]).covered?
  end

  test "a deployment still carrying the removed shadow mode is driven, as webhook_with_poll_fallback is" do
    ENV["GITHUB_PR_INGEST_MODE"] = "webhook_shadow"
    Rails.logger.stubs(:warn)
    GithubPrSignal.signal!([ %w[tadasant/zimmer delivery] ])

    assert Github::PrWebhookIngest::Reading.for([ ref ]).driving?
  end

  test "a signal is pending only when it is newer than the stamp it concerns" do
    GithubPrSignal.signal!([ [ PR, "status" ], [ PR, "comments" ] ], at: 2.minutes.ago)
    reading = Github::PrWebhookIngest::Reading.for([ ref ])

    assert reading.status_pending?(3.minutes.ago)
    assert_not reading.status_pending?(1.minute.ago)
    assert reading.comments_pending?(nil)
    assert_not reading.merge_conflict_pending?(nil)
  end

  test "a repository-wide CI signal makes every tracked pull request's status pending" do
    GithubPrSignal.signal!([ %w[tadasant/zimmer ci] ], at: 1.minute.ago)

    assert Github::PrWebhookIngest::Reading.for([ ref ]).status_pending?(2.minutes.ago)
  end

  test "a repository-wide CI signal does not re-read a PR whose CI already finished" do
    GithubPrSignal.signal!([ %w[tadasant/zimmer ci] ], at: 1.minute.ago)

    assert_not Github::PrWebhookIngest::Reading.for([ ref ], ci_statuses: { PR => "pass" }).status_pending?(2.minutes.ago)
    assert Github::PrWebhookIngest::Reading.for([ ref ], ci_statuses: { PR => "pending" }).status_pending?(2.minutes.ago)
  end

  test "a comment signal waits out CommentEvaluator's attribution grace unless asked for unsettled ones" do
    GithubPrSignal.signal!([ [ PR, "comments" ] ], at: 10.seconds.ago)
    reading = Github::PrWebhookIngest::Reading.for([ ref ])

    assert_not reading.comments_pending?(1.minute.ago)
    assert reading.comments_pending?(1.minute.ago, settled: false)
  end

  test "a merge-conflict signal waits for GitHub to recompute mergeability before it is pending" do
    GithubPrSignal.signal!([ %w[tadasant/zimmer base_push] ], at: 10.seconds.ago)
    assert_not Github::PrWebhookIngest::Reading.for([ ref ]).merge_conflict_pending?(1.hour.ago)

    travel Github::PrWebhookIngest::MERGE_CONFLICT_SETTLE do
      assert Github::PrWebhookIngest::Reading.for([ ref ]).merge_conflict_pending?(1.hour.ago)
    end
  end
end

# frozen_string_literal: true

require "test_helper"

# What "the PR" and "green" mean on the User view's row, and on the Merge button
# that reads the same answer.
class Sessions::PrSummaryTest < ActiveSupport::TestCase
  def session_with(urls: [], statuses: {}, ci: {})
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      custom_metadata: {
        "github_pull_request_urls" => urls,
        "github_pull_request_statuses" => statuses,
        "github_pull_request_ci_statuses" => ci
      }
    )
  end

  URL_A = "https://github.com/o/r/pull/1"
  URL_B = "https://github.com/o/r/pull/2"

  test "a session with no PRs answers nothing rather than raising" do
    summary = Sessions::PrSummary.for(Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test"))

    assert_not summary.any?
    assert_nil summary.url
    assert_nil summary.status
    assert_not summary.mergeable?
    assert_equal "This session has no PR.", summary.merge_blocked_reason
  end

  test "the PR is the most recently recorded one" do
    summary = Sessions::PrSummary.for(session_with(
      urls: [ URL_A, URL_B ],
      statuses: { URL_A => "merged", URL_B => "open" },
      ci: { URL_B => "pass" }
    ))

    assert_equal URL_B, summary.url, "a follow-up PR is the one the session is currently about"
    assert_equal 2, summary.count
    assert summary.mergeable?
  end

  test "open plus a green CI is the only mergeable combination" do
    assert Sessions::PrSummary.for(
      session_with(urls: [ URL_A ], statuses: { URL_A => "open" }, ci: { URL_A => "pass" })
    ).mergeable?
  end

  # Every one of these has been mistaken for "green" at some point. None of them
  # is: pending is a run still going, skipping/cancel are checks that never
  # reported, and an absent key means GitHub answered and the PR has no checks at
  # all. Offering a merge on any of them offers to merge something unverified.
  test "pending, failing, skipped, cancelled and unchecked PRs are all un-mergeable" do
    { "pending" => "CI is pending.",
      "fail" => "CI is fail.",
      "skipping" => "CI is skipping.",
      "cancel" => "CI is cancel." }.each do |ci_status, reason|
      summary = Sessions::PrSummary.for(
        session_with(urls: [ URL_A ], statuses: { URL_A => "open" }, ci: { URL_A => ci_status })
      )
      assert_not summary.mergeable?, "#{ci_status} must not read as green"
      assert_equal reason, summary.merge_blocked_reason
    end

    no_checks = Sessions::PrSummary.for(session_with(urls: [ URL_A ], statuses: { URL_A => "open" }))
    assert_not no_checks.mergeable?
    assert_equal "CI has not reported on this PR.", no_checks.merge_blocked_reason
  end

  test "a merged PR says so rather than reporting a CI problem" do
    summary = Sessions::PrSummary.for(
      session_with(urls: [ URL_A ], statuses: { URL_A => "merged" }, ci: { URL_A => "pass" })
    )

    assert summary.merged?
    assert_not summary.mergeable?
    assert_equal "Already merged.", summary.merge_blocked_reason
  end

  test "a closed PR is not mergeable and names its state" do
    summary = Sessions::PrSummary.for(
      session_with(urls: [ URL_A ], statuses: { URL_A => "closed" }, ci: { URL_A => "pass" })
    )

    assert_not summary.mergeable?
    assert_equal "The PR is closed.", summary.merge_blocked_reason
  end

  # The poller has not rated it yet. Unknown is not green.
  test "a PR the poller has not rated is not mergeable" do
    summary = Sessions::PrSummary.for(session_with(urls: [ URL_A ]))

    assert summary.any?
    assert_not summary.mergeable?
    assert_equal "Zimmer has not read this PR's state yet.", summary.merge_blocked_reason
  end
end

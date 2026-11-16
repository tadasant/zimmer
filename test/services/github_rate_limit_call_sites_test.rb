# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Every GithubCli.run call site, handed a call the rate-limit breaker refused. Each must read
# it as "ask again later": one call, no retry inside the same tick, and no definite answer
# (a PR gone, no comments, no runs, no checks) built on a call that was never sent. A tick
# that comes back against a breaker still open is fine, because a refused call sends nothing.
#
# `GithubCli.expects(:run).once` is the "no tight loop" half: a site that retried a refused
# call within the same invocation would call it again.
class GithubRateLimitCallSitesTest < ActiveSupport::TestCase
  REF = Github::PrRef.parse("https://github.com/owner/repo/pull/42")

  setup do
    BoundedSubprocess.expects(:run).never
    GhTokenProvisioner.stubs(:ensure!)
  end

  def refused(resource)
    GithubCli::Result.refused(
      GithubRateLimit::Refusal.new(resource: resource, reset_at: 20.minutes.from_now, credential: "GH_TOKEN")
    )
  end

  def expect_one_refused(resource)
    GithubCli.expects(:run).once.returns(refused(resource))
  end

  test "GithubCommentPromptBuilder#public_repo?: assumed public, and marked refused so the comment waits" do
    expect_one_refused("core")
    comment_info = { owner: "outsider", repo: "repo", type: "pr", data: { "id" => 1, "created_at" => Time.current.iso8601 } }
    builder = GithubCommentPromptBuilder.new(session: sessions(:with_pr_url), comment_info: comment_info)

    assert builder.send(:public_repo?)
    assert builder.visibility_lookup_refused?
  end

  test "GithubSearchService.auth_preflight: :rate_limited, which the poller polls through" do
    expect_one_refused("core")

    preflight = GithubSearchService.auth_preflight
    assert preflight.rate_limited?
    assert preflight.reset_at
  end

  test "GithubSearchService.search_issues: RateLimitedError at once, not the transient retry" do
    expect_one_refused("search")

    assert_raises(GithubSearchService::RateLimitedError) { GithubSearchService.search_issues("repo:a/b is:issue") }
  end

  test "GateDecisions::LedgerSource::Github: Unavailable, which the post-deploy task backs off on" do
    expect_one_refused("core")

    assert_raises(GateDecisions::LedgerSource::Unavailable) { GateDecisions::LedgerSource::Github.new.files }
  end

  test "WorkBacklog::Source::Github: Unavailable, which the post-deploy task backs off on" do
    expect_one_refused("core")

    assert_raises(WorkBacklog::Source::Unavailable) { WorkBacklog::Source::Github.new.items }
  end

  test "Github::IssueLinkProbe: ProbeError, so the liveness sweep leaves its rows unknown" do
    expect_one_refused("graphql")

    assert_raises(Github::IssueLinkProbe::ProbeError) { Github::IssueLinkProbe.call(repo: "owner/repo", numbers: [ 1, 2 ]) }
  end

  test "CommentEvaluator#fetch_paginated_comments: nil, not an empty list, and no further page" do
    expect_one_refused("core")

    assert_nil Github::CommentEvaluator.new.send(:fetch_paginated_comments, "repos/owner/repo/issues/42/comments")
  end

  test "CommentEvaluator#add_eyes_reaction: dropped quietly, never retried" do
    expect_one_refused("core")

    assert_nothing_raised do
      Github::CommentEvaluator.new.send(:add_eyes_reaction, { owner: "owner", repo: "repo", type: "pr", data: { "id" => 7 } })
    end
  end

  test "PrStatusEvaluator#fetch_merge_commit_sha: nil, so the merge message goes out unchanged" do
    expect_one_refused("graphql")

    assert_nil Github::PrStatusEvaluator.new.send(:fetch_merge_commit_sha, REF)
  end

  test "PrStatusEvaluator#post_merge_automation: a refused runs lookup is 'could not tell', not 'no runs'" do
    evaluator = Github::PrStatusEvaluator.new
    evaluator.stubs(:fetch_merge_commit_sha).returns("abc1234")
    expect_one_refused("core")

    assert_equal({ merge_commit_sha: nil, runs: [] }, evaluator.send(:post_merge_automation, REF.url))
  end

  test "PrStatusEvaluator#fetch_ci_status: unknown, never the exit-8 pending code" do
    expect_one_refused("graphql")

    assert_equal Github::PrStatusEvaluator::CI_STATUS_UNKNOWN, Github::PrStatusEvaluator.new.send(:fetch_ci_status, REF)
  end

  test "PrSnapshot.fetch: nil, never 'the PR is gone'" do
    expect_one_refused("graphql")

    assert_nil Github::PrSnapshot.fetch(REF)
  end

  test "PrSnapshot.fetch_rest_mergeable: nil, so the GraphQL reading stands" do
    expect_one_refused("core")

    assert_nil Github::PrSnapshot.fetch_rest_mergeable(REF)
  end
end

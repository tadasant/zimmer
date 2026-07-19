# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GithubSearchServiceTest < ActiveSupport::TestCase
  # A stand-in for Process::Status with a controllable #success?.
  Status = Struct.new(:success?)

  test "configured? is true when gh auth status exits 0" do
    BoundedSubprocess.expects(:run)
      .with([ "gh", "auth", "status" ], timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .returns([ "", "Logged in", Status.new(true) ])
    assert GithubSearchService.configured?
  end

  test "configured? is false when gh auth status exits non-zero" do
    # This is the staging failure mode: gh present but no credential.
    BoundedSubprocess.expects(:run)
      .with([ "gh", "auth", "status" ], timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .returns([ "", "You are not logged into any GitHub hosts. To get started with GitHub CLI, please run: gh auth login", Status.new(false) ])
    assert_not GithubSearchService.configured?
  end

  test "configured? is false (not raising) when gh is not even installed" do
    BoundedSubprocess.expects(:run)
      .with([ "gh", "auth", "status" ], timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .raises(Errno::ENOENT, "No such file or directory - gh")
    assert_not GithubSearchService.configured?
  end

  test "configured? is false (not raising) when the auth preflight hangs and is killed" do
    # A degraded GitHub API can hang `gh auth status`; the watchdog kills it and we
    # treat the tick as unconfigured rather than letting the hang wedge the poller.
    BoundedSubprocess.expects(:run)
      .with([ "gh", "auth", "status" ], timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .raises(BoundedSubprocess::TimeoutError, "command timed out after 10s (process group killed): gh auth status")
    assert_not GithubSearchService.configured?
  end

  test "search_issues surfaces a hung request as a SearchError" do
    # The heart of the incident: `gh` stalls against a degraded API. BoundedSubprocess
    # kills it and raises TimeoutError; search_issues must convert that into the same
    # SearchError any other request failure raises, so the poller alerts and retries.
    BoundedSubprocess.stubs(:run)
      .raises(BoundedSubprocess::TimeoutError, "command timed out after 15s (process group killed): gh api search/issues")

    error = assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a label:\"ready to merge\"")
    end
    assert_includes error.message, "timed out"
  end

  test "search_issues raises SearchError on a non-zero gh exit" do
    BoundedSubprocess.stubs(:run).returns([ "", "API rate limit exceeded", Status.new(false) ])

    error = assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end
    assert_includes error.message, "API rate limit exceeded"
  end

  test "search_issues raises SearchError (not NoMethodError) when gh returns a nil status" do
    # Production incident 2026-07-19 (condition 352, the live "PR ready to merge → merge
    # gate" poller): BoundedSubprocess handed back a nil Process::Status — Open3's wait_thr
    # is a Process.detach thread whose #value is nil when the child was reaped elsewhere
    # before its own waitpid (ECHILD), a race in the multi-threaded GoodJob worker. The
    # unguarded `status.success?` then blew up with `undefined method 'success?' for nil`
    # and crashed the poll tick. A nil status is a failed gh call and must surface as the
    # same SearchError every other failure raises, so the poller's rescue handles it.
    BoundedSubprocess.stubs(:run).returns([ "out", "", nil ])

    error = assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end
    assert_includes error.message, "gh api search/issues failed"
    assert_includes error.message, "without a status"
  end

  test "configured? is false on a nil gh auth status, without traversing the rescue" do
    # The same reaped-child race on the auth preflight. configured?'s broad `rescue => e`
    # already downgraded the old `nil.success?` NoMethodError to false, so a bare
    # `assert_not configured?` would pass against the unfixed code too. The observable delta
    # the fix introduces is that a nil status is now handled inline (`status&.success? ||
    # false`) instead of raising into the rescue and logging a misleading
    # "gh auth preflight failed: NoMethodError" WARN — so pin that: no WARN is emitted.
    BoundedSubprocess.expects(:run)
      .with([ "gh", "auth", "status" ], timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .returns([ "", "", nil ])
    Rails.logger.expects(:warn).never

    assert_not GithubSearchService.configured?
  end

  test "repo_group ORs the repos" do
    assert_equal "(repo:owner/a OR repo:owner/b)",
                 GithubSearchService.repo_group(%w[owner/a owner/b])
  end

  test "label_group quotes each label and strips embedded quotes" do
    assert_equal %{(label:"ready to merge" OR label:"urgent")},
                 GithubSearchService.label_group([ "ready to merge", "urgent" ])
    # An embedded double quote would terminate the qualifier early; it is dropped.
    assert_equal %{(label:"weird name")},
                 GithubSearchService.label_group([ 'weird" name' ])
  end
end

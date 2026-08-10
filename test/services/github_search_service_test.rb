# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GithubSearchServiceTest < ActiveSupport::TestCase
  # A stand-in for Process::Status with a controllable #success?. Built from the
  # shared helper so it answers #exitstatus and #signaled? too: the failure path
  # formats those, and a real Process::Status always has them.
  def status(success) = fake_process_status(exitstatus: success ? 0 : 1)

  test "configured? is true when gh auth status exits 0" do
    BoundedSubprocess.expects(:run)
      .with([ "gh", "auth", "status" ], timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .returns([ "", "Logged in", status(true) ])
    assert GithubSearchService.configured?
  end

  test "configured? is false when gh auth status exits non-zero" do
    # This is the staging failure mode: gh present but no credential.
    BoundedSubprocess.expects(:run)
      .with([ "gh", "auth", "status" ], timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .returns([ "", "You are not logged into any GitHub hosts. To get started with GitHub CLI, please run: gh auth login", status(false) ])
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
    BoundedSubprocess.stubs(:run).returns([ "", "API rate limit exceeded", status(false) ])

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
    assert_includes error.message, SubprocessStatus::REAPED_DESCRIPTION
  end

  test "configured? is false on a nil gh auth status, without traversing the rescue" do
    # The same reaped-child race on the auth preflight. configured?'s broad `rescue => e`
    # already downgraded the old `nil.success?` NoMethodError to false, so a bare
    # `assert_not configured?` would pass against the unfixed code too. The observable delta
    # the fix introduces is that a nil status is now handled inline (SubprocessStatus.success?)
    # instead of raising into the rescue and logging a misleading
    # "gh auth preflight failed: NoMethodError" WARN — so pin that: no WARN is emitted.
    BoundedSubprocess.expects(:run)
      .with([ "gh", "auth", "status" ], timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .returns([ "", "", nil ])
    Rails.logger.expects(:warn).never

    assert_not GithubSearchService.configured?
  end

  # ── incomplete_results: refuse the read, but don't page for it ─────────────
  #
  # GitHub answers `incomplete_results: true` when its search index times out and returns
  # only what it managed to index. Accepting that as the complete picture would shrink the
  # poller's seen-set and re-fire every item missing from the short read, so it is refused
  # — but it is also transient, so the page is re-fetched before we give up, and what we
  # finally raise is the narrower IncompleteResultsError the poller can treat as a skip.

  # A search response as `gh api` prints it.
  def search_payload(numbers:, total: nil, incomplete: false)
    JSON.generate({
      "total_count" => total || numbers.length,
      "incomplete_results" => incomplete,
      "items" => numbers.map { |n| { "number" => n, "repository_url" => "https://api.github.com/repos/owner/a" } }
    })
  end

  test "search_issues re-fetches an incomplete page and returns the recovered, complete result" do
    # The common case in production: the index blips on one request and has the answer on
    # the next. The caller must see a normal, complete search — not an error, and not the
    # partial page merged into the complete one (which would double-count item 1).
    partial = search_payload(numbers: [ 1 ], total: 2, incomplete: true)
    complete = search_payload(numbers: [ 1, 2 ], total: 2)

    BoundedSubprocess.expects(:run).twice
      .returns([ partial, "", status(true) ], [ complete, "", status(true) ])
    delays = []
    GithubSearchService.stubs(:sleep).with { |seconds| delays << seconds; true }

    items = GithubSearchService.search_issues("is:open is:pr repo:owner/a")

    assert_equal [ 1, 2 ], items.map { |item| item["number"] }
    assert_equal [ GithubSearchService::INCOMPLETE_RESULT_RETRY_DELAYS.first ], delays
  end

  test "a multi-page search that blips on a later page is re-run from page 1, not stitched" do
    # The invariant a per-page retry would quietly break. Pages 1..N-1 came from an index
    # that was already struggling; splicing them onto a page fetched seconds later, after
    # the index changed state, can drop an item whose page boundary shifted underneath the
    # pagination — corrupting the seen-set by a subtler route than the short read itself.
    # So the whole search restarts: 2 requests for the failed attempt, 2 for the retry.
    first_page = search_payload(numbers: (1..GithubSearchService::PER_PAGE).to_a, total: 101)
    bad_second = search_payload(numbers: [ 101 ], total: 101, incomplete: true)
    good_second = search_payload(numbers: [ 101 ], total: 101)

    BoundedSubprocess.expects(:run).times(4).returns(
      [ first_page, "", status(true) ],   # attempt 1, page 1
      [ bad_second, "", status(true) ],   # attempt 1, page 2 — index times out
      [ first_page, "", status(true) ],   # attempt 2 starts over at page 1
      [ good_second, "", status(true) ]   # attempt 2, page 2
    )
    GithubSearchService.stubs(:sleep)

    numbers = GithubSearchService.search_issues("is:open is:pr repo:owner/a").map { |item| item["number"] }

    assert_equal 101, numbers.length
    assert_equal numbers.uniq, numbers, "restarting must not double-count the pages already read"
    assert_equal (1..101).to_a, numbers
  end

  test "search_issues raises IncompleteResultsError once the index stays incomplete" do
    # Exhausted retries: one initial attempt plus one per configured delay, then give up.
    attempts = GithubSearchService::INCOMPLETE_RESULT_RETRY_DELAYS.length + 1
    BoundedSubprocess.expects(:run).times(attempts)
      .returns([ search_payload(numbers: [ 1 ], total: 2, incomplete: true), "", status(true) ])
    delays = []
    GithubSearchService.stubs(:sleep).with { |seconds| delays << seconds; true }

    error = assert_raises(GithubSearchService::IncompleteResultsError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end

    # Still a SearchError, so callers that don't care about the distinction are unaffected.
    assert_kind_of GithubSearchService::SearchError, error
    assert_includes error.message, "incomplete results"
    assert_equal GithubSearchService::INCOMPLETE_RESULT_RETRY_DELAYS.to_a, delays
  end

  test "an incomplete page is never returned to the caller as the complete set" do
    # The guarantee the raise exists for, stated directly: the index says there are 2
    # matching items and hands back 1. If that 1 were accepted, the poller would read the
    # other as newly unlabelled, drop it from the seen-set, and re-fire it. Nothing short
    # of a complete page may leave this method — an exception is the only other exit.
    BoundedSubprocess.stubs(:run)
      .returns([ search_payload(numbers: [ 1 ], total: 2, incomplete: true), "", status(true) ])
    GithubSearchService.stubs(:sleep)

    assert_raises(GithubSearchService::IncompleteResultsError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end
  end

  test "only the incomplete case retries — a hung request still fails on the first attempt" do
    # A timeout has already spent REQUEST_TIMEOUT and is no likelier to succeed on an
    # immediate repeat; retrying it would spend three timeouts inside a one-minute tick.
    BoundedSubprocess.expects(:run).once
      .raises(BoundedSubprocess::TimeoutError, "command timed out after 15s (process group killed)")
    GithubSearchService.expects(:sleep).never

    error = assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end
    assert_not_kind_of GithubSearchService::IncompleteResultsError, error
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

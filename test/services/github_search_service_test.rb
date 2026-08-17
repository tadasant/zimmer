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
    # A 422 is GitHub rejecting the query itself, so this is the fail-fast path: one
    # attempt, no backoff, straight to the SearchError the poller pages on.
    BoundedSubprocess.expects(:run).once.returns([ "", "gh: Validation Failed (HTTP 422)", status(false) ])
    GithubSearchService.expects(:sleep).never

    error = assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end
    assert_includes error.message, "Validation Failed"
  end

  test "search_issues raises SearchError (not NoMethodError) when gh returns a nil status" do
    # Production incident 2026-07-19 (condition 352, the live "PR ready to merge → merge
    # gate" poller): BoundedSubprocess handed back a nil Process::Status — Open3's wait_thr
    # is a Process.detach thread whose #value is nil when the child was reaped elsewhere
    # before its own waitpid (ECHILD), a race in the multi-threaded GoodJob worker. The
    # unguarded `status.success?` then blew up with `undefined method 'success?' for nil`
    # and crashed the poll tick. A nil status is a failed gh call and must surface as the
    # same SearchError every other failure raises, so the poller's rescue handles it.
    #
    # It is also retried on the way there — a child reaped before its waiter is a lost
    # race, not a verdict — so the delays are asserted too. Without that the terminal
    # SearchError would pass against a classifier that had dropped the unknown? branch.
    attempts = GithubSearchService::TRANSIENT_REQUEST_RETRY_DELAYS.length + 1
    BoundedSubprocess.expects(:run).times(attempts).returns([ "out", "", nil ])
    delays = []
    GithubSearchService.stubs(:sleep).with { |seconds| delays << seconds; true }

    error = assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end
    assert_equal GithubSearchService::TRANSIENT_REQUEST_RETRY_DELAYS.to_a, delays
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
    # configured? provisions GH_TOKEN first. Stubbed so this assertion stays about the
    # preflight: an unreachable secret store would otherwise emit a WARN of its own.
    GhTokenProvisioner.stubs(:ensure!)
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

  test "a hung request still fails on the first attempt, alone among the transient failures" do
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

  # ── a failed request: retry the blip, still page for the outage ────────────
  #
  # #436. Any non-zero `gh` exit raised on the first attempt, and GithubTriggerPollerJob's
  # per-condition rescue turns that straight into ERROR + AlertService — a page. Production
  # produced four distinct upstream failures in seven days (an incomplete index, a 401, a
  # truncated body, two 504s), every one of them cleared by the next tick, so every page
  # arrived at a system that had already healed. These pin the two halves of the fix: a
  # blip is absorbed silently, and a failure that does not clear is exactly as loud as it
  # was before.

  # Rails.logger swapped for a StringIO-backed logger whose formatter keeps the severity,
  # so a test can assert the LEVEL a line was written at rather than merely that it was
  # written — the whole point being that an intermediate retry must not write ERROR, which
  # is what pages.
  def capture_log_lines
    original_logger = Rails.logger
    buffer = StringIO.new
    logger = ActiveSupport::Logger.new(buffer)
    logger.formatter = proc { |severity, _time, _progname, msg| "#{severity} #{msg}\n" }
    Rails.logger = logger

    yield

    buffer.string.lines.map(&:chomp).grep(/GithubSearchService/)
  ensure
    Rails.logger = original_logger
  end

  # The verbatim stderr of each mode production actually logged, so these tests fail if
  # the classifier stops recognising the strings it was written against.
  PRODUCTION_401 = "gh: Bad credentials (HTTP 401)"
  PRODUCTION_504 = "gh: We couldn't respond to your request in time. Sorry about that. " \
                   "Please try resubmitting your request and contact us if the problem persists. (HTTP 504)"
  PRODUCTION_TRUNCATED_BODY = "unexpected end of JSON input"

  test "a 401 that clears on retry returns the recovered result, silently" do
    # 2026-08-14T08:00:05Z, both live conditions, 0.35s apart — the incident that filed the
    # issue. Nothing was broken by the time anyone read the page.
    BoundedSubprocess.expects(:run).twice.returns(
      [ "", PRODUCTION_401, status(false) ],
      [ search_payload(numbers: [ 1 ]), "", status(true) ]
    )
    delays = []
    GithubSearchService.stubs(:sleep).with { |seconds| delays << seconds; true }
    AlertService.expects(:raise_alert).never

    lines = capture_log_lines do
      items = GithubSearchService.search_issues("is:open is:pr repo:owner/a")
      assert_equal [ 1 ], items.map { |item| item["number"] }
    end

    assert_equal [ GithubSearchService::TRANSIENT_REQUEST_RETRY_DELAYS.first ], delays
    assert_empty lines.grep(/\AERROR/), "a recovered blip must not write the ERROR line that pages"
    assert_equal 1, lines.grep(/\AINFO/).length
    # GitHub's own words survive into the log, so the retry is diagnosable rather than mute.
    assert_includes lines.first, "Bad credentials"
  end

  test "a 504 and a truncated body are retried too — the mode is not read off a status code" do
    # 2026-08-17T14:10:32Z and 13:31:03Z. The truncated body is the one that matters for the
    # design: `gh` exits non-zero having written a partial response and there is no HTTP
    # status anywhere in stderr to key off.
    [ PRODUCTION_504, PRODUCTION_TRUNCATED_BODY ].each do |stderr|
      BoundedSubprocess.expects(:run).twice.returns(
        [ "", stderr, status(false) ],
        [ search_payload(numbers: [ 2 ]), "", status(true) ]
      )
      GithubSearchService.stubs(:sleep)

      items = GithubSearchService.search_issues("is:open is:pr repo:owner/a")
      assert_equal [ 2 ], items.map { |item| item["number"] }, "#{stderr} should have been retried"
    end
  end

  test "a body that arrives cut short is retried, even when gh exits 0" do
    # The zero-exit twin of `unexpected end of JSON input`: gh is happy, the JSON is not.
    BoundedSubprocess.expects(:run).twice.returns(
      [ '{"total_count": 1, "items": [{"num', "", status(true) ],
      [ search_payload(numbers: [ 3 ]), "", status(true) ]
    )
    GithubSearchService.stubs(:sleep)

    assert_equal [ 3 ], GithubSearchService.search_issues("is:open is:pr repo:owner/a").map { |i| i["number"] }
  end

  test "a 401 that does not clear still raises, so a dead credential is exactly as loud as before" do
    # The half that must not regress. Retrying cannot make a sustained failure quieter,
    # only ~4s later: the poller's per-condition rescue still logs ERROR and pages, on this
    # tick and every tick after.
    attempts = GithubSearchService::TRANSIENT_REQUEST_RETRY_DELAYS.length + 1
    BoundedSubprocess.expects(:run).times(attempts).returns([ "", PRODUCTION_401, status(false) ])
    delays = []
    GithubSearchService.stubs(:sleep).with { |seconds| delays << seconds; true }

    error = assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end

    assert_equal GithubSearchService::TRANSIENT_REQUEST_RETRY_DELAYS.to_a, delays
    assert_includes error.message, "Bad credentials"
    # The page says GitHub kept failing, not that it failed once.
    assert_includes error.message, "still failing after #{attempts} attempts"
    # A plain SearchError: the poller's `rescue IncompleteResultsError` must not swallow
    # this into a quiet skip.
    assert_not_kind_of GithubSearchService::IncompleteResultsError, error
    assert_not_kind_of GithubSearchService::TransientRequestError, error
  end

  test "a failure GitHub attributes to the request fails fast, without spending the tick" do
    # Waiting cannot fix a query GitHub rejected, a repo the token cannot see, a permission
    # it does not have, or a flag this file passed that `gh` does not know. Each must page
    # on the first attempt rather than three seconds and two retries later.
    {
      "gh: Validation Failed (HTTP 422)" => "malformed query",
      "gh: Not Found (HTTP 404)" => "invisible repo",
      "gh: Resource not accessible by integration (HTTP 403)" => "permission denial",
      "unknown flag: --raw-field" => "argument error"
    }.each do |stderr, description|
      BoundedSubprocess.expects(:run).once.returns([ "", stderr, status(false) ])
      GithubSearchService.expects(:sleep).never

      error = assert_raises(GithubSearchService::SearchError) do
        GithubSearchService.search_issues("is:open is:pr repo:owner/a")
      end
      assert_not_kind_of GithubSearchService::TransientRequestError, error, "#{description} must not retry"
    end
  end

  test "rate limiting fails fast, because a retry would spend the quota that caused it" do
    # Transient in every other sense, and deliberately not retried: the search endpoint
    # allows 30 requests a minute and a secondary limit's Retry-After is usually 60s+, so
    # no retry inside this budget can succeed — and since a retry re-runs the whole search,
    # it would spend more of the very quota that produced the failure.
    [ "gh: API rate limit exceeded for user ID 1. (HTTP 403)",
      "gh: You have exceeded a secondary rate limit (HTTP 403)",
      "gh: API rate limit exceeded (HTTP 429)" ].each do |stderr|
      BoundedSubprocess.expects(:run).once.returns([ "", stderr, status(false) ])
      GithubSearchService.expects(:sleep).never

      error = assert_raises(GithubSearchService::SearchError) do
        GithubSearchService.search_issues("is:open is:pr repo:owner/a")
      end
      assert_not_kind_of GithubSearchService::TransientRequestError, error, "#{stderr} must not retry"
    end
  end

  test "a hard failure during a search that ends incomplete raises SearchError, so it still pages" do
    # The subtle way a retry could have swallowed a page. IncompleteResultsError is the
    # poller's signal to skip the tick QUIETLY; a search that also failed outright is a
    # degradation it must page for. Raising the narrower class here would have turned a
    # 504 into five silent ticks.
    incomplete = search_payload(numbers: [ 1 ], total: 2, incomplete: true)
    BoundedSubprocess.stubs(:run).returns(
      [ "", PRODUCTION_504, status(false) ],
      [ incomplete, "", status(true) ],
      [ "", PRODUCTION_504, status(false) ],
      [ incomplete, "", status(true) ],
      [ incomplete, "", status(true) ]
    )
    GithubSearchService.stubs(:sleep)

    error = assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end

    assert_not_kind_of GithubSearchService::IncompleteResultsError, error,
                       "the poller would have skipped this quietly instead of paging"
    assert_includes error.message, "failed outright"
  end

  test "an injected HTTP status in the query cannot make a permanent failure retryable" do
    # Repo and label names reach `q=` from the trigger's configuration, and `gh` echoes the
    # query back in its error. Classification requires EVERY status it finds to be
    # retryable, so a label named "x (HTTP 503)" can only ever make us fail faster.
    BoundedSubprocess.expects(:run).once.returns(
      [ "", %{gh: Validation Failed (HTTP 422): q=label:"x (HTTP 503)"}, status(false) ]
    )
    GithubSearchService.expects(:sleep).never

    assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end
  end

  test "a non-zero exit with no stderr at all is retried" do
    # The most likely unclassified shape: `gh` fails and says nothing. Nothing identifies
    # it as ours, so the deny-list retries it — and pages if it persists.
    BoundedSubprocess.expects(:run).twice.returns(
      [ "", "", status(false) ],
      [ search_payload(numbers: [ 5 ]), "", status(true) ]
    )
    GithubSearchService.stubs(:sleep)

    assert_equal [ 5 ], GithubSearchService.search_issues("is:open is:pr repo:owner/a").map { |i| i["number"] }
  end

  test "a status outside 4xx is retried, not just 5xx" do
    # `return true unless 4xx` is the rule; pin it with a redirect nobody expects to see.
    BoundedSubprocess.expects(:run).twice.returns(
      [ "", "gh: Moved Permanently (HTTP 301)", status(false) ],
      [ search_payload(numbers: [ 6 ]), "", status(true) ]
    )
    GithubSearchService.stubs(:sleep)

    assert_equal [ 6 ], GithubSearchService.search_issues("is:open is:pr repo:owner/a").map { |i| i["number"] }
  end

  test "a slow search stops retrying on the wall clock, not just on the attempt count" do
    # The delay list bounds only the sleeping; a restart re-issues every page. A search
    # already past TRANSIENT_RETRY_DEADLINE starts no new attempt, so one condition cannot
    # spend the tick every other condition shares.
    BoundedSubprocess.expects(:run).once.returns([ "", PRODUCTION_504, status(false) ])
    GithubSearchService.expects(:sleep).never
    # First reading sets the deadline; the second is the check, by which point the search
    # has been running longer than the deadline allows.
    GithubSearchService.stubs(:monotonic_now)
                       .returns(1000.0, 1000.0 + GithubSearchService::TRANSIENT_RETRY_DEADLINE + 1)

    error = assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end
    assert_includes error.message, "giving up after #{GithubSearchService::TRANSIENT_RETRY_DEADLINE}s"
  end

  test "a failed page restarts the whole search rather than resuming mid-pagination" do
    # Same invariant the incomplete path defends: pages read before the failure came from
    # an API that is now visibly unwell, and splicing them onto a page fetched seconds
    # later can drop an item whose page boundary moved.
    first_page = search_payload(numbers: (1..GithubSearchService::PER_PAGE).to_a, total: 101)
    last_page = search_payload(numbers: [ 101 ], total: 101)

    BoundedSubprocess.expects(:run).times(4).returns(
      [ first_page, "", status(true) ],          # attempt 1, page 1
      [ "", PRODUCTION_504, status(false) ],     # attempt 1, page 2 — GitHub times out
      [ first_page, "", status(true) ],          # attempt 2 starts over at page 1
      [ last_page, "", status(true) ]            # attempt 2, page 2
    )
    GithubSearchService.stubs(:sleep)

    numbers = GithubSearchService.search_issues("is:open is:pr repo:owner/a").map { |item| item["number"] }

    assert_equal (1..101).to_a, numbers
    assert_equal numbers.uniq, numbers, "restarting must not double-count the pages already read"
  end

  test "the two retry budgets are separate, and both are bounded" do
    # A search unlucky enough to hit both modes gets both allowances and no more — the
    # ceiling on what one condition can spend sleeping inside a one-minute tick.
    incomplete = search_payload(numbers: [ 1 ], total: 2, incomplete: true)
    BoundedSubprocess.stubs(:run).returns(
      [ "", PRODUCTION_504, status(false) ],
      [ incomplete, "", status(true) ],
      [ "", PRODUCTION_504, status(false) ],
      [ incomplete, "", status(true) ],
      [ incomplete, "", status(true) ]
    )
    delays = []
    GithubSearchService.stubs(:sleep).with { |seconds| delays << seconds; true }

    # SearchError rather than IncompleteResultsError, because the request also failed
    # outright — see the dedicated test above for why that distinction is what pages.
    assert_raises(GithubSearchService::SearchError) do
      GithubSearchService.search_issues("is:open is:pr repo:owner/a")
    end

    both_budgets = GithubSearchService::TRANSIENT_REQUEST_RETRY_DELAYS +
                   GithubSearchService::INCOMPLETE_RESULT_RETRY_DELAYS
    assert_equal both_budgets.sort, delays.sort
    assert_operator delays.sum, :<=, 6, "one condition must not sleep away the tick it shares"
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

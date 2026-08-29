# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GithubSearchServiceTest < ActiveSupport::TestCase
  # A stand-in for Process::Status with a controllable #success?. Built from the
  # shared helper so it answers #exitstatus and #signaled? too: the failure path
  # formats those, and a real Process::Status always has them.
  def status(success) = fake_process_status(exitstatus: success ? 0 : 1)

  # ── the auth preflight ─────────────────────────────────────────────────────
  #
  # Every fixture below is `gh auth status --json hosts` output captured from a real
  # `gh` 2.97.0 driven into that state — an empty config dir, a bogus token, a CONNECT
  # proxy answering 503 — rather than invented. See the PR for #542 for the capture.
  AUTH_CMD = [ "gh", "auth", "status", "--json", "hosts" ].freeze

  def auth_status_json(accounts)
    JSON.generate(accounts.nil? ? { "hosts" => {} } : { "hosts" => { "github.com" => accounts } })
  end

  def stub_auth_status(stdout, stderr = "", exit_ok: true)
    BoundedSubprocess.expects(:run)
      .with(AUTH_CMD, timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .returns([ stdout, stderr, status(exit_ok) ])
  end

  # `gh` reports a live token as state "success".
  def healthy_json
    auth_status_json([ { "state" => "success", "active" => true, "host" => "github.com", "login" => "tadasant" } ])
  end

  # `gh` inlines the 401 body, escapes and all, exactly as reproduced here.
  def rejected_json
    auth_status_json([ { "state" => "error", "active" => true, "host" => "github.com",
                         "error" => "non-200 OK status code: 401 Unauthorized body: " \
                                    "\"{\\r\\n  \\\"message\\\": \\\"Bad credentials\\\",\\r\\n  " \
                                    "\\\"status\\\": \\\"401\\\"\\r\\n}\"" } ])
  end

  def unreachable_json(error = "Get \"https://api.github.com/\": Service Unavailable")
    auth_status_json([ { "state" => "error", "active" => true, "host" => "github.com", "error" => error } ])
  end

  test "auth_preflight is :authenticated when GitHub accepts the credential" do
    stub_auth_status(healthy_json)

    preflight = GithubSearchService.auth_preflight
    assert preflight.authenticated?
    assert_equal GithubSearchService::PREFLIGHT_AUTHENTICATED, preflight.state
  end

  test "auth_preflight is :unconfigured when gh knows of no github.com credential" do
    # The staging failure mode, and the ONLY state that keeps the poller's original
    # "gh CLI is not authenticated" wording. `--json` exits 0 here and reports an empty
    # hosts map; the "please run gh auth login" prose goes to stderr.
    stub_auth_status(auth_status_json(nil), "You are not logged into any GitHub hosts. To log in, run: gh auth login")

    assert GithubSearchService.auth_preflight.unconfigured?
  end

  test "auth_preflight is :unconfigured when gh is not even installed" do
    # Local and permanent, and says nothing about GitHub's health — so it belongs with
    # the staging case (skip quietly) rather than the degradation case.
    BoundedSubprocess.expects(:run)
      .with(AUTH_CMD, timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .raises(Errno::ENOENT, "No such file or directory - gh")

    assert GithubSearchService.auth_preflight.unconfigured?
  end

  test "auth_preflight is :rejected when GitHub actively refuses the credential" do
    stub_auth_status(rejected_json)

    preflight = GithubSearchService.auth_preflight
    assert preflight.rejected?
    assert_includes preflight.detail, "401"
  end

  test "auth_preflight caps gh's inlined 401 body rather than logging a paragraph" do
    stub_auth_status(rejected_json)

    detail = GithubSearchService.auth_preflight.detail
    assert_operator detail.length, :<=, GithubSearchService::MAX_PREFLIGHT_DETAIL_LENGTH
    assert_includes detail, "non-200 OK status code: 401"
  end

  # The regression this change exists for (#542). A 503 from GitHub against a VALID
  # credential exits non-zero and raises nothing — so the exit-code-and-exception split
  # the issue proposed would still have called this "unconfigured". Only the structured
  # error distinguishes it, and it must never read as a credential fault.
  test "auth_preflight is :unknown — not :unconfigured — when GitHub answers 503" do
    stub_auth_status(unreachable_json)

    preflight = GithubSearchService.auth_preflight
    assert preflight.unknown?
    assert_not preflight.unconfigured?, "a reachability failure must never be reported as a missing credential"
    assert_includes preflight.detail, "Service Unavailable"
  end

  test "auth_preflight is :unknown when GitHub cannot be resolved" do
    stub_auth_status(unreachable_json("Get \"https://api.github.com/\": dial tcp: lookup api.github.com: no such host"))

    assert GithubSearchService.auth_preflight.unknown?
  end

  test "auth_preflight is :unknown, not :rejected, on a 403 that may be a secondary rate limit" do
    # Auth-shaped but ambiguous: GitHub answers a secondary rate limit 403 too, and a
    # rate-limited preflight is a degradation rather than a dead token.
    stub_auth_status(unreachable_json("non-200 OK status code: 403 Forbidden body: \"rate limit\""))

    assert GithubSearchService.auth_preflight.unknown?
  end

  test "auth_preflight is :unknown when the preflight hangs and is killed" do
    # A degraded GitHub API can hang `gh auth status`. The watchdog kills it so the hang
    # cannot wedge the singleton — but the tick skips as "we could not ask", not as
    # "there is no credential".
    BoundedSubprocess.expects(:run)
      .with(AUTH_CMD, timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .raises(BoundedSubprocess::TimeoutError, "command timed out after 10s (process group killed): gh auth status")

    preflight = GithubSearchService.auth_preflight
    assert preflight.unknown?
    assert_includes preflight.detail, "TimeoutError"
  end

  test "auth_preflight is :unknown when gh fails before it can report" do
    # `--json` exits 0 for every auth problem it can describe, so a non-zero exit means
    # `gh` fell over first (an unknown flag on an older binary, an unreadable config).
    # We learned nothing about the credential, and must not pretend otherwise.
    stub_auth_status("", "unknown flag: --json", exit_ok: false)

    preflight = GithubSearchService.auth_preflight
    assert preflight.unknown?
    assert_includes preflight.detail, "unknown flag"
  end

  test "auth_preflight is :unknown when gh's output cannot be parsed" do
    stub_auth_status("not json at all")

    assert GithubSearchService.auth_preflight.unknown?
  end

  test "auth_preflight ignores a broken entry for a host this service never searches" do
    # `gh auth status` reports every host it knows, and its exit code goes non-zero if
    # ANY of them has a problem — so a stale enterprise entry used to read as "this
    # worker has no credential". The question is only ever about github.com.
    stdout = JSON.generate("hosts" => {
      "github.com" => [ { "state" => "success", "active" => true, "login" => "tadasant" } ],
      "ghe.example.com" => [ { "state" => "error", "error" => "non-200 OK status code: 401 Unauthorized" } ]
    })
    stub_auth_status(stdout, "", exit_ok: true)

    assert GithubSearchService.auth_preflight.authenticated?
  end

  test "auth_preflight is :authenticated when one of several github.com accounts works" do
    stdout = auth_status_json([
      { "state" => "error", "error" => "non-200 OK status code: 401 Unauthorized" },
      { "state" => "success", "active" => true, "login" => "tadasant" }
    ])
    stub_auth_status(stdout)

    assert GithubSearchService.auth_preflight.authenticated?
  end

  test "auth_preflight is :unknown when a refused account sits beside an unreachable one" do
    # Mixed evidence. We cannot say which credential we would have used is dead, so the
    # honest answer to a question we cannot settle is that we could not settle it.
    stdout = auth_status_json([
      { "state" => "error", "error" => "non-200 OK status code: 401 Unauthorized" },
      { "state" => "error", "error" => "Get \"https://api.github.com/\": Service Unavailable" }
    ])
    stub_auth_status(stdout)

    assert GithubSearchService.auth_preflight.unknown?
  end

  test "configured? stays a bare yes/no over auth_preflight" do
    # GithubTriggerHealthCheckJob's no-baseline guard reads this, and must keep declining
    # to seed for every non-authenticated state — including the new ones.
    GithubSearchService.stubs(:auth_preflight)
      .returns(GithubSearchService::PreflightResult.new(GithubSearchService::PREFLIGHT_UNKNOWN, "503"))
    assert_not GithubSearchService.configured?

    GithubSearchService.unstub(:auth_preflight)
    stub_auth_status(healthy_json)
    assert GithubSearchService.configured?
  end

  test "configured? leaves a breadcrumb when the preflight could not reach GitHub" do
    # GithubTriggerHealthCheckJob's no-baseline path asks this and then simply returns, so
    # without this line a GitHub outage during exactly that window would leave no record —
    # the silence the four states exist to break.
    stub_auth_status(unreachable_json)
    Rails.logger.expects(:warn).with { |line| line.include?("Could not determine") && line.include?("Service Unavailable") }

    assert_not GithubSearchService.configured?
  end

  test "configured? stays quiet on a host that is merely unconfigured" do
    # Staging legitimately has no credential and the health check runs on a schedule; a
    # WARN every time would be the noise the poller's early return exists to avoid.
    stub_auth_status(auth_status_json(nil))
    Rails.logger.expects(:warn).never

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

  test "auth_preflight is :unknown, and silent, on a nil gh auth status" do
    # The same reaped-child race on the auth preflight. A nil status is handled inline
    # (SubprocessStatus.success?) rather than raising `nil.success?` into the rescue, so
    # no WARN is emitted here — the caller owns the reporting. And it is :unknown, not
    # :unconfigured: a lost exit code tells us nothing about the credential.
    BoundedSubprocess.expects(:run)
      .with(AUTH_CMD, timeout: GithubSearchService::AUTH_STATUS_TIMEOUT)
      .returns([ "", "", nil ])
    # auth_preflight provisions GH_TOKEN first. Stubbed so this assertion stays about the
    # preflight: an unreachable secret store would otherwise emit a WARN of its own.
    GhTokenProvisioner.stubs(:ensure!)
    Rails.logger.expects(:warn).never

    preflight = GithubSearchService.auth_preflight
    assert preflight.unknown?
    assert_includes preflight.detail, SubprocessStatus::REAPED_DESCRIPTION
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

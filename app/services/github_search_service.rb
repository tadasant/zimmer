# frozen_string_literal: true

# Thin wrapper over GitHub's issue/PR search API, used by GithubTriggerPollerJob.
#
# Shells out to the `gh` CLI, exactly as Github::CommentEvaluator does, so it reuses
# the host's existing GitHub credential rather than introducing a second one.
#
# ## Why every query pins advanced_search=true
#
# GitHub is migrating the issue search API to its "advanced" query syntax. The two
# syntaxes are mutually incompatible for the multi-repo query this poller is built
# on, and neither form works under both:
#
#   legacy    repo:a repo:b        -> implicit OR;  `(repo:a OR repo:b)` is a 422
#   advanced  (repo:a OR repo:b)   -> explicit OR;  `repo:a repo:b` returns 0 rows
#
# The advanced form's failure mode is the dangerous one: a silent zero, not an error.
# Under the poller's seen-set semantics an empty result means "nothing carries the
# label", so a query that started being evaluated as advanced without us noticing
# would quietly drain the seen-set and then re-fire every labelled item the moment
# the syntax was corrected. Pinning the parameter means the syntax we build is the
# syntax GitHub evaluates, whichever default the API settles on.
class GithubSearchService
  class SearchError < StandardError; end

  # A search GitHub answered with `incomplete_results: true` — its index timed out and
  # handed back only what it had managed to index — and that did not clear on retry.
  #
  # Split out from SearchError for the same reason `configured?` is kept distinct from a
  # transient API failure: the two deserve different *reporting*, not different rigour.
  # The refusal is identical either way (a partial read is never treated as the complete
  # picture), but this one is transient and self-healing — GitHub's index recovers on its
  # own and the next tick re-derives the whole seen-set — whereas a rate limit, a hang, or
  # an unparseable response is worth paging on the first occurrence. The caller decides;
  # see GithubTriggerPollerJob#skip_incomplete_search.
  class IncompleteResultsError < SearchError; end

  # One attempt at a request failed in a way a moment's wait might fix: GitHub answered
  # 5xx, rate-limited us, or the response never arrived whole. Never reaches a caller —
  # search_issues either retries past it or converts it to a plain SearchError once the
  # budget is spent — but it subclasses SearchError anyway so that a future escape route
  # degrades to "the poller alerts", not "an unfamiliar class crashes the tick".
  class TransientRequestError < SearchError; end

  PER_PAGE = 100

  # GitHub's search API tops out at 1000 results, which is these 10 pages. A query
  # needing more than that is misconfigured (a label on every open issue, say), and
  # a truncated read would corrupt the poller's seen-set, so we raise instead.
  MAX_PAGES = 10

  # A search that came back incomplete is re-run this many times, waiting this long before
  # each attempt, because the index that timed out usually has the answer a moment later.
  # Deliberately short and few: the poller is a `total_limit: 1` singleton on a one-minute
  # cadence, so a condition's whole retry budget has to fit in a couple of seconds. It is
  # 2s of waiting per condition however many pages the search spans, since the delay is
  # spent per search attempt rather than per page.
  INCOMPLETE_RESULT_RETRY_DELAYS = [ 0.5, 1.5 ].freeze

  # The same treatment for a request that FAILED rather than came back short: `gh` exited
  # non-zero for a reason that reads as GitHub's problem rather than ours, or the response
  # body did not arrive whole. Waits a beat longer than the incomplete-index delays, and
  # widens, because the failures it covers are an API under load (502/503/504, a connection
  # cut mid-body) rather than one index query timing out.
  #
  # Two retries, not more, because the point is to outlast a blip, not to ride out an
  # outage. A failure that survives all three attempts still raises SearchError, and the
  # poller still logs ERROR and pages for it on that tick and every tick after — see
  # #retryable_failure? for why waiting cannot make a real failure quieter, only later.
  TRANSIENT_REQUEST_RETRY_DELAYS = [ 1.0, 3.0 ].freeze

  # No new attempt starts once a search has been running this long. The delays above bound
  # only the SLEEPING (4s, plus 2s for an incomplete index); they say nothing about the
  # requests a restart re-issues, and restarting is the whole design — so a search spanning
  # several pages against a merely-slow API could otherwise re-spend MAX_PAGES ×
  # REQUEST_TIMEOUT per attempt and eat the tick it shares with every other condition. This
  # is the bound that actually holds: a search still going after this long is not having a
  # blip, and the next tick is the better place to ask again.
  #
  # Generous against the healthy case (these searches return in well under a second, so it
  # never fires) and tight enough that one condition cannot spend the minute.
  TRANSIENT_RETRY_DEADLINE = 20

  # `gh` reports the API's status on its error line: `gh: Bad credentials (HTTP 401)`.
  # Absent for everything that fails below HTTP — a truncated body, a cut connection, a
  # DNS failure — which is why classification cannot be a status-code lookup alone.
  HTTP_STATUS_PATTERN = /\(HTTP (\d{3})\)/

  # The 4xx worth retrying. Everything else in that range is GitHub telling us the
  # REQUEST is wrong — a malformed query (422), a repo the token cannot see (404), a
  # permission denial (403) — which no amount of waiting changes.
  #
  #   401  Observed in production 2026-08-14 and again through the 2026-08-17 degradation,
  #        against a credential that authenticated from the same host minutes either side.
  #        Retrying it does not make a genuinely dead credential quieter, only ~4s later:
  #        the exhausted-retry raise pages on that tick and every tick after. And a
  #        revoked token does not usually arrive here at all — `configured?` fails, the
  #        tick skips, no heartbeat is stamped, and GithubTriggerHealthCheckJob pages on
  #        the stale heartbeat, which is the backstop it documents itself as being.
  #   408  A request timeout GitHub reports itself, rather than one we imposed.
  #
  # **Rate limiting is deliberately NOT here**, though it is transient in every other
  # sense. GitHub answers it 429, or 403 for a secondary limit, and neither clears inside
  # this budget: the search endpoint allows 30 requests a minute and a secondary limit
  # ships a Retry-After that is usually 60s or more. So a retry cannot succeed — and
  # because a retry re-runs the WHOLE search, it would spend more of the very quota that
  # produced the failure, on the one class of failure where extra requests make things
  # worse. It fails fast and pages, exactly as it did before this retry existed, and the
  # next tick is the retry.
  RETRYABLE_CLIENT_STATUSES = [ 401, 408 ].freeze

  # `gh` rejecting the command line before it ever calls GitHub — a flag the installed
  # `gh` does not know, say. That is a bug in this file, deterministic, and identical on
  # every attempt, so it must page on the first tick rather than three seconds later.
  GH_USAGE_ERROR_PATTERN = /\A(unknown (flag|shorthand flag|command)|accepts \d+ arg)/

  # Hard wall-clock ceiling on a single `gh` invocation. A healthy search API call
  # returns in well under a second; this is generous headroom for a merely slow
  # (degraded) API. Its real job is to bound a HANG: during a GitHub REST incident a
  # request can stall with the TCP connection half-open — no response, no reset — and
  # `Open3.capture3` would block the calling thread forever. Because the poller is a
  # `total_limit: 1` singleton, one hung `gh` call holds the only slot and every
  # subsequent minute's tick is a no-op: polling silently freezes with nothing raised
  # and nothing alerted (the exact shape of the merge-gate stall this bound exists to
  # prevent). BoundedSubprocess kills the whole process group on deadline and we turn
  # that into a SearchError, so a hang becomes a normal, alerting failure the poller
  # retries next tick rather than a silent wedge.
  REQUEST_TIMEOUT = 15

  # `gh auth status` validates the token against the API, so it too makes a network
  # call that a GitHub outage can hang — on the very preflight the poller runs before
  # it reaches any condition. Bound it as well so a stalled preflight can't wedge the
  # singleton before polling even begins. Shorter than a search: it is a single cheap
  # round-trip.
  AUTH_STATUS_TIMEOUT = 10

  # The only host this service searches. `gh auth status` reports every host it knows
  # about, and the preflight is a question about the one we are about to query — so a
  # broken entry for some other host must not read as "this worker has no credential".
  AUTH_HOST = "github.com"

  # The four answers the preflight can give. They exist because the previous two —
  # true/false — could not tell an operator apart from a liar: a credential GitHub
  # never saw, and a credential GitHub could not be asked about, both collapsed into
  # `false` and produced the poller's "gh CLI is not authenticated" WARN. See
  # .auth_preflight for how each is established.
  #
  #   :authenticated  `gh` reached GitHub and GitHub accepted the credential.
  #   :unconfigured   `gh` is certain there is no AUTH_HOST credential here (or `gh`
  #                   itself is not installed). The staging case the poller's early
  #                   return was built for.
  #   :rejected       A credential IS present and GitHub actively refused it — 401,
  #                   "Bad credentials". The one case that genuinely wants a human to
  #                   look at the token.
  #   :unknown        We did not get an answer. GitHub was unreachable or degraded, the
  #                   call timed out, or `gh` failed before it could report. Says nothing
  #                   about the credential, and must not be logged as if it did.
  PREFLIGHT_AUTHENTICATED = :authenticated
  PREFLIGHT_UNCONFIGURED = :unconfigured
  PREFLIGHT_REJECTED = :rejected
  PREFLIGHT_UNKNOWN = :unknown

  # GitHub refusing the credential, in the wording `gh auth status --json hosts` puts in
  # an account's `error` field:
  #
  #   non-200 OK status code: 401 Unauthorized body: "{\"message\": \"Bad credentials\" …}"
  #
  # Deliberately narrow, and deliberately the ONLY thing that earns :rejected. Every
  # other error — a 5xx, a DNS failure, a refused connection, a scope complaint we do
  # not recognise — falls through to :unknown, because the cost of the two mistakes is
  # not symmetric. Calling a transport failure a credential fault is the bug this whole
  # change exists to remove; calling a credential fault "could not determine" merely
  # sends the operator to read `gh`'s own words, which the log line carries verbatim.
  #
  # 403 is NOT here even though it is an auth-shaped status: GitHub answers a secondary
  # rate limit with 403, and a rate-limited preflight is a degradation, not a dead token.
  CREDENTIAL_REJECTED_PATTERN = /non-200 OK status code: 401\b|Bad credentials/

  # `gh` inlines the whole response body into its 401 error — a nested, doubly-escaped
  # JSON blob several times longer than the sentence that explains it. The leading text
  # carries the diagnosis ("401 … Bad credentials"), so cap the tail rather than let one
  # skipped tick print a paragraph every minute.
  MAX_PREFLIGHT_DETAIL_LENGTH = 200

  # One reading of `gh auth status`, as the poller needs to act on it: which of the four
  # answers above, plus `gh`'s own words for the operator reading the log line.
  PreflightResult = Struct.new(:state, :detail) do
    def authenticated?
      state == PREFLIGHT_AUTHENTICATED
    end

    def unconfigured?
      state == PREFLIGHT_UNCONFIGURED
    end

    def rejected?
      state == PREFLIGHT_REJECTED
    end

    def unknown?
      state == PREFLIGHT_UNKNOWN
    end
  end

  class << self
    # Whether the `gh` CLI can actually authenticate to GitHub from this process —
    # via a stored `gh auth login` credential OR a GH_TOKEN/GITHUB_TOKEN in the
    # environment, both of which `gh auth status` recognizes.
    #
    # This is the GitHub analogue of SlackService.configured?, and the poller guards
    # on it the same way SlackTriggerPollerJob guards on that. The staging worker ships
    # no gh credential, so without this every tick shelled out N times, each failing
    # with "please run: gh auth login", and each failure alerted — an every-minute
    # error storm over a missing credential the poller can simply detect and skip.
    #
    # Kept deliberately distinct from a transient API failure: an *unconfigured*
    # environment is not an incident (skip quietly), whereas a rate-limit or network
    # error on a configured host still raises out of search_issues and alerts.
    #
    # Answers ONLY "did GitHub accept the credential", collapsing every way of failing
    # into a bare false — which is what GithubTriggerHealthCheckJob's no-baseline guard
    # needs, since it must decline to seed unless the host has demonstrably polled.
    # Callers that report to a human want .auth_preflight instead, which does the actual
    # work: "no credential", "a credential GitHub refused" and "we could not ask" are the
    # same decision here but three different things to tell an operator.
    def configured?
      preflight = auth_preflight

      # The one breadcrumb this lossy shape owes its caller. GithubTriggerHealthCheckJob
      # asks this on its no-baseline path and then simply returns, so without a line here
      # a preflight that could not reach GitHub during exactly that window would leave no
      # record at all — the same silence this file's four states exist to break. Only
      # :unknown logs: an unconfigured staging host and a refused token are both answers,
      # and neither is worth a WARN every time the check runs.
      if preflight.unknown?
        Rails.logger.warn "[GithubSearchService] Could not determine whether the gh credential is " \
                          "valid: #{preflight.detail}"
      end

      preflight.authenticated?
    end

    # The full reading of `gh auth status`: which of the four PREFLIGHT_* states holds,
    # and `gh`'s own words for the log line.
    #
    # ## Why this parses `--json hosts` rather than reading the exit code
    #
    # `gh auth status`'s exit code and human-readable output cannot tell a dead
    # credential from an unreachable API, and its prose actively asserts the wrong one.
    # Driven against a CONNECT proxy answering 503 — the shape of the 2026-08-17
    # degradation — a *valid* credential produces exit 1 and:
    #
    #   github.com
    #     X Failed to log in to github.com account tadasant (…/hosts.yml)
    #     - The token in …/hosts.yml is invalid.
    #
    # which is a claim `gh` is in no position to make: it never got an answer. A
    # genuinely revoked token prints the same three lines, and so does an empty config.
    # Any classifier built on the exit code inherits that conflation — which is why
    # #542's suggested "non-zero exit = unconfigured, raised = degradation" split would
    # not have moved the observed symptom: the 503 exits non-zero and raises nothing.
    #
    # `--json hosts` is the same single round-trip, but structured, and it carries the
    # transport error `gh` swallows on its way to the prose above:
    #
    #   no credential   exit 0  {"hosts":{}}
    #   healthy         exit 0  hosts["github.com"][0].state == "success"
    #   revoked token   exit 0  state "error", error "non-200 OK status code: 401 … Bad credentials"
    #   GitHub 503      exit 0  state "error", error "Get \"https://api.github.com/\": Service Unavailable"
    #   DNS failure     exit 0  state "error", error "… no such host"
    #   API hangs       BoundedSubprocess::TimeoutError
    #
    # `--json` exits 0 for every auth problem it can describe ("unless there is a fatal
    # error", per `gh auth status --help`), which is what makes a NON-zero exit here
    # meaningful in its own right: `gh` fell over before it could report, and we learned
    # nothing. That is :unknown, not :unconfigured.
    def auth_preflight
      # Publish GH_TOKEN from the ${VAR} chain before asking `gh` anything, so the
      # preflight answers for the token the store holds NOW. The boot initializer has
      # usually done this already; re-running it here is what carries a rotation into
      # a long-lived worker (and, because sessions inherit this process's ENV, into
      # every agent spawned after it). Idempotent, and never raises — see the class.
      GhTokenProvisioner.ensure!

      result = GithubCli.run([ "gh", "auth", "status", "--json", "hosts" ], timeout: AUTH_STATUS_TIMEOUT)

      # GithubCli for the same reason as `search_issues` below: a nil status (child reaped
      # before the waiter's waitpid) and a hang that hit AUTH_STATUS_TIMEOUT both mean the
      # preflight produced no result. Unlike the old code we do not call that
      # "unconfigured" — we never learned anything, so it is :unknown and the poller says so.
      unless result.success?
        return unknown_preflight("gh auth status failed before it could report " \
                                 "(#{result.failure_description})")
      end

      classify_auth_hosts(JSON.parse(result.stdout))
    rescue JSON::ParserError => e
      unknown_preflight("could not parse gh auth status output: #{e.message}")
    rescue Errno::ENOENT => e
      # No `gh` binary at all. Local, permanent, and nothing to do with GitHub's health,
      # so it belongs with the staging case: skip quietly rather than page every minute
      # for a degradation that is not happening.
      PreflightResult.new(PREFLIGHT_UNCONFIGURED, "the gh CLI is not installed (#{e.message})")
    rescue => e
      # Anything GithubCli does not turn into a Result — it converts only the timeout.
      # The tick still skips, as :unknown, so nothing downstream claims the credential
      # is missing over a failure that says nothing about it.
      unknown_preflight("#{e.class}: #{e.message}")
    end

    # Runs a search query and returns every matching item.
    #
    # Raises rather than returning a partial result. The poller derives its seen-set
    # from the full result, so a short read would look like "these items lost their
    # label" and re-fire them on the next tick. A search GitHub reports as incomplete is
    # re-run whole a bounded number of times and, if it is still incomplete, raises
    # IncompleteResultsError — a SearchError, so callers that do not care about the
    # distinction are unaffected.
    #
    # A request that fails outright gets the same shape of second chance when the failure
    # reads as GitHub's rather than ours (see #retryable_failure?), and for the same
    # reason it is the whole search that re-runs rather than the offending page. What
    # changes is only WHEN the caller hears about a failure, never WHETHER: three failed
    # attempts raise SearchError exactly as one used to.
    def search_issues(query, sort: nil, order: nil)
      incomplete_attempt = 0
      transient_attempt = 0
      # Whether any attempt in this search failed OUTRIGHT, as opposed to coming back
      # short. It decides which error the exhausted search raises — see the incomplete
      # branch below, where getting this wrong would route a hard failure into the
      # poller's quiet skip.
      request_failed = false
      deadline = monotonic_now + TRANSIENT_RETRY_DEADLINE

      begin
        items = []
        page = 1

        loop do
          payload = request(query, page: page, sort: sort, order: order)

          # A timed-out search returns whatever it managed to index. Treating that as
          # the complete picture would shrink the seen-set, so refuse the whole read.
          if payload["incomplete_results"]
            raise IncompleteResultsError, "GitHub search returned incomplete results for query: #{query}"
          end

          page_items = payload["items"] || []
          items.concat(page_items)

          total = payload["total_count"].to_i
          break if page_items.empty? || items.length >= total

          page += 1
          if page > MAX_PAGES
            raise SearchError, "GitHub search matched more than #{MAX_PAGES * PER_PAGE} items " \
                               "(total_count=#{total}) for query: #{query}"
          end
        end

        items
      rescue IncompleteResultsError => e
        delay = INCOMPLETE_RESULT_RETRY_DELAYS[incomplete_attempt]

        if delay.nil?
          # The narrower class is a promise to the caller: "the index was slow, skip this
          # tick quietly, the next one re-derives the whole seen-set". That promise is only
          # honest if the index being slow is ALL that happened. A search that also failed
          # outright — a 504 on one attempt, an incomplete index on the next — is a
          # degradation the poller must page for, and raising IncompleteResultsError here
          # would hand it to #skip_incomplete_search instead, converting a page into five
          # quiet ticks. The hard failure wins.
          raise SearchError, "#{e.message} (and the request failed outright during this search)" if request_failed

          raise
        end

        incomplete_attempt += 1
        # .info, not .warn: an intermediate attempt that may still succeed is not a fault
        # (per the repo's logging philosophy). The terminal case is reported by the caller.
        Rails.logger.info "[GithubSearchService] Search index returned incomplete results on " \
                          "page #{page}; re-running the search in #{delay}s " \
                          "(retry #{incomplete_attempt} of #{INCOMPLETE_RESULT_RETRY_DELAYS.length})"
        sleep delay

        # Restarts the whole search from page 1 with an empty `items` — deliberately not
        # a re-fetch of the offending page alone. Every page a multi-page read accumulated
        # before the blip came from an index that was already struggling, and stitching
        # those onto a page served a couple of seconds later, after the index changed
        # state, can silently drop an item whose page boundary shifted underneath the
        # pagination. That is the same corrupt-the-seen-set failure the refusal exists to
        # prevent, arrived at by a subtler route. Whole read or nothing, on every attempt.
        retry
      rescue TransientRequestError => e
        request_failed = true
        delay = TRANSIENT_REQUEST_RETRY_DELAYS[transient_attempt]

        # Budget spent. Out goes a plain SearchError, so the poller's per-condition rescue
        # logs ERROR and pages exactly as it always has — the attempt count is in the
        # message so the page says "GitHub kept failing", not "GitHub failed once".
        if delay.nil?
          raise SearchError, "#{e.message} (still failing after " \
                             "#{TRANSIENT_REQUEST_RETRY_DELAYS.length + 1} attempts)"
        end

        # Out of wall clock rather than out of attempts. Restarting re-issues every page,
        # so a slow multi-page search can spend far more of the tick than the delay list
        # implies; past this point the next tick is the better place to ask again.
        if monotonic_now + delay > deadline
          raise SearchError, "#{e.message} (giving up after #{TRANSIENT_RETRY_DEADLINE}s)"
        end

        transient_attempt += 1
        # .info for the same reason the incomplete path uses it: an attempt that may still
        # succeed is not a fault, and an ERROR here would page for the blip we are absorbing.
        Rails.logger.info "[GithubSearchService] Search request failed, possibly transiently " \
                          "(#{e.message}); re-running the search in #{delay}s " \
                          "(retry #{transient_attempt} of #{TRANSIENT_REQUEST_RETRY_DELAYS.length})"
        sleep delay

        # Restarted whole rather than resumed at the failed page, for the reason spelled out
        # in the incomplete branch above: pages accumulated before the failure were served by
        # an API that is now visibly unwell, and stitching them onto a page fetched seconds
        # later can drop an item whose page boundary moved. Same invariant, same remedy.
        retry
      end
    end

    # ["owner/a", "owner/b"] -> (repo:owner/a OR repo:owner/b)
    #
    # Repo names are validated against TriggerCondition::GITHUB_REPO_FORMAT before
    # they are stored, so they cannot contain whitespace or quoting metacharacters.
    def repo_group(repos)
      or_group(repos.map { |repo| "repo:#{repo}" })
    end

    # ["ready to merge", "urgent"] -> (label:"ready to merge" OR label:"urgent")
    #
    # Labels are free text and routinely contain spaces, so each is quoted. An
    # embedded double quote would terminate the qualifier early, and GitHub has no
    # escape for it, so it is dropped rather than allowed to reshape the query.
    def label_group(labels)
      or_group(labels.map { |label| %(label:"#{label.to_s.delete('"')}") })
    end

    # ["hold issue work gate", "wip"] -> -label:"hold issue work gate" -label:"wip"
    #
    # Negations are ANDed, which is what makes "carrying ANY of these is enough to be
    # excluded" fall out: an item is returned only if it carries none of them. Returns
    # "" for an empty list so callers can join it into a query unconditionally.
    def exclude_label_terms(labels)
      labels.map { |label| %(-label:"#{label.to_s.delete('"')}") }.join(" ")
    end

    private

    # `{"hosts": {"github.com": [{state:, error:, …}, …]}}` -> a PreflightResult.
    def classify_auth_hosts(payload)
      accounts = Array(payload.dig("hosts", AUTH_HOST))

      # No entry for the host we search. `gh` reached its own config, found nothing to
      # offer for GitHub, and said so — the one negative answer it is actually able to
      # give without the network. This is the staging case the early return exists for.
      if accounts.empty?
        return PreflightResult.new(PREFLIGHT_UNCONFIGURED, "no #{AUTH_HOST} credential is configured")
      end

      # One working account is enough; `gh` lists every account it knows for a host and
      # a stale second entry does not stop the active one from authenticating.
      return PreflightResult.new(PREFLIGHT_AUTHENTICATED) if accounts.any? { |account| account["state"] == "success" }

      # Matched against the raw errors, never the shortened `detail` below: truncation is
      # a log-line concern, and letting it reach the classifier would make a long enough
      # error silently change state.
      errors = accounts.filter_map { |account| account["error"].presence }.uniq
      detail = errors.join("; ").presence ||
        "gh reported no working #{AUTH_HOST} account and gave no reason"

      # ALL of them, not any: with a mix of a refused token and an unreachable API we do
      # not know whether the credential we would actually use is dead, and the honest
      # answer to a question we cannot settle is that we could not settle it.
      if errors.any? && errors.all? { |error| error.match?(CREDENTIAL_REJECTED_PATTERN) }
        return PreflightResult.new(PREFLIGHT_REJECTED, preflight_detail(detail))
      end

      unknown_preflight(detail)
    end

    def unknown_preflight(detail)
      PreflightResult.new(PREFLIGHT_UNKNOWN, preflight_detail(detail))
    end

    # `gh`'s words, made fit for a log line that may repeat every minute: onto one line,
    # and capped — `gh` inlines whole response bodies into its errors.
    def preflight_detail(text)
      text.to_s.squish.truncate(MAX_PREFLIGHT_DETAIL_LENGTH)
    end

    def or_group(terms)
      "(#{terms.join(' OR ')})"
    end

    def request(query, page:, sort:, order:)
      command = [
        "gh", "api", "-X", "GET", "search/issues",
        "--raw-field", "q=#{query}",
        "--field", "advanced_search=true",
        "--field", "per_page=#{PER_PAGE}",
        "--field", "page=#{page}"
      ]
      command.push("--field", "sort=#{sort}") if sort.present?
      command.push("--field", "order=#{order}") if order.present?

      result = GithubCli.run(command, timeout: REQUEST_TIMEOUT)

      # A hung request is a failure like any other network failure: surface it as a
      # SearchError so the poller's per-condition rescue alerts and retries next tick.
      #
      # Deliberately NOT retried, alone among the transient failures — which is why it is
      # tested before `retryable_failure?` rather than folded into it. This one has already
      # spent REQUEST_TIMEOUT — a full 15s of the tick — and a repeat would spend another
      # 15s before it could even reach its backoff, so a hang would cost most of a minute
      # per condition rather than the seconds the retry budget is sized for. It is also the
      # failure a retry helps least: a stalled connection says the API is not answering at
      # all, and the next tick is a better time to ask than three seconds from now.
      raise SearchError, "gh api search/issues timed out: #{result.timeout_message}" if result.timed_out?

      # A nil status is a failed gh call, not a success — see SubprocessStatus for the
      # full mechanism. Routing it through the same SearchError the poller's per-condition
      # rescue already handles beats crashing the tick with `undefined method 'success?' for nil`.
      unless result.success?
        message = "gh api search/issues failed: #{result.failure_description}"
        raise TransientRequestError, message if retryable_failure?(result.status, result.stderr)

        raise SearchError, message
      end

      JSON.parse(result.stdout)
    rescue JSON::ParserError => e
      # The zero-exit twin of the truncation `gh` reports as `unexpected end of JSON input`
      # (observed in production 2026-08-17T13:31:03Z): a body that arrived cut short parses
      # no better on this attempt than that one, and no worse on the next.
      raise TransientRequestError, "Could not parse GitHub search response: #{e.message}"
    end

    # Whether a failed `gh` invocation is worth trying again.
    #
    # Deny-list, not allow-list: retry unless the failure is recognisably OURS. The four
    # modes production has actually produced here — a 401, an incomplete index, a truncated
    # body, a 504 — share nothing but the exit code, and two of them carry no HTTP status
    # at all, so an allow-list of known-transient signatures would keep paging for the
    # next mode nobody has seen yet. The cost of being wrong in this direction is bounded
    # and small: a permanent failure that slips through waits 4s and then pages anyway, on
    # this tick and every tick after. Nothing is ever suppressed.
    def retryable_failure?(status, stderr)
      # We never learned the exit code (the child was reaped before its waiter). The
      # command may well have succeeded; a lost race is the most retryable failure there
      # is, and SubprocessStatus#unknown? exists to let callers say exactly this.
      return true if SubprocessStatus.unknown?(status)

      detail = stderr.to_s.strip
      return false if detail.match?(GH_USAGE_ERROR_PATTERN)

      statuses = detail.scan(HTTP_STATUS_PATTERN).flatten.map(&:to_i)

      # No status at all: the failure happened below HTTP — a cut connection, a DNS
      # failure, a body that stopped mid-stream. Transient by nature.
      return true if statuses.empty?

      # EVERY status has to be retryable, not merely the first. `gh` can print more than
      # one, and the query it echoes back is partly user-supplied: repo and label names
      # reach `q=` from the trigger's configuration, so a label named `x (HTTP 503)` would
      # otherwise let a permanent 422 read as a retryable 503. Requiring unanimity means an
      # injected status can only ever make us fail FASTER.
      statuses.all? { |http| !http.in?(400..499) || RETRYABLE_CLIENT_STATUSES.include?(http) }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

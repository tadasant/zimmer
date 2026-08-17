# frozen_string_literal: true

# Thin wrapper over GitHub's issue/PR search API, used by GithubTriggerPollerJob.
#
# Shells out to the `gh` CLI, exactly as GithubCommentPollerJob does, so it reuses
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
  #
  INCOMPLETE_RESULT_RETRY_DELAYS = [ 0.5, 1.5 ].freeze

  # The same treatment for a request that FAILED rather than came back short: `gh` exited
  # non-zero for a reason that reads as GitHub's problem rather than ours, or the response
  # body did not arrive whole. Waits a beat longer than the incomplete-index delays, and
  # widens, because the failures it covers are an API under load (502/503/504, a rate
  # limit, a connection cut mid-body) rather than one index query timing out.
  #
  # Sized against the tick, exactly as above: 4s of waiting per condition, spent per
  # SEARCH attempt however many pages the search spans. A condition can therefore spend at
  # most INCOMPLETE_RESULT_RETRY_DELAYS + this — 6s — sleeping inside a 60s tick it shares
  # with every other condition.
  #
  # Two retries, not more, because the point is to outlast a blip, not to ride out an
  # outage. A failure that survives all three attempts still raises SearchError, and the
  # poller still logs ERROR and pages for it on that tick and every tick after — see
  # #retryable_failure? for why waiting cannot make a real failure quieter, only later.
  TRANSIENT_REQUEST_RETRY_DELAYS = [ 1.0, 3.0 ].freeze

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
  #   403  Only when it reads as a rate limit; GitHub returns both primary and secondary
  #        rate limiting as 403, and those clear on their own.
  #   408  A request timeout GitHub reports itself, rather than one we imposed.
  #   429  Rate limited, explicitly.
  RETRYABLE_CLIENT_STATUSES = [ 401, 408, 429 ].freeze

  # A 403 that is rate limiting rather than a permission denial. Matched on GitHub's own
  # wording, which is not an API contract — a rewording downgrades this to "fail fast and
  # page", which is the safe direction to be wrong in.
  RATE_LIMIT_PATTERN = /rate limit|secondary rate|abuse detection/i

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
    def configured?
      # Publish GH_TOKEN from the ${VAR} chain before asking `gh` anything, so the
      # preflight answers for the token the store holds NOW. The boot initializer has
      # usually done this already; re-running it here is what carries a rotation into
      # a long-lived worker (and, because sessions inherit this process's ENV, into
      # every agent spawned after it). Idempotent, and never raises — see the class.
      GhTokenProvisioner.ensure!

      _out, _err, status = BoundedSubprocess.run([ "gh", "auth", "status" ], timeout: AUTH_STATUS_TIMEOUT)
      # SubprocessStatus for the same reason as `search_issues` below: a nil status (child
      # reaped before the waiter's waitpid) means the preflight produced no result, so treat
      # this tick as unconfigured and skip rather than raising `nil.success?`.
      SubprocessStatus.success?(status)
    rescue => e
      # A timeout (BoundedSubprocess::TimeoutError) lands here too: a preflight that
      # hangs against a degraded API is treated as "not configured this tick" — the
      # poller skips rather than wedging, and the liveness check catches the resulting
      # gap in successful polls.
      Rails.logger.warn "[GithubSearchService] gh auth preflight failed: #{e.class}: #{e.message}"
      false
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
      rescue IncompleteResultsError
        delay = INCOMPLETE_RESULT_RETRY_DELAYS[incomplete_attempt]
        raise if delay.nil?

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
        delay = TRANSIENT_REQUEST_RETRY_DELAYS[transient_attempt]

        # Budget spent. Out goes a plain SearchError, so the poller's per-condition rescue
        # logs ERROR and pages exactly as it always has — the attempt count is in the
        # message so the page says "GitHub kept failing", not "GitHub failed once".
        if delay.nil?
          raise SearchError, "#{e.message} (still failing after " \
                             "#{TRANSIENT_REQUEST_RETRY_DELAYS.length + 1} attempts)"
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

      stdout, stderr, status = BoundedSubprocess.run(command, timeout: REQUEST_TIMEOUT)

      # A nil status is a failed gh call, not a success — see SubprocessStatus for the
      # full mechanism. Routing it through the same SearchError the poller's per-condition
      # rescue already handles beats crashing the tick with `undefined method 'success?' for nil`.
      unless SubprocessStatus.success?(status)
        message = "gh api search/issues failed: #{SubprocessStatus.describe_failure(status, stderr)}"
        raise TransientRequestError, message if retryable_failure?(status, stderr)

        raise SearchError, message
      end

      JSON.parse(stdout)
    rescue BoundedSubprocess::TimeoutError => e
      # A hung request is a failure like any other network failure: surface it as a
      # SearchError so the poller's per-condition rescue alerts and retries next tick,
      # rather than letting the stall propagate as an unfamiliar error class.
      #
      # Deliberately NOT retried, alone among the transient failures. This one has already
      # spent REQUEST_TIMEOUT — a full 15s of the tick — and a repeat would spend another
      # 15s before it could even reach its backoff, so a hang would cost most of a minute
      # per condition rather than the seconds the retry budget is sized for. It is also the
      # failure a retry helps least: a stalled connection says the API is not answering at
      # all, and the next tick is a better time to ask than three seconds from now.
      raise SearchError, "gh api search/issues timed out: #{e.message}"
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

      http = detail[HTTP_STATUS_PATTERN, 1]&.to_i

      # No status: the failure happened below HTTP — a cut connection, a DNS failure, a
      # body that stopped mid-stream. Transient by nature.
      return true if http.nil?
      return true unless http.in?(400..499)

      RETRYABLE_CLIENT_STATUSES.include?(http) || (http == 403 && detail.match?(RATE_LIMIT_PATTERN))
    end
  end
end

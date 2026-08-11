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
  # Only this failure retries. A timeout or a non-zero exit has already spent
  # REQUEST_TIMEOUT and is no likelier to succeed on an immediate repeat, so those raise
  # on the first attempt.
  INCOMPLETE_RESULT_RETRY_DELAYS = [ 0.5, 1.5 ].freeze

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
    def search_issues(query, sort: nil, order: nil)
      attempt = 0

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
        delay = INCOMPLETE_RESULT_RETRY_DELAYS[attempt]
        raise if delay.nil?

        attempt += 1
        # .info, not .warn: an intermediate attempt that may still succeed is not a fault
        # (per the repo's logging philosophy). The terminal case is reported by the caller.
        Rails.logger.info "[GithubSearchService] Search index returned incomplete results on " \
                          "page #{page}; re-running the search in #{delay}s " \
                          "(retry #{attempt} of #{INCOMPLETE_RESULT_RETRY_DELAYS.length})"
        sleep delay

        # Restarts the whole search from page 1 with an empty `items` — deliberately not
        # a re-fetch of the offending page alone. Every page a multi-page read accumulated
        # before the blip came from an index that was already struggling, and stitching
        # those onto a page served a couple of seconds later, after the index changed
        # state, can silently drop an item whose page boundary shifted underneath the
        # pagination. That is the same corrupt-the-seen-set failure the refusal exists to
        # prevent, arrived at by a subtler route. Whole read or nothing, on every attempt.
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
        raise SearchError, "gh api search/issues failed: #{SubprocessStatus.describe_failure(status, stderr)}"
      end

      JSON.parse(stdout)
    rescue BoundedSubprocess::TimeoutError => e
      # A hung request is a failure like any other network failure: surface it as a
      # SearchError so the poller's per-condition rescue alerts and retries next tick,
      # rather than letting the stall propagate as an unfamiliar error class.
      raise SearchError, "gh api search/issues timed out: #{e.message}"
    rescue JSON::ParserError => e
      raise SearchError, "Could not parse GitHub search response: #{e.message}"
    end
  end
end

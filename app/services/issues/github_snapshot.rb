# frozen_string_literal: true

module Issues
  # What is going on in GitHub across the five repos the fleet works, loaded at
  # request time and held in Rails.cache for a few minutes.
  #
  # GITHUB IS THE SOURCE OF TRUTH, so there is no mirror table. The alternative —
  # a poller writing issue rows into Postgres — buys a fast page at the cost of a
  # second, always-slightly-wrong copy of issue state, and a page showing "open"
  # for an issue closed ten minutes ago is worse than a page that takes a second
  # to load. The cache is a request-coalescer, not a mirror: it holds one
  # transformed read for CACHE_TTL and the page says how old that read is.
  #
  # WHY THE WINDOW IS ALWAYS THE WIDEST ONE. The trend chart reconstructs
  # open-issue counts per day from each issue's created/closed timestamps, so it
  # needs every issue that was open at any point in the window: everything
  # currently open, plus everything closed since the window began. Fetching the
  # widest window (180 days) once makes the 30- and 90-day views slices of the
  # same cached read rather than three separate loads of GitHub.
  #
  # WHY `gh` AND NOT A NEW CLIENT. GithubSearchService already shells out to the
  # `gh` CLI with the host's existing credential, paginates, and retries GitHub's
  # transient failures; the PR poller and the comment poller reach GitHub the same
  # way. A second credential for this page would be a second thing to rotate.
  class GithubSnapshot
    # The five repos Tadas works. Not configurable: the Issues page is a view of a
    # specific fleet's work, and a repo list in the database would be a setting
    # nobody sets. A sixth repo is a one-line change here.
    REPOS = %w[
      tadasant/zimmer
      tadasant/strad
      tadasant/tadasant-internal
      tadasant/pi-extensions
      tadasant/motet
    ].freeze

    # The trend windows the page offers, widest last — WINDOWS.max is what gets
    # fetched, and the others are slices of it.
    WINDOWS = [ 30, 90, 180 ].freeze

    # Short enough that a page load reflects a label applied a moment ago; long
    # enough that clicking between windows, segments and filters — each of which
    # is a fresh request — costs one GitHub read rather than a dozen.
    CACHE_TTL = 5.minutes

    # Bump when the cached shape changes, so a deploy does not read yesterday's
    # keys with today's parser.
    CACHE_KEY = "issues/github_snapshot/v2"

    # One `gh` call can spend GithubSearchService::REQUEST_TIMEOUT (15s) and a
    # full load is ten of them, so repos are fetched concurrently and the page
    # waits for the slowest repo rather than the sum of all five. This is the
    # backstop on that wait: past it the page renders what it has and says which
    # repo did not answer.
    FETCH_TIMEOUT = 60

    # A whole load: the issues, when it was taken, and — per repo — what went
    # wrong if anything did. A repo that failed is named on the page rather than
    # silently rendering as "no issues", which reads as good news.
    Snapshot = Data.define(:issues, :fetched_at, :errors) do
      def stale_seconds = [ (Time.current - fetched_at).to_i, 0 ].max
      def failed? = errors.any?
    end

    class << self
      # @param force [Boolean] drop the cached read first — the page's "refresh"
      #   control, and the only way to get a fresh load inside the TTL.
      # @return [Snapshot]
      def fetch(force: false)
        Rails.cache.delete(CACHE_KEY) if force

        cached = Rails.cache.read(CACHE_KEY)
        return hydrate(cached) if cached

        raw = load_from_github
        # A read in which EVERY repo failed is not a picture of GitHub, it is a
        # picture of GitHub being unreachable — and caching it would hold the
        # whole page in its degraded state for the full TTL after the outage
        # cleared, recoverable only by someone noticing and pressing Refresh. A
        # partial read is cached: it has real issues in it, and the repo that
        # failed is named on the page.
        Rails.cache.write(CACHE_KEY, raw, expires_in: CACHE_TTL) unless total_failure?(raw)
        hydrate(raw)
      end

      # The raw, cacheable shape: plain hashes and strings.
      #
      # Value objects are NOT cached. `Rails.cache` marshals, and a marshalled
      # Data subclass carries the autoloaded constant with it — so a read taken
      # before a deploy (or before a dev-mode reload) can fail to load against the
      # redefined class. Hashes survive both.
      def load_from_github
        preflight = GithubSearchService.auth_preflight
        return unauthenticated(preflight) unless preflight.authenticated?

        since = (Date.current - WINDOWS.max).iso8601
        issues = []
        errors = {}

        # A repo can come back with BOTH — the open search answered and the closed
        # one did not — so the issues are kept and the error recorded, rather than
        # one branch or the other.
        fetch_repos_concurrently(since).each do |repo, repo_issues, error|
          issues.concat(repo_issues)
          errors[repo] = error if error
        end

        { "fetched_at" => Time.current.iso8601, "issues" => issues.map(&:to_h_for_cache), "errors" => errors }
      end

      private

      # Every repo failed, so there is nothing in this read worth keeping.
      def total_failure?(raw)
        raw["errors"].to_h.length == REPOS.length && Array(raw["issues"]).empty?
      end

      def hydrate(raw)
        raw = {} unless raw.is_a?(Hash)
        Snapshot.new(
          issues: Array(raw["issues"]).map { |hash| GithubIssue.from_cache(hash) },
          fetched_at: GithubIssue.parse_time(raw["fetched_at"]) || Time.current,
          errors: raw["errors"].is_a?(Hash) ? raw["errors"] : {}
        )
      end

      # Every repo named, with the same reason, rather than an empty page that
      # looks like "nothing is going on in GitHub".
      def unauthenticated(preflight)
        reason = "Zimmer's GitHub credential is #{preflight.state} — #{preflight.detail}"
        { "fetched_at" => Time.current.iso8601, "issues" => [], "errors" => REPOS.index_with { reason } }
      end

      # `[repo, issues, error_message]` per repo, in REPOS order.
      #
      # Wrapped in the Rails executor because the block autoloads (GithubIssue,
      # GithubSearchService) and dev-mode autoloading from a bare thread is how
      # you get a deadlock rather than a page. Every failure is caught and named:
      # one repo's search failing must not cost the other four, and must not 500
      # the page.
      def fetch_repos_concurrently(since)
        started = REPOS.map do |repo|
          thread = Thread.new do
            # Set inside the thread, not on the line after `Thread.new` — a fast
            # failure could otherwise beat the assignment.
            Thread.current.report_on_exception = false
            Rails.application.executor.wrap { [ repo, *fetch_repo(repo, since) ] }
          rescue StandardError => e
            # Caught HERE rather than around `thread.value`, because `Thread#join`
            # re-raises before the value is ever asked for — so a rescue at the
            # join site would take the whole page down with the first repo that
            # 404s. A thread in this pool never raises a StandardError; anything
            # outside it (a failed autoload, an OOM) is not a condition a page can
            # render around, and is left to propagate.
            Rails.logger.warn("[Issues::GithubSnapshot] #{repo}: #{e.class}: #{e.message}")
            [ repo, [], "#{e.class}: #{e.message}" ]
          end
          [ repo, thread ]
        end

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + fetch_timeout
        started.map do |repo, thread|
          remaining = [ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max
          next thread.value if thread.join(remaining)

          thread.kill
          [ repo, [], "the GitHub read did not finish within #{fetch_timeout}s" ]
        end
      end

      # A seam, not a setting. FETCH_TIMEOUT is the answer everywhere; this exists
      # so a test can prove the timeout branch reports the repo rather than
      # silently emptying it, without waiting a minute to find out.
      def fetch_timeout = FETCH_TIMEOUT

      # Two searches, not one. Neither search syntax says "open, or closed since
      # X" in a form both GitHub and we can rely on, and the pair keeps each
      # result well inside GithubSearchService::MAX_PAGES — which raises rather
      # than truncating, so a repo that outgrows 1000 open issues is reported and
      # not silently halved.
      #
      # EACH HALF FAILS ON ITS OWN. The two searches are not equally likely to
      # fail, and they are not equally costly to lose. "Closed in the last 180
      # days" is the one that grows without bound on a fleet's own repo, so it is
      # the one that hits the 1000-result ceiling first — and letting that take
      # the open half down with it would blank the counts strip, the per-repo
      # summary and the loose list for a repo whose open issues we successfully
      # read a moment earlier. What survives is kept; what failed is named. The
      # trend line for that repo is short by its closed issues, so the error says
      # which half was lost rather than only that something was.
      def fetch_repo(repo, since)
        errors = []
        open_items = search(%(repo:#{repo} is:issue is:open), "the open issues", errors)
        closed_items = search(%(repo:#{repo} is:issue is:closed closed:>=#{since}), "the closed issues", errors)

        issues = (open_items + closed_items)
          .reject { |item| item.key?("pull_request") }
          .map { |item| GithubIssue.from_search_item(item, repo) }
          .uniq(&:number)

        [ issues, errors.presence&.join("; ") ]
      end

      def search(query, what, errors)
        GithubSearchService.search_issues(query)
      rescue GithubSearchService::SearchError => e
        errors << "could not read #{what} (#{e.message})"
        []
      end
    end
  end
end

# frozen_string_literal: true

module Issues
  # The Issues page, assembled: the fleet's work backlog joined to what is going
  # on in GitHub across the repos it watches.
  #
  # The join key is the issue URL. A backlog item carries one; a GitHub issue is
  # one. Everything the page shows is one of three things:
  #
  #   queued    an item the issue gate cleared, waiting its turn, in rank order
  #   in flight an item a pull or a promote started, whose session is still alive
  #   loose     an open GitHub issue with no queued or in-flight backlog row —
  #             held, unrated, or simply not picked up yet
  #
  # THE FILTERS ARE WorkBacklog::Filters, not a second filtering path. The queue
  # is the same queue `get_work_backlog` and the REST index read, and a page that
  # could answer "what is queued for strad" differently from the tool the groomer
  # calls would be worse than no page. The GitHub side reuses the same repo and
  # direction values so one filter bar drives both halves.
  class Board
    # Loose GitHub issues are paginated: the repos carry ~500 open issues between
    # them and a page that renders all of them is a page nobody scrolls.
    GITHUB_PER_PAGE = 50

    Row = Data.define(:item, :github, :direction, :position) do
      def key = item.key
      def issue_url = item.issue_url
      # An issue that was closed while its item sat on the queue. Worth saying out
      # loud: promoting it would spawn a session to implement something already
      # done. The puller removes these mechanically, but only when it gets to them.
      def issue_closed? = github.present? && !github.open?
      def labels = github&.labels || []
    end

    LooseRow = Data.define(:github, :direction) do
      def held? = github.labels.include?(Issues::Board::HOLD_LABEL)
    end

    # The label the issue gate applies when it refuses to let work start. An issue
    # carrying it is deliberately not on the queue.
    HOLD_LABEL = "hold issue work gate"

    attr_reader :filters, :snapshot, :direction_resolver

    # @param filters [WorkBacklog::Filters]
    # @param snapshot [Issues::GithubSnapshot::Snapshot]
    # @param github_page [Integer] 1-based page of the loose-issue list
    def initialize(filters:, snapshot:, github_page: 1)
      @filters = filters
      @snapshot = snapshot
      @github_page = github_page.to_i
      @github_by_url = snapshot.issues.index_by(&:url)
      @direction_resolver = Direction.new(issue_urls: @github_by_url.keys | backlog_urls)
    end

    # Every queued item the filters admit, in rank order, joined to GitHub.
    def queued_rows
      @queued_rows ||= begin
        ranked = WorkBacklogItem.queued.in_rank_order.pluck(:id)
        positions = ranked.each_with_index.to_h { |id, i| [ id, i + 1 ] }
        scoped(WorkBacklogItem::QUEUED)
          .map { |item| build_row(item, positions[item.id]) }
          .select { |row| direction_matches?(row.direction) }
      end
    end

    # Started items whose session is still alive, newest start first. Not filtered
    # by the queue filters: "what is the fleet working on right now" is a fixed
    # question, and a repo filter that emptied it would read as "nothing running".
    def in_flight_rows
      @in_flight_rows ||= WorkBacklogItem.in_flight
                                         .includes(:started_session)
                                         .order(started_at: :desc)
                                         .map { |item| build_row(item, nil) }
    end

    # Open GitHub issues with no live backlog row, filtered by the repo and
    # direction the filter bar is set to. This is the half of the page that is
    # "what is going on in GitHub" rather than "what is on the queue".
    #
    # "Live" is exactly what the two lists above show — `queued`, plus `started`
    # with a session that is still alive. NOT every `started` row: an item whose
    # session failed or was archived is not queued, is not in flight, and if it
    # were excluded here as well its open issue would disappear from the page
    # entirely. That is the ordinary "a pull or a promote started it and the
    # session died" case, and the honest answer is that the issue is open and
    # nobody is working it.
    def loose_rows
      @loose_rows ||= begin
        live = (WorkBacklogItem.queued.where.not(issue_url: nil).pluck(:issue_url) +
                WorkBacklogItem.in_flight.where.not(issue_url: nil).pluck(:issue_url)).to_set

        snapshot.issues
                .select { |issue| issue.open? && !live.include?(issue.url) }
                .map { |issue| LooseRow.new(github: issue, direction: direction_for.call(issue)) }
                .select { |row| loose_row_matches?(row) }
                .sort_by { |row| [ row.github.repo, -row.github.number ] }
      end
    end

    def loose_total = loose_rows.length
    def loose_page_count = [ (loose_total.to_f / GITHUB_PER_PAGE).ceil, 1 ].max

    # Clamped at BOTH ends. A hand-edited `?gh_page=999` would otherwise render an
    # empty table under "page 999 of 3", with a Previous link to 998 and the
    # reassuring-but-false "every open issue is already on the queue".
    def github_page = @github_page.clamp(1, loose_page_count)
    def loose_page_rows = loose_rows.slice((github_page - 1) * GITHUB_PER_PAGE, GITHUB_PER_PAGE) || []

    # The count strip. Backlog counts are the whole queue, not the filtered slice —
    # a filter narrows what you read, it does not change how much work there is.
    #
    # Exactly what the strip renders and nothing else: every entry here is a
    # COUNT(*) on every page load, so a count the page does not show is a query
    # nobody asked for.
    def counts
      @counts ||= {
        queued: WorkBacklogItem.queued.count,
        in_flight: WorkBacklogItem.in_flight.count,
        github_open: snapshot.issues.count(&:open?)
      }
    end

    # Queued items by resolved direction — the "labeled convergent vs divergent"
    # reading of the queue, resolved through the same chain as everything else
    # rather than off the column alone.
    def queued_by_direction
      @queued_by_direction ||= Direction::ALL.index_with { |d| all_queued_rows.count { |row| row.direction.direction == d } }
    end

    # Every open GitHub issue by resolved direction, across every repo.
    def github_by_direction
      @github_by_direction ||= Direction::ALL.index_with do |d|
        open_issue_directions.count { |resolution| resolution.direction == d }
      end
    end

    # Per-repo: how much is open on GitHub, how much of it is queued, and how the
    # open issues split by direction. The orientation strip for the GitHub half.
    RepoSummary = Data.define(:repo, :open_count, :queued_count, :directions, :error)

    def repo_summaries
      @repo_summaries ||= begin
        queued_by_repo = WorkBacklogItem.queued.group(:repo).count
        # Grouped once rather than re-scanned per repo: a `select` per repo over
        # ~1,100 issues is one sweep each to answer what a single sweep answers.
        open_by_repo = snapshot.issues.select(&:open?).group_by(&:repo)

        GithubSnapshot::REPOS.map do |repo|
          issues = open_by_repo.fetch(repo, [])
          # `direction_for`, not the resolver directly — this is the third caller
          # of the memo, and going around it resolved every open issue twice per
          # request.
          directions = issues.map { |issue| direction_for.call(issue).direction }.tally
          RepoSummary.new(
            repo: repo,
            open_count: issues.length,
            queued_count: queued_by_repo.fetch(repo, 0),
            directions: Direction::ALL.index_with { |d| directions.fetch(d, 0) },
            error: snapshot.errors[repo]
          )
        end
      end
    end

    # The issues the trend chart folds over: every issue GitHub returned, open or
    # closed-within-the-window, narrowed by the repo filter if one is set.
    #
    # The DIRECTION filter is deliberately not applied here. Narrowing the chart
    # to one direction and then segmenting it by direction leaves a single line
    # and throws away the comparison the chart exists to make — "is the divergent
    # pile growing faster than the convergent one" is a question about both. The
    # repo filter has no such conflict: it narrows the population without
    # collapsing the segmentation.
    def trend_issues
      @trend_issues ||= filters.repo ? snapshot.issues.select { |issue| issue.repo == filters.repo } : snapshot.issues
    end

    # Resolves an issue's direction, memoized per issue URL. Passed to Trend as a
    # callable so it never has to know where directions come from — and shared by
    # the loose list, the per-repo summaries and the count strip, which between
    # them would otherwise resolve the same ~950 issues three times over.
    def direction_for
      @direction_for ||= begin
        cache = {}
        ->(issue) { cache[issue.url] ||= direction_resolver.call(labels: issue.labels, issue_url: issue.url) }
      end
    end

    # The vocabularies the filter selects offer, drawn from the queue rather than
    # from a constant: a `kind` or a `surface` the gate starts writing should show
    # up without a deploy.
    def surface_options = WorkBacklogItem.distinct.order(:surface).pluck(:surface)
    def kind_options = WorkBacklogItem.distinct.order(:kind).pluck(:kind)
    def repo_options = (WorkBacklogItem.distinct.pluck(:repo) | GithubSnapshot::REPOS).sort

    private

    def all_queued_rows
      @all_queued_rows ||= WorkBacklogItem.queued.in_rank_order.map { |item| build_row(item, nil) }
    end

    def open_issue_directions
      @open_issue_directions ||= snapshot.issues.select(&:open?).map { |issue| direction_for.call(issue) }
    end

    # Whether a resolved direction passes the filter bar. Applied in Ruby, after
    # resolution, on BOTH halves of the page — `filters.scope` can only filter the
    # `scope_direction` COLUMN, and the column is the second of the four sources
    # Issues::Direction consults. Filtering the queue on the column while the pill
    # beside it shows the resolved value is how a row ends up visible under
    # "divergent" with a "convergent" pill on it.
    def direction_matches?(resolution)
      filters.scope_direction.nil? || resolution.direction == filters.scope_direction
    end

    def backlog_urls
      WorkBacklogItem.where.not(issue_url: nil).pluck(:issue_url)
    end

    # The filter object's own scope, forced to one status and with the direction
    # filter lifted out. `filters.scope` already applies status; the queued and
    # in-flight lists want two different ones from the same filter set. And
    # `scope_direction` is applied in Ruby by #direction_matches? instead, on the
    # resolved direction — leaving it here as well would compose two different
    # readings of the same filter and hide rows that satisfy either.
    def scoped(status)
      filters.scope.unscope(where: :status).unscope(where: :scope_direction).where(status: status)
    end

    def build_row(item, position)
      github = item.issue_url && @github_by_url[item.issue_url]
      Row.new(item: item, github: github, direction: direction_resolver.for_item(item, github), position: position)
    end

    # The loose list honours the two filters that mean the same thing on both
    # halves of the page. The queue-only filters (kind, cost, pinned, added_by)
    # have no counterpart on a GitHub issue, so they narrow the queue and leave
    # this list alone rather than silently emptying it.
    def loose_row_matches?(row)
      return false if filters.repo && row.github.repo != filters.repo

      direction_matches?(row.direction)
    end
  end
end

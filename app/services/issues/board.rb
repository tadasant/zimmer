# frozen_string_literal: true

module Issues
  # The Issues page, assembled: the fleet's work backlog joined to what is going
  # on in GitHub across the five repos.
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
    # Loose GitHub issues are paginated: five repos carry ~500 open issues between
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

    attr_reader :filters, :snapshot, :direction_resolver, :github_page

    # @param filters [WorkBacklog::Filters]
    # @param snapshot [Issues::GithubSnapshot::Snapshot]
    # @param github_page [Integer] 1-based page of the loose-issue list
    def initialize(filters:, snapshot:, github_page: 1)
      @filters = filters
      @snapshot = snapshot
      @github_page = [ github_page.to_i, 1 ].max
      @github_by_url = snapshot.issues.index_by(&:url)
      @direction_resolver = Direction.new(issue_urls: @github_by_url.keys | backlog_urls)
    end

    # Every queued item the filters admit, in rank order, joined to GitHub.
    def queued_rows
      @queued_rows ||= begin
        ranked = WorkBacklogItem.queued.in_rank_order.pluck(:id)
        positions = ranked.each_with_index.to_h { |id, i| [ id, i + 1 ] }
        scoped(WorkBacklogItem::QUEUED).map { |item| build_row(item, positions[item.id]) }
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
    def loose_rows
      @loose_rows ||= begin
        live = WorkBacklogItem.where(status: [ WorkBacklogItem::QUEUED, WorkBacklogItem::STARTED ])
                              .where.not(issue_url: nil).pluck(:issue_url).to_set

        snapshot.issues
                .select { |issue| issue.open? && !live.include?(issue.url) }
                .map { |issue| LooseRow.new(github: issue, direction: direction_resolver.call(labels: issue.labels, issue_url: issue.url)) }
                .select { |row| loose_row_matches?(row) }
                .sort_by { |row| [ row.github.repo, -row.github.number ] }
      end
    end

    def loose_total = loose_rows.length
    def loose_page_count = [ (loose_total.to_f / GITHUB_PER_PAGE).ceil, 1 ].max
    def loose_page_rows = loose_rows.slice((github_page - 1) * GITHUB_PER_PAGE, GITHUB_PER_PAGE) || []

    # The count strip. Backlog counts are the whole queue, not the filtered slice —
    # a filter narrows what you read, it does not change how much work there is.
    def counts
      @counts ||= {
        queued: WorkBacklogItem.queued.count,
        in_flight: WorkBacklogItem.in_flight.count,
        started: WorkBacklogItem.started.count,
        removed: WorkBacklogItem.removed.count,
        pinned: WorkBacklogItem.queued.pinned_items.count,
        github_open: snapshot.issues.count(&:open?)
      }
    end

    # Queued items by resolved direction — the "labeled convergent vs divergent"
    # reading of the queue, resolved through the same chain as everything else
    # rather than off the column alone.
    def queued_by_direction
      @queued_by_direction ||= Direction::ALL.index_with { |d| all_queued_rows.count { |row| row.direction.direction == d } }
    end

    # Every open GitHub issue by resolved direction, across all five repos.
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
        GithubSnapshot::REPOS.map do |repo|
          issues = snapshot.issues.select { |issue| issue.repo == repo && issue.open? }
          RepoSummary.new(
            repo: repo,
            open_count: issues.length,
            queued_count: queued_by_repo.fetch(repo, 0),
            directions: Direction::ALL.index_with { |d| issues.count { |i| direction_resolver.call(labels: i.labels, issue_url: i.url).direction == d } },
            error: snapshot.errors[repo]
          )
        end
      end
    end

    # The issues the trend chart folds over: every issue GitHub returned, open or
    # closed-within-the-window, narrowed by the repo filter if one is set so the
    # chart answers the same question as the table under it.
    def trend_issues
      @trend_issues ||= filters.repo ? snapshot.issues.select { |issue| issue.repo == filters.repo } : snapshot.issues
    end

    # Resolves an issue's direction for the chart. Passed as a callable so Trend
    # never has to know where directions come from.
    def direction_for
      @direction_for ||= ->(issue) { direction_resolver.call(labels: issue.labels, issue_url: issue.url) }
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

    def backlog_urls
      WorkBacklogItem.where.not(issue_url: nil).pluck(:issue_url)
    end

    # The filter object's own scope, forced to one status. `filters.scope` already
    # applies status; the queued and in-flight lists want two different ones from
    # the same filter set.
    def scoped(status)
      filters.scope.unscope(where: :status).where(status: status)
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
      return false if filters.scope_direction && row.direction.direction != filters.scope_direction

      true
    end
  end
end

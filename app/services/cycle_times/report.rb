# frozen_string_literal: true

module CycleTimes
  # "Where did the time go" over a window of finished hierarchies.
  #
  # The one reading of the cycle_time_analyses table that the Cycle Time page,
  # GET /api/v1/cycle_times and `get_cycle_time` share, so the three can never
  # answer the same question differently. Reads only persisted rows.
  #
  # A row belongs to the window its hierarchy FINISHED in (its last archive), so
  # "yesterday's runs" are the tasks that completed yesterday.
  class Report
    TOP_SEGMENTS = 10

    attr_reader :window, :agent_root

    # @param window [CostWindow] the same window object the Token Spend page uses
    # @param agent_root [String, nil] restrict to hierarchies whose root ran in it
    def initialize(window:, agent_root: nil)
      @window = window
      @agent_root = agent_root.presence
    end

    def from = window.from
    def to = window.to

    # Eligible rows, newest first, without the heavy segment columns.
    def rows(limit: nil, offset: 0)
      scope = eligible_scope.select(CycleTimeAnalysis.list_columns).order(finished_at: :desc, id: :desc)
      scope = scope.limit(limit).offset(offset) if limit
      scope.to_a
    end

    def count = eligible_scope.count

    # The longest tasks in the window, without the heavy columns.
    def slowest(limit)
      eligible_scope.select(CycleTimeAnalysis.list_columns).order(wall_seconds: :desc, id: :desc).limit(limit).to_a
    end

    # Category totals summed over every eligible row — hierarchy time, so the
    # parts add up to `wall_seconds`.
    def totals
      @totals ||= sum_json(:category_seconds)
    end

    # The same, counting each session's own time (overlap counted twice).
    def session_totals
      @session_totals ||= sum_json(:session_category_seconds)
    end

    def wall_seconds
      @wall_seconds ||= eligible_scope.sum(:wall_seconds).to_f
    end

    def family_totals
      totals.each_with_object(Hash.new(0.0)) do |(key, seconds), out|
        out[Categories.fetch(key).family] += seconds if Categories::BY_KEY[key]
      end
    end

    def top_waits(limit = 5)
      totals.select { |key, _| Categories.wait?(key) }.sort_by { |_, s| -s }.first(limit)
    end

    # Percentiles of per-hierarchy wall-clock, in seconds.
    def wall_percentiles
      values = eligible_scope.order(:wall_seconds).pluck(:wall_seconds)
      return {} if values.empty?

      { "p50" => percentile(values, 0.5), "p90" => percentile(values, 0.9), "max" => values.last }
    end

    # The single segments that cost the most hierarchy time across the window,
    # each naming its hierarchy and session.
    def top_segments(limit = TOP_SEGMENTS)
      eligible_scope.pluck(:root_session_id, :title, :top_segments).flat_map do |root_id, title, segments|
        Array(segments).map { |segment| segment.merge("root_session_id" => root_id, "task" => title) }
      end.sort_by { |segment| -segment["seconds"].to_f }.first(limit)
    end

    # How many settled hierarchies in the window were NOT autonomous, by reason.
    def ineligible_counts
      window_scope.ineligible.group(:ineligible_reason).count
    end

    # Archived roots in the window the sweep has not reached yet — so a thin
    # window can say "still computing" rather than look like no work happened.
    def pending_count
      CycleTimeSweepJob.candidate_scope.where(archived_at: from..to).count
    end

    def to_h(rows_limit: 20)
      {
        window: { from: from.iso8601, to: to.iso8601, label: window.label },
        agent_root: agent_root,
        eligible_hierarchies: count,
        ineligible_hierarchies: ineligible_counts,
        pending_hierarchies: pending_count,
        wall_seconds: wall_seconds.round(1),
        wall_percentiles: wall_percentiles.transform_values { |v| v.round(1) },
        categories: category_rows(totals, wall_seconds),
        families: family_totals.map { |family, s| { family: family, seconds: s.round(1), share: share(s, wall_seconds) } },
        top_wait_categories: top_waits.map { |key, s| { category: key, label: Categories.label(key), seconds: s.round(1), share: share(s, wall_seconds) } },
        session_time_categories: category_rows(session_totals, session_totals.values.sum),
        top_segments: top_segments,
        hierarchies: rows(limit: rows_limit).map { |row| self.class.row_summary(row) }
      }
    end

    def self.row_summary(row)
      {
        root_session_id: row.root_session_id,
        title: row.title,
        agent_root: row.agent_root,
        initiator: row.initiator,
        initiator_detail: row.initiator_detail,
        sessions: row.session_count,
        started_at: row.started_at.iso8601,
        finished_at: row.finished_at.iso8601,
        wall_seconds: row.wall_seconds.round(1),
        dominant_wait: row.dominant_wait_category,
        categories: row.ranked_categories.to_h { |key, s| [ key, s.round(1) ] }
      }
    end

    # [{category, label, family, seconds, share}] in Categories order.
    def self.category_rows(totals, denominator)
      Categories.ordered(totals).map do |key, seconds|
        category = Categories.fetch(key)
        share = denominator.to_f.positive? ? (seconds / denominator).round(4) : 0.0
        { category: key, label: category.label, family: category.family, seconds: seconds.round(1), share: share }
      end
    end

    def category_rows(totals, denominator) = self.class.category_rows(totals, denominator)

    private

    def window_scope
      scope = CycleTimeAnalysis.current.finished_between(from, to)
      scope = scope.where(agent_root: agent_root) if agent_root
      scope
    end

    def eligible_scope = window_scope.eligible

    def sum_json(column)
      eligible_scope.pluck(column).each_with_object(Hash.new(0.0)) do |hash, out|
        hash.each { |key, seconds| out[key] += seconds.to_f }
      end
    end

    def share(part, whole)
      whole.to_f.positive? ? (part / whole).round(4) : 0.0
    end

    def percentile(sorted, fraction)
      # Nearest-rank: the smallest value at or above +fraction+ of the rows.
      sorted[[ (fraction * sorted.size).ceil - 1, 0 ].max]
    end
  end
end

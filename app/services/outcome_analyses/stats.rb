# frozen_string_literal: true

module OutcomeAnalyses
  # The summary-stats view's numbers, computed entirely from the denormalized
  # columns on `outcome_analyses`.
  #
  # No Segment tree is ever loaded here. `segment_count` and
  # `failure_segment_count` were written at save time precisely so that
  # "what fraction of all segments failed, grouped by model" is one GROUP BY over
  # an index rather than a fold over thousands of JSON documents.
  class Stats
    # The dimensions the view can group by. Each is a column on the analysis row
    # (frozen at save time), not a join back to `sessions` — an analysis is a
    # statement about the session as it was, and a session later re-pointed at a
    # different model does not retroactively change what was analyzed.
    GROUPINGS = {
      "agent_runtime" => { label: "Harness", column: "agent_runtime" },
      "model" => { label: "Model", column: "model" },
      "agent_root" => { label: "Agent root", column: "agent_root" }
    }.freeze
    DEFAULT_GROUPING = "agent_runtime"

    # Buckets for the failure-segment distribution. The interesting shape is at
    # the low end — most transcripts have a handful of failed segments, and the
    # tail is what you go looking for — so the buckets are fine-grained there and
    # open-ended at the top.
    DISTRIBUTION_BUCKETS = [
      { label: "0", range: (0..0) },
      { label: "1", range: (1..1) },
      { label: "2", range: (2..2) },
      { label: "3–5", range: (3..5) },
      { label: "6–10", range: (6..10) },
      { label: "11+", range: (11..Float::INFINITY) }
    ].freeze

    Row = Data.define(:key, :label, :transcripts, :successes, :failures, :segments, :failed_segments) do
      def transcript_success_rate = transcripts.zero? ? nil : successes.to_f / transcripts
      def segment_success_rate = segments.zero? ? nil : (segments - failed_segments).to_f / segments
      def avg_segments = transcripts.zero? ? 0.0 : segments.to_f / transcripts
      def avg_failed_segments = transcripts.zero? ? 0.0 : failed_segments.to_f / transcripts
    end

    attr_reader :filters, :grouping

    def initialize(filters:, grouping: DEFAULT_GROUPING)
      @filters = filters
      @grouping = GROUPINGS.key?(grouping.to_s) ? grouping.to_s : DEFAULT_GROUPING
    end

    def grouping_label = GROUPINGS.fetch(@grouping)[:label]

    def any?
      totals.transcripts.positive?
    end

    # The whole filtered population as one Row, so the header and the table use
    # the same arithmetic.
    def totals
      @totals ||= begin
        row = scope.pick(*aggregate_expressions)
        build_row("all", "All analyzed transcripts", row)
      end
    end

    # One Row per value of the current grouping dimension, busiest first.
    def rows
      @rows ||= begin
        grouped = scope.group(Arel.sql(group_column)).pluck(Arel.sql(group_column), *aggregate_expressions)
        grouped
          .map { |key, *aggregates| build_row(key, key.presence || "(unattributed)", aggregates) }
          .sort_by { |row| -row.transcripts }
      end
    end

    # Histogram of failure-segment counts across the filtered population.
    def failure_distribution
      @failure_distribution ||= begin
        counts = scope.group(:failure_segment_count).count
        DISTRIBUTION_BUCKETS.map do |bucket|
          total = counts.sum { |failures, count| bucket[:range].cover?(failures) ? count : 0 }
          { label: bucket[:label], count: total }
        end
      end
    end

    # The deepest / most failure-heavy transcripts in the filtered population —
    # the rows worth opening. Capped, and never loads a tree.
    def worst_transcripts(limit: 10)
      @worst_transcripts ||= {}
      @worst_transcripts[limit] ||= scope
        .without_tree
        .includes(:session)
        .order(failure_segment_count: :desc, segment_count: :desc, id: :desc)
        .limit(limit)
        .to_a
    end

    private

    def group_column = "outcome_analyses.#{GROUPINGS.fetch(@grouping)[:column]}"

    def aggregate_expressions
      [
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE root_outcome = 'Success')"),
        Arel.sql("COUNT(*) FILTER (WHERE root_outcome = 'Failure')"),
        Arel.sql("COALESCE(SUM(segment_count), 0)"),
        Arel.sql("COALESCE(SUM(failure_segment_count), 0)")
      ]
    end

    def build_row(key, label, aggregates)
      transcripts, successes, failures, segments, failed_segments = Array(aggregates)
      Row.new(
        key: key,
        label: label,
        transcripts: transcripts.to_i,
        successes: successes.to_i,
        failures: failures.to_i,
        segments: segments.to_i,
        failed_segments: failed_segments.to_i
      )
    end

    # Only current analyses, windowed on the ANALYZED SESSION's created_at — the
    # date a user means by "sessions from last week", not the date somebody got
    # round to analyzing them.
    def scope
      relation = OutcomeAnalysis.current.created_between(filters.from_time, filters.to_time)
      relation = relation.where(agent_runtime: filters.agent_runtime) if filters.agent_runtime
      relation = relation.where(model: filters.model) if filters.model
      relation = relation.where(agent_root: filters.agent_root) if filters.agent_root
      relation = relation.where(root_outcome: filters.outcome) unless filters.outcome == LedgerFilters::OUTCOME_ANY
      relation
    end
  end
end

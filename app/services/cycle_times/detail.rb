# frozen_string_literal: true

module CycleTimes
  # One hierarchy's breakdown as data — what GET /api/v1/cycle_times/:id and
  # `get_cycle_time` with `root_session_id` return.
  #
  # Segments are omitted unless asked for: a busy hierarchy has thousands, and
  # the question an agent usually brings ("what held this task up?") is
  # answered by the totals, the per-session totals and the top segments.
  class Detail
    def initialize(analysis)
      @analysis = analysis
    end

    def to_h(include_segments: false)
      a = @analysis
      wall = a.wall_seconds.to_f
      out = Report.row_summary(a).merge(
        eligible: a.eligible,
        ineligible_reason: a.ineligible_reason,
        ineligible_detail: a.ineligible_detail,
        url: "/cycle_times/#{a.root_session_id}",
        categories: category_rows(a.category_seconds, wall),
        session_time_categories: category_rows(a.session_category_seconds, a.session_category_seconds.values.sum),
        top_wait_categories: a.category_seconds.select { |key, _| Categories.wait?(key) }
                              .sort_by { |_, s| -s.to_f }.first(5)
                              .map { |key, s| { category: key, label: Categories.label(key), seconds: s.to_f.round(1) } },
        top_segments: a.top_segments,
        sessions: a.lanes.map { |lane| lane_summary(lane, include_segments) }
      )
      out[:hierarchy_segments] = a.hierarchy_segments.map { |s| segment_hash(s) } if include_segments
      out
    end

    private

    def category_rows(totals, denominator)
      Report.category_rows(totals.transform_values(&:to_f), denominator)
    end

    def lane_summary(lane, include_segments)
      summary = lane.slice("session_id", "parent_session_id", "depth", "title", "agent_root", "start", "end", "archived_by")
      summary["totals"] = Categories.ordered(lane["totals"]).to_h { |key, s| [ key, s.round(1) ] }
      summary["segments"] = lane["segments"].map { |s| segment_hash(s) } if include_segments
      summary
    end

    def segment_hash(segment)
      from, to, category, detail, session_id = segment
      { start: from, end: to, seconds: (to - from).round(2), category: category, detail: detail, session_id: session_id }.compact
    end
  end
end

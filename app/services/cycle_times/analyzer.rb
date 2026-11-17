# frozen_string_literal: true

module CycleTimes
  # Computes and stores one hierarchy's CycleTimeAnalysis.
  #
  # Idempotent: the row is keyed on the root and upserted, so running this twice
  # — the archive hook and the sweep racing, a backfill re-running — writes the
  # same row twice. A hierarchy that is no longer settled (a session was
  # restored, or a new child spawned under it) has its stale row removed rather
  # than left claiming a finished task.
  class Analyzer
    # Bump when the classification or the rollup changes meaning; the sweep
    # recomputes every row written under an older version.
    VERSION = 2

    TOP_SEGMENTS = 15

    # How many segments the detail page draws across ALL lanes. A lane gets an
    # equal share, between LANE_FLOOR and LaneBuilder::MAX_SEGMENTS, so a
    # 300-session hierarchy is still a page a browser renders.
    DISPLAY_BUDGET = 20_000
    LANE_FLOOR = 60

    LOG_PREFIXES = [
      StateLog::STATE_MACHINE, "Spot session held", "Quota exceeded across all", "No usable ", "Provider quota wall"
    ].freeze

    def self.call(root) = new(root).call

    def initialize(root)
      @root = root
    end

    # @return [CycleTimeAnalysis, nil] nil while the hierarchy is in flight
    def call
      hierarchy = Hierarchy.new(@root)
      unless hierarchy.settled?
        CycleTimeAnalysis.where(root_session_id: @root.id).delete_all
        return nil
      end

      changes = changes_by_session(hierarchy.ids)
      human_messages = HumanMessage.where(session_id: hierarchy.ids).to_a
      eligibility = Eligibility.new(hierarchy, changes_by_session: changes, human_messages: human_messages).call

      attributes = base_attributes(hierarchy, eligibility)
      if eligibility.eligible
        lanes = build_lanes(hierarchy, changes)
        reason, detail = Eligibility.missed_wake(hierarchy.sessions.map(&:id).zip(lanes.map(&:missed_wakes)).to_h)
        if reason
          attributes.merge!(eligible: false, ineligible_reason: reason, ineligible_detail: detail.truncate(500))
        else
          attributes.merge!(breakdown(hierarchy, changes, lanes.map(&:segments), attributes[:started_at], attributes[:finished_at]))
        end
      end

      CycleTimeAnalysis.upsert(attributes, unique_by: :root_session_id, record_timestamps: true)
      CycleTimeAnalysis.find_by(root_session_id: @root.id)
    end

    private

    def base_attributes(hierarchy, eligibility)
      started_at = hierarchy.sessions.map(&:created_at).min
      finished_at = [ hierarchy.sessions.map { |s| archived_time(s) }.max, started_at ].max
      {
        root_session_id: @root.id,
        eligible: eligibility.eligible,
        ineligible_reason: eligibility.reason,
        ineligible_detail: eligibility.detail&.truncate(500),
        initiator: eligibility.initiator,
        initiator_detail: eligibility.initiator_detail&.truncate(250),
        title: (@root.title.presence || @root.prompt.to_s.squish).truncate(250),
        agent_root: agent_root_of(@root),
        session_count: hierarchy.sessions.size,
        started_at: started_at,
        finished_at: finished_at,
        wall_seconds: (finished_at - started_at).to_f,
        category_seconds: {},
        session_category_seconds: {},
        dominant_wait_category: nil,
        lanes: [],
        hierarchy_segments: [],
        top_segments: [],
        algorithm_version: VERSION,
        computed_at: Time.current
      }
    end

    BuiltLane = Data.define(:segments, :missed_wakes)

    # One LaneBuilder per session, in hierarchy order.
    def build_lanes(hierarchy, changes)
      sessions = hierarchy.sessions
      children = sessions.group_by(&:parent_session_id)

      sessions.map do |session|
        child_windows = Array(children[session.id]).map { |child| [ child.created_at, archived_time(child) ] }
        builder = LaneBuilder.new(
          span_start: session.created_at,
          span_end: archived_time(session),
          changes: Array(changes[session.id]),
          events: TranscriptEvents.for(session),
          child_windows: child_windows,
          holds_pr: Array(session.custom_metadata&.dig("github_pull_request_urls")).any?,
          root: session.id == hierarchy.root.id
        )
        BuiltLane.new(builder.build, builder.missed_wakes)
      end
    end

    def breakdown(hierarchy, changes, built, started_at, finished_at)
      sessions = hierarchy.sessions

      rollup = Rollup.new(built, start: started_at, finish: finished_at).call
      totals = round_totals(rollup.totals)

      {
        category_seconds: totals,
        session_category_seconds: round_totals(rollup.summed_totals),
        dominant_wait_category: totals.select { |key, _| Categories.wait?(key) }.max_by { |_, s| s }&.first,
        lanes: sessions.each_with_index.map do |session, i|
          lane_json(session, hierarchy, built[i], changes, started_at, display_max: display_max(sessions.size))
        end,
        hierarchy_segments: hierarchy_display(rollup.segments, sessions, started_at, display_max(sessions.size)),
        top_segments: top_segments(rollup.contributions, built, sessions, started_at)
      }
    end

    def display_max(lane_count)
      (DISPLAY_BUDGET / (lane_count + 1)).clamp(LANE_FLOOR, LaneBuilder::MAX_SEGMENTS)
    end

    def agent_root_of(session)
      session.metadata&.dig("agent_root_key") || session.subdirectory
    end

    def lane_json(session, hierarchy, segments, changes, started_at, display_max:)
      totals = Hash.new(0.0)
      segments.each { |s| totals[s.category] += s.seconds }
      archive_phrase = StateLog.archive_actors(Array(changes[session.id])).last
      {
        "session_id" => session.id,
        "parent_session_id" => session.parent_session_id,
        "depth" => hierarchy.depths[session.id],
        "title" => (session.title.presence || session.prompt.to_s.squish).truncate(120),
        "agent_root" => agent_root_of(session),
        "start" => offset(session.created_at, started_at),
        "end" => offset(archived_time(session), started_at),
        "archived_by" => archive_phrase,
        "totals" => round_totals(totals),
        "segments" => LaneBuilder.for_display(segments, max: display_max).map { |s| [ offset(s.start, started_at), offset(s.finish, started_at), s.category, s.detail ] }
      }
    end

    # The rolled-up lane, through the same display cut as a session lane.
    def hierarchy_display(merged, sessions, started_at, max)
      lane_of = {}
      segments = merged.map do |s|
        segment = LaneBuilder::Segment.new(s[:start], s[:finish], s[:category], s[:detail])
        lane_of[segment] = s[:lane]
        segment
      end
      LaneBuilder.for_display(segments, max: max).map do |s|
        lane = lane_of[s]
        [ offset(s.start, started_at), offset(s.finish, started_at), s.category, s.detail, lane && sessions[lane].id ]
      end
    end

    def top_segments(contributions, built, sessions, started_at)
      contributions.sort_by { |_, seconds| -seconds }.first(TOP_SEGMENTS).map do |(lane, index), seconds|
        segment = built[lane][index]
        {
          "session_id" => sessions[lane].id,
          "category" => segment.category,
          "detail" => segment.detail,
          "start" => offset(segment.start, started_at),
          "end" => offset(segment.finish, started_at),
          "seconds" => seconds.round(1)
        }
      end
    end

    def changes_by_session(ids)
      scope = Log.where(session_id: ids)
      condition = LOG_PREFIXES.map { "content LIKE ?" }.join(" OR ")
      logs = scope.where(condition, *LOG_PREFIXES.map { |p| "#{Log.sanitize_sql_like(p)}%" })
                  .order(:created_at, :id)
                  .select(:session_id, :created_at, :content)
      logs.group_by(&:session_id).transform_values { |rows| StateLog.parse(rows) }
    end

    # When a session was archived: the column, falling back to its last
    # update for a row archived before the column existed.
    def archived_time(session)
      session.archived_at || session.updated_at
    end

    def offset(time, started_at) = (time - started_at).to_f.round(2)

    def round_totals(totals)
      totals.transform_values { |s| s.to_f.round(2) }.reject { |_, s| s.zero? }
    end
  end
end

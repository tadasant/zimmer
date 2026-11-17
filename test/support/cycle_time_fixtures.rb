# frozen_string_literal: true

# Builds sessions whose timeline and Claude Code transcript follow a script, for
# the Cycle Time tests (and the screenshot seed). A script is a list of steps,
# each stamped with a Time:
#
#   [:state, t, "Turn started on a worker"]     a `[State Machine]` timeline line
#   [:warn, t, "Spot session held ..."]         a raw warning timeline line
#   [:user, t, "prompt text"]                   a user transcript line
#   [:say, t, "assistant text"]                 an assistant text line
#   [:tool, t_call, t_result, "Bash", { ... }]  a tool_use and its tool_result
#   [:archive, t, "session #SELF via the self-session MCP server"]
#                                               (#SELF is the session's own id: a self-archive)
#
# Timeline rows are bulk-inserted so their `created_at` is the scripted time
# and no broadcast fires.
module CycleTimeFixtures
  def build_cycle_time_session(created_at:, script:, parent: nil, title: "Task", **attributes)
    session = Session.create!(
      {
        prompt: "#{title} prompt",
        title: title,
        status: :waiting,
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        parent_session_id: parent&.id
      }.merge(attributes)
    )

    lines = []
    logs = []
    archived_at = nil
    script.each_with_index do |step, i|
      case step.first
      when :state then logs << log_row(session, step[1], "[State Machine] #{step[2]}")
      when :warn then logs << log_row(session, step[1], step[2], level: "warning")
      when :archive
        archived_at = step[1]
        logs << log_row(session, step[1], "[State Machine] Session moved to trash by #{step[2].gsub('#SELF', "##{session.id}")}")
      when :user then lines << { "type" => "user", "timestamp" => step[1].utc.iso8601(3), "uuid" => "u#{i}", "message" => { "role" => "user", "content" => step[2] } }
      when :say then lines << assistant_line(step[1], i, [ { "type" => "text", "text" => step[2] } ])
      when :tool
        _, called, returned, name, input = step
        id = "toolu_#{session.id}_#{i}"
        lines << assistant_line(called, i, [ { "type" => "tool_use", "id" => id, "name" => name, "input" => input || {} } ])
        lines << { "type" => "user", "timestamp" => returned.utc.iso8601(3), "uuid" => "r#{i}",
                   "message" => { "role" => "user", "content" => [ { "type" => "tool_result", "tool_use_id" => id, "content" => "ok" } ] } }
      end
    end

    session.transcript = lines.map(&:to_json).join("\n") if lines.any?
    session.save!
    Log.insert_all(logs) if logs.any?
    columns = { created_at: created_at }
    columns.merge!(status: Session.statuses[:archived], archived_at: archived_at) if archived_at
    session.update_columns(columns)
    session.reload
  end

  # The timeline and transcript of one ordinary turn: queued, started, a prompt,
  # one tool call, a final message, paused.
  def simple_turn(start, tool: [ "Read", { "file_path" => "app/models/session.rb" } ], tool_seconds: 2)
    [
      [ :state, start, "Turn started on a worker" ],
      [ :user, start + 3, "do the thing" ],
      [ :tool, start + 10, start + 10 + tool_seconds, *tool ],
      [ :say, start + 20 + tool_seconds, "done" ],
      [ :state, start + 22 + tool_seconds, "Session paused, waiting for input" ]
    ]
  end

  # A CycleTimeAnalysis row written directly, for tests of the readers. Totals
  # are hierarchy seconds by category; the wall-clock is their sum.
  def create_cycle_time_row(finished_at:, totals:, title: "Task", agent_root: "zimmer", eligible: true, reason: nil)
    root = Session.create!(title: title, prompt: "#{title} prompt", status: :archived, archived_at: finished_at,
                           git_root: "https://github.com/test/repo.git", metadata: { "agent_root_key" => agent_root })
    wall = totals.values.sum.to_f
    CycleTimeAnalysis.create!(
      root_session: root, eligible: eligible, ineligible_reason: reason, title: title, agent_root: agent_root,
      initiator: "trigger", initiator_detail: "Nightly", session_count: 2,
      started_at: finished_at - wall, finished_at: finished_at, wall_seconds: wall,
      category_seconds: eligible ? totals : {}, session_category_seconds: eligible ? totals.transform_values { |v| v * 1.5 } : {},
      dominant_wait_category: totals.select { |k, _| CycleTimes::Categories.wait?(k) }.max_by { |_, v| v }&.first,
      lanes: [ { "session_id" => root.id, "parent_session_id" => nil, "depth" => 0, "title" => title, "start" => 0, "end" => wall,
                 "totals" => totals, "segments" => [ [ 0.0, wall, totals.keys.first, "seeded" ] ] } ],
      hierarchy_segments: [ [ 0.0, wall, totals.keys.first, "seeded", root.id ] ],
      top_segments: totals.map { |k, v| { "session_id" => root.id, "category" => k, "detail" => "#{k} stretch", "start" => 0, "end" => v, "seconds" => v } },
      algorithm_version: CycleTimes::Analyzer::VERSION, computed_at: Time.current
    )
  end

  private

  def log_row(session, at, content, level: "info")
    { session_id: session.id, content: content, level: level, created_at: at, updated_at: at }
  end

  def assistant_line(at, i, content)
    { "type" => "assistant", "timestamp" => at.utc.iso8601(3), "uuid" => "a#{i}-#{content.first['type']}",
      "message" => { "role" => "assistant", "model" => "claude-opus-5-5", "content" => content } }
  end
end

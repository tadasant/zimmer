# frozen_string_literal: true

module Mcp
  module Tools
    # The read side of the Cycle Time view: where autonomous tasks spent their
    # wall-clock. One call answers "where were yesterday's runs bottlenecked?".
    #
    # Reads only the persisted cycle_time_analyses rows through
    # CycleTimes::Report / CycleTimes::Detail — the same objects the page and
    # GET /api/v1/cycle_times render — so it never parses a transcript.
    class GetCycleTime < Tool
      tool_name "get_cycle_time"

      description <<~DESC
        Where autonomous tasks spent their wall-clock time — the Cycle Time view (/cycle_times) as data.

        A **task** is one session hierarchy: a root session and every session it spawned (spawn edges
        only). It counts only if it ran end to end autonomously: every session was archived by an agent
        in the task (itself or another session in the hierarchy), never by a human, a Zimmer sweep or an
        outside session; the human-messages record holds no human message after the initiating prompt;
        and no session slept over an hour past a wake that never fired. A task belongs to the window it FINISHED in, counted whole.

        Each task's wall-clock — first session created to last session archived — is split into
        categories that sum to it exactly:
        - **inference** — the model generating (prompt or tool result → next assistant event), incl. compaction
        - **network** — MCP calls, WebFetch/WebSearch, network shell commands (gh, git push/fetch, curl, installs)
        - **local_io** — Read/Edit/Write/Grep/Glob and local shell commands (tests, builds)
        - **subagent** — blocked on an in-process Task/Agent subagent
        - waits: **wait_ci** (CI wakes, `gh pr checks --watch`), **wait_merge_gate** (holding a PR for the
          merge gate), **wait_deploy** (post-merge runs, deploys), **wait_child** (watching a spawned
          session), **wait_sleep** (other timed self-wakes / shell sleeps), **wait_worker_queue** (turn
          queued for a worker), **wait_spot_hold** (spot gate), **wait_quota_park** (quota parks),
          **wait_human** (MCP elicitation, or a root parked in needs_input until archived)
        - **turn_startup** (worker start → first transcript event) and **unattributed** (wind-down, gaps, and
          sleep past a scheduled wake that did not fire)

        When sessions overlap, each instant is charged once, to the highest-priority thing any session
        was doing: work beats waiting, and a parent waiting on a child is charged to what the child was
        doing. So a large `wait_ci` means the whole task was blocked on CI with nothing else running.
        `session_time_categories` adds every session's own time instead (overlap counted twice).

        **Without `root_session_id`** — the window's aggregate: category totals and shares, family totals,
        the top wait categories, the single segments that cost the most (with their task and session),
        p50/p90 cycle time, how many tasks were excluded as not autonomous (by reason), how many are still
        being computed, and the slowest-first list of tasks.

        **With `root_session_id`** — one task: its totals, per-session totals, top segments, and with
        `include_segments: true` every segment (start/end are seconds from the task's start).

        Example: "where were yesterday's runs bottlenecked?" → `{"from": "<yesterday>", "to": "<yesterday>"}`
        and read `top_wait_categories` and `top_segments`.
      DESC

      MAX_ROWS = 100

      input_schema({
        type: "object",
        properties: {
          days: { type: "integer", minimum: 1, maximum: CostWindow::MAX_DAYS,
                  description: "Window in days counting back from now. Default 7. Ignored when `from` or `to` is given." },
          from: { type: "string", description: "Start of a calendar window, YYYY-MM-DD, inclusive (deployment time zone)." },
          to: { type: "string", description: "End of a calendar window, YYYY-MM-DD, inclusive through the end of that day." },
          agent_root: { type: "string", description: "Only tasks whose root session ran in this agent root." },
          limit: { type: "integer", minimum: 0, maximum: MAX_ROWS,
                   description: "How many tasks to list, slowest first. Default 10." },
          root_session_id: { type: "integer", description: "Return one task's breakdown instead of the aggregate." },
          include_segments: { type: "boolean", description: "With root_session_id: include every segment. Default false." }
        },
        required: []
      })

      def call(args)
        return detail(args) if args["root_session_id"].present?

        window = CostWindow.from_params(days: args["days"], from: args["from"], to: args["to"])
        report = CycleTimes::Report.new(window: window, agent_root: args["agent_root"])
        limit = (args["limit"] || 10).to_i.clamp(0, MAX_ROWS)

        result = report.to_h(rows_limit: 0)
        result[:hierarchies] = slowest(report, limit)
        result[:page_url] = "#{context.base_url}/cycle_times?#{window.to_params.merge(agent_root: report.agent_root).compact.to_query}" if context.base_url.present?
        result
      end

      private

      def detail(args)
        id = args["root_session_id"].to_i
        analysis = CycleTimeAnalysis.find_by(root_session_id: id)
        if analysis.nil?
          session = Session.find_by(id: id)
          hint =
            if session.nil? then "No session #{id}."
            elsif session.parent_session_id then "Session #{id} is not a root; its hierarchy's root is #{CycleTimes::Hierarchy.root_for(session).id}."
            else "Session #{id}'s hierarchy is still in flight or not analyzed yet (the sweep runs every 15 minutes)."
            end
          raise ToolError, hint
        end

        CycleTimes::Detail.new(analysis).to_h(include_segments: args["include_segments"] == true)
      end

      def slowest(report, limit)
        return [] if limit.zero?

        report.slowest(limit).map { |row| CycleTimes::Report.row_summary(row) }
      end
    end
  end
end

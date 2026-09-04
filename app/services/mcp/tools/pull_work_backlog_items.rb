# frozen_string_literal: true

module Mcp
  module Tools
    # The groomer's pull: start the top N queued items as spot sessions, in one
    # call, and record which session each became.
    #
    # In the opt-in `work_backlog` group — see AppendWorkBacklogItem for why the
    # group exists. The puller is stamped from the connection and becomes the
    # parent of every session spawned, so the spawned tree inherits its genesis
    # and sits contiguous with it in the spot queue.
    class PullWorkBacklogItems < Tool
      tool_name "pull_work_backlog_items"

      description <<~DESC
        Pull items off the top of the **work backlog** and start them. For each item this spawns a session on the router root (`#{AgentRootsConfig::ROUTER_ROOT_NAMES.first}`) (goal `#{WorkBacklog::Start::GOAL}`, `scheduling_class: "spot"`, prompt = the issue URL plus "please implement this"), marks the item `started` with that session recorded, and returns both. One transaction per pull: if a spawn fails nothing is marked. This replaces the groomer's read-spawn-remove-PR cycle.

        **Two ways to say which.** `count` starts the top N by rank (0 is a legal, useful no-op that just re-ranks). `keys` starts exactly the items you name, in the order you give them, after you have read them with `get_work_backlog` and re-checked each on GitHub — that is the normal path, since **you must re-check before you start**: the item is a pointer to a live thread, and weeks can pass between an append and a pull. Live means open, no linked open PR, no unarchived session already working it; trusted means the thread's author and every commenter still pass the trust rules as it stands now. A key that is not queued fails the whole call. At most #{WorkBacklog::Pull::MAX} per call, so one bad night is bounded — how many to pull is your WIP arithmetic (`counts.in_flight` from `get_work_backlog` is the number of sessions this backlog produced that are still alive).

        **The one removal you may make.** An item whose issue you found dead goes in `dead` with a `reason` from `#{WorkBacklogItem::MECHANICAL_REMOVAL_REASONS.join(' | ')}`; it is marked `removed` with that reason and this session, not started. Those are facts you observed, not judgements — a removal for any other reason is a human's call and has no agent path. A trust failure is a silent drop: count it, do not comment on the issue, do not quote what you saw.

        **Retrying after an error.** `keys` is safe to retry: an item that was already started fails cleanly as "not queued" and nothing else happens. `count` is not — a retry starts the *next* N. So prefer `keys`, and if a `count` call errors, read `get_work_backlog` (status `started`) before calling again.

        **Rank is carried forward.** The n-th item started gets a spot precedence of this session's own plus (count − n + 1), so the top item runs first and the spawned tree stays contiguous with its parent.

        **Pinned items are pulled like any other** — pinning fixes an item's place in the queue, it does not exempt it. Comment the session URL on the issue afterwards; that is still your job.

        **Returns** JSON: `started` (each item with its `session` id, URL and precedence), `removed`, and the queue's `queued` / `in_flight` counts afterwards.
      DESC

      input_schema({
        type: "object",
        properties: {
          count: { type: "integer", description: "Start the top N queued items by rank. 0–#{WorkBacklog::Pull::MAX}. Mutually exclusive with `keys`." },
          keys: {
            type: "array",
            items: { type: "string" },
            description: "Start exactly these queued items, in this order (e.g. [\"zimmer#498\", \"strad#12\"]). At most #{WorkBacklog::Pull::MAX}."
          },
          dead: {
            type: "array",
            items: {
              type: "object",
              properties: {
                key: { type: "string" },
                reason: { type: "string", enum: WorkBacklogItem::MECHANICAL_REMOVAL_REASONS }
              },
              required: %w[key reason]
            },
            description: "Queued items to remove instead of start, each with the mechanical reason you observed."
          }
        }
      })

      def call(args)
        # A restricted connection may only spawn its allowed roots, and a pull
        # spawns the router root — under either of its names, since a session
        # whose .mcp.json was written under the old one still carries it.
        if args["count"].to_i.positive? || Array(args["keys"]).any?
          enforce_any_allowed_root!(AgentRootsConfig::ROUTER_ROOT_NAMES)
        end

        result = WorkBacklog::Pull.call(
          count: args["count"],
          keys: args["keys"],
          dead: args["dead"],
          acting_session: connection_session,
          removed_by: WorkBacklogItem::MCP
        )

        {
          started: result.started.map { |s| { item: s.item.as_api_json, session: session_json(s.session) } },
          removed: result.removed.map { |r| { key: r.item.key, reason: r.reason, item: r.item.as_api_json } },
          queue: { queued: WorkBacklogItem.queued.count, in_flight: WorkBacklogItem.in_flight.count },
          pulled_by_session_id: context.self_session_id
        }
      rescue WorkBacklog::Pull::InvalidPull, WorkBacklog::Start::NotQueued => e
        raise ToolError, "Nothing was pulled: #{e.message}"
      rescue AgentRootsConfig::AgentRootNotFoundError => e
        raise ToolError, "Nothing was pulled: the #{AgentRootsConfig::ROUTER_ROOT_NAMES.first} agent root is not in the catalog (#{e.message})"
      end

      private

      def connection_session
        return nil unless context.self_session_id

        Session.find_by(id: context.self_session_id)
      end

      def session_json(session)
        {
          id: session.id,
          url: session_url(session),
          title: session.title,
          status: session.status,
          scheduling_class: session.scheduling_class,
          precedence: session.precedence,
          parent_session_id: session.parent_session_id
        }
      end
    end
  end
end

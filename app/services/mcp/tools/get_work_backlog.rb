# frozen_string_literal: true

module Mcp
  module Tools
    # The read half of the work backlog: the queue in rank order, filterable.
    # What the groomer reads before a pull and what the Issues view reads on
    # load. In the `work_backlog` group AND its `_readonly` variant.
    class GetWorkBacklog < Tool
      tool_name "get_work_backlog"

      description <<~DESC
        Read the agent fleet's **work backlog** — the ranked queue of GitHub issues the issue work gate has cleared and nobody has started yet. This replaces reading `WORK_BACKLOG.json`.

        **Returned in rank order.** Highest `precedence` first, then oldest `added_at`, then id — the top of the list is the next thing to be worked. Each queued item carries its 1-based `position` in the whole queue (not just this page), so "the top 3" is `position` 1–3 even when you filter.

        **Ranking, in one paragraph.** `precedence` is an absolute scale (higher is pulled sooner; sparse values; not a 1..N position). An unpinned item sits in a band chosen by its `estimated_cost` — small #{WorkBacklog::Ranking.describe_band("small")}, medium #{WorkBacklog::Ranking.describe_band("medium")}, large #{WorkBacklog::Ranking.describe_band("large")} — so the cheapest work floats to the top and, within a band, first-in is first-out. A `pinned: true` item is a human's hand-placement: it sits wherever they put it, can be anywhere on the scale, and is never moved by an agent. Do not re-rate, renumber or re-band anything; the server does the arithmetic on every append and every pull.

        **Status.** Defaults to `queued`, which is the queue. `started` items are history — each names the `started_session_id` it became; `in_flight` in `counts` is how many of those sessions are still alive, which is the number the groomer's WIP ceiling counts (sessions THIS backlog produced, not the whole spot queue). `removed` items name a `removal_reason` and `removed_by`. Pass `status: "all"` for everything.

        **Filters** narrow the list; none of them changes the order. `limit` defaults to #{WorkBacklog::Filters::DEFAULT_LIMIT} and caps at #{WorkBacklog::Filters::MAX_LIMIT}; page with `offset`. A filter value outside the vocabulary is an error, not an empty result — an empty queue must never be a typo.

        **GitHub stays the source of truth for the issue.** An item is a pointer plus the gate's rating and rank; it does not mirror issue state. Re-check the issue is still open, unclaimed and trusted before you act on an item.

        **Returns** JSON: `counts` (queued / started / removed / in_flight / pinned), `ranking` (the bands), `total_matching`, `items`, and `next_offset` when there are more.
      DESC

      input_schema({
        type: "object",
        properties: {
          status: {
            type: "string",
            enum: WorkBacklogItem::STATUSES + [ WorkBacklog::Filters::ANY_STATUS ],
            description: 'Default "queued" — the queue itself. "started" and "removed" are history; "all" is everything.'
          },
          surface: { type: "string", description: 'The gate surface that rated it: "zimmer", "strad", "motet", "tadasant-internal", "strad-production", "artifacts", …' },
          repo: { type: "string", description: '"owner/name", e.g. "tadasant/zimmer".' },
          scope_direction: { type: "string", enum: WorkBacklogItem::SCOPE_DIRECTIONS },
          kind: { type: "string", description: 'The gate\'s classification: "bug", "tech-debt", "docs", "dep-bump", …' },
          estimated_cost: { type: "string", enum: WorkBacklogItem::COSTS },
          pinned: { type: "boolean", description: "true for only hand-placed items, false for only unpinned ones." },
          key: { type: "string", description: 'One item by its key ("zimmer#498"). Combine with status "all" to see its history.' },
          added_by: { type: "string", description: 'Who appended it: "issue-work-gate", "queue-migration", "human", …' },
          limit: { type: "integer", description: "Items per page. Default #{WorkBacklog::Filters::DEFAULT_LIMIT}, max #{WorkBacklog::Filters::MAX_LIMIT}." },
          offset: { type: "integer", description: "Skip this many matching items; use the `next_offset` from a previous call." }
        }
      })

      def call(args)
        filters = WorkBacklog::Filters.new(args)
        scope = filters.scope
        total = scope.count
        items = scope.offset(filters.offset).limit(filters.limit).to_a
        positions = queue_positions(items)

        {
          filters: filters.describe,
          counts: counts,
          ranking: {
            order: "precedence desc, added_at asc, id asc",
            gap: WorkBacklog::Ranking::GAP,
            bands: WorkBacklog::Ranking.describe_bands
          },
          total_matching: total,
          returned: items.size,
          offset: filters.offset,
          next_offset: (filters.offset + items.size < total ? filters.offset + items.size : nil),
          items: items.map { |item| item.as_api_json.merge(position: positions[item.id]) }
        }
      rescue WorkBacklog::Filters::InvalidFilter => e
        raise ToolError, e.message
      end

      private

      def counts
        {
          queued: WorkBacklogItem.queued.count,
          started: WorkBacklogItem.started.count,
          removed: WorkBacklogItem.removed.count,
          in_flight: WorkBacklogItem.in_flight.count,
          pinned: WorkBacklogItem.queued.pinned_items.count
        }
      end

      # Position in the WHOLE queue, so a filtered page still says where each
      # item stands. Nil for anything not queued.
      def queue_positions(items)
        return {} unless items.any?(&:queued?)

        ranked = WorkBacklogItem.queued.in_rank_order.pluck(:id)
        items.select(&:queued?).to_h { |item| [ item.id, ranked.index(item.id)&.succ ] }
      end
    end
  end
end

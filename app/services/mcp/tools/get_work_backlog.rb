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

        **Status.** Defaults to `queued`, which is the queue. `started` items are history — each names the `started_session_id` it became. In `counts`, `in_flight` is how many of those sessions an agent is still advancing (`running` or `waiting` — a turn on a worker, queued for one, or asleep on a self-wake), and that is the number the groomer's WIP ceiling counts: sessions THIS backlog produced, not the whole spot queue. `parked` is the rest of the unfinished ones — sessions stopped in `needs_input`, waiting on a person, typically holding a PR. A parked session is NOT in flight: nothing advances it without a human, it spends no compute, and counting it would ratchet the ceiling shut as parked items accumulate. Pass `status: "in_flight"`, `"spot_held"`, `"parked"` or `"claimed"` to LIST those items rather than only count them — a growing `parked` pile is a signal to go and get those PRs merged, not to keep pulling. `removed` items name a `removal_reason` and `removed_by`. Pass `status: "all"` for everything.

        **`spot_held` is the one that explains a pull of zero, and you must read it before you report one.** It counts the `in_flight` sessions that are dormant at the SPOT GATE — started, but refused before a turn. It is a SUBSET of `in_flight`, not a fourth slice beside it, and those items keep their WIP slot on purpose: they are assigned work that will run, and `SpotSessionHold` re-checks each one on its own backoff ladder (clamped to an hour) and starts it with no pull involved. A sustained hold is therefore a WAIT, not a deadlock — when the gate opens, the held sessions start themselves, finish, and release the ceiling.

        `spot_held` near zero means the ceiling is genuinely full of work being done, and a pull of zero is the healthy outcome the WIP ceiling exists to produce. Report it as such.

        **`spot_held` at or near `in_flight` means the ceiling is full of work the gate has never started — and you cannot tell from this number alone whether that is healthy, because the gate refuses for two opposite reasons.** Call `get_spot_policy` and read which ceiling is holding:

        - `fleet_cap` — every session slot is taken. The fleet is BUSY, work is finishing, and a pull of zero is correct and healthy.
        - `spot_budget` or `pacing_curve` — a Claude quota window is spent or ahead of its curve. The fleet is IDLE behind a budget window with capacity to spare, and a pull of zero, while still the right action, is NOT evidence of a healthy fleet and must not be reported as one.

        Either way a pull of zero is the correct action — pulling more into a held fleet only grows the pile, so it all resumes at once when the gate opens and blows the same pacing curve. What changes is what you SAY. Give the number and the reason: "pulled 0 — 20 in flight against a ceiling of 20, but 14 of those are held at the spot gate on `pacing_curve`, so the fleet is idle behind quota rather than busy".

        **Filters** narrow the list; none of them changes the order. `limit` defaults to #{WorkBacklog::Filters::DEFAULT_LIMIT} and caps at #{WorkBacklog::Filters::MAX_LIMIT}; page with `offset`. A filter value outside the vocabulary is an error, not an empty result — an empty queue must never be a typo.

        **GitHub stays the source of truth for the issue.** An item is a pointer plus the gate's rating and rank; it does not mirror issue state. Re-check the issue is still open, unclaimed and trusted before you act on an item.

        **Returns** JSON: `counts` (queued / started / removed / in_flight / spot_held / parked / pinned), `ranking` (the bands), `total_matching`, `items`, and `next_offset` when there are more.
      DESC

      input_schema({
        type: "object",
        properties: {
          status: {
            type: "string",
            enum: WorkBacklog::Filters::STATUS_VOCABULARY,
            description: 'Default "queued" — the queue itself. "started" and "removed" are history; "all" is everything. ' \
                         '"in_flight", "spot_held", "parked" and "claimed" narrow "started" by what became of ' \
                         "its session: in flight = an agent is still advancing it, spot_held = the subset of those " \
                         "the spot gate is holding before a turn, parked = it has stopped on a person, " \
                         "claimed = in flight plus parked. They list the items the matching count reports."
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
          spot_held: WorkBacklogItem.spot_held.count,
          parked: WorkBacklogItem.parked.count,
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

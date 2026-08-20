---
title: Outcome analysis
description: The Outcomes view — decomposing an archived transcript into Transcript Segments, classifying each Success or Failure, and reading the flamegraph. Plus the save API, the MCP tool, and the Analyze All queue.
sidebar:
  order: 5
---

An archived transcript is a record of what an agent did. **Outcome analysis** turns it into a
record of what worked: a tree of *Transcript Segments*, each with a Success or Failure verdict
against its own goal, rendered as a flamegraph you can scan.

The interesting part is the contrast. A transcript that succeeded overall usually contains several
Segments that failed on the way there — a patch that did not compile, a test that stayed red, a
reproduction that never reproduced. Those failures are the signal, and a view that only reported
"this session succeeded" would throw all of it away.

## Zimmer never runs this by itself

Analysis is a full agent session reading a full transcript. It is expensive, so **nothing in Zimmer
triggers it implicitly** — no callback, no poller, no state transition. An analysis exists because
someone clicked Analyze, started an Analyze All batch, or made an explicit API/MCP call. Opening the
Outcomes page analyzes nothing.

Only **archived** sessions are analyzable. A transcript that is still being written is not finished
enough to have an outcome, and both write paths reject one.

## The Transcript Segment

A Segment is one coherent unit of agent work, described by a `Trigger → Goal → Outcome` triplet.
Segments nest, and the whole transcript is the root Segment.

```
Segment {
  id:      string,                        // "S0", "S0.0", "S0.1.2", … depth-first positional
  trigger: { kind: "New" | "Correction", source: "user" | "agent" | "subagent" },
  goal:    { text: string, kind: "Plan" | "Action" },
  outcome: { kind: "Success" | "Failure", explanation: string },
  meta:    { event_range: [string, string] | null, wall_clock_s: number | null,
             tokens_in: number | null, tokens_out: number | null, model: string | null },
  children: Segment[]                     // [] for leaves
}
```

Four rules the server enforces:

- **Outcome is local to the goal.** A Failure Segment under a Success parent is normal, and failures
  do not propagate up. Nothing in Zimmer rolls a child's verdict into its parent's.
- **Ids are positional and deterministic.** Root is `S0`; the children of `S0` are `S0.0`, `S0.1`, …;
  the children of `S0.1` are `S0.1.0`, …. Depth-first. A tree whose ids disagree with its shape is
  rejected, which is what makes the ids safe to use as DOM ids and cross-references.
- **A `Correction` trigger means the prior sibling failed** to deliver its own goal, so the first
  child of any parent can never be a Correction.
- **`outcome.explanation` is required on Success as well as Failure**, capped at 140 characters. It
  renders as the flamegraph's hover tooltip, so it has to be one short clause.

The last two bullets are deliberate deviations from the upstream `agent-transcript-analysis` spec,
which requires an explanation only on Failure. The phase-3 analyzers in that spec — skill
recommendations, MCP recommendations, efficiency analysis, cross-transcript mining — are **not** part
of this schema. Extra keys in a saved tree are ignored, not stored.

## The three surfaces

| Page | What it answers |
| --- | --- |
| `/outcomes` | The ledger: every archived session, its analysis or "not analyzed", and the Analyze buttons |
| `/outcomes/:session_id` | One transcript's flamegraph and its segment table |
| `/outcomes/stats` | Rates and distributions across everything analyzed, grouped by harness, model, or agent root |

The ledger filters on created-at range, agent root, harness, model, analyzed-or-not, and
transcript-level outcome. The filter set travels with you: it survives the switch to stats, it rides
along on every Analyze click, and it is what Analyze All acts on.

### Reading the flamegraph

Each row is a depth. Each cell is a Segment, colored green for Success and red for Failure, and its
width is its **subtree size** — how many Segments it contains — not its wall-clock duration.
Duration is optional in the schema and frequently null, and the question the view answers is "where
did the work go and what failed", not "where did the time go".

Hovering a cell shows its goal, its verdict, and the one-line explanation. Clicking it jumps to that
Segment's row in the dense table below, which lists every Segment depth-first with its trigger, goal
kind, verdict, and explanation.

### Re-analysis supersedes

Analyzing a session that already has an analysis does not duplicate it and does not destroy the old
one. The previous row is stamped `superseded_at` and the new one becomes current; the drilldown
lists the superseded readings underneath. A partial unique index enforces exactly one current
analysis per session, so two analyzers racing on the same transcript cannot both win.

## Analyze All

Analyze All builds a **batch** from the filters currently applied, plus a concurrency number, and
enqueues one item per matching session that has no analysis yet. Membership is frozen when the batch
is created — a session archived while the batch runs does not join it, because a batch that silently
grew would have no honest completion point.

`OutcomeAnalysisBatchPumpJob` is the engine. It runs on a one-minute cron and is kicked directly when
a batch is created. Each wave it:

1. **Reconciles what is in flight.** An item is *succeeded* the moment a current analysis exists for
   its session — the batch's actual goal — which frees its concurrency slot immediately rather than
   holding it until the analyzer session gets round to archiving. An analysis session that reached a
   terminal state with nothing saved fails its item, as does one that has gone quiet for three hours.
2. **Spawns up to `concurrency - in flight` queued items.**

That ordering is what makes `concurrency: 1` strictly sequential: the one slot cannot free and refill
in the same wave without the reconcile having proved the previous analysis landed.

The number you type is honored as typed. `100` really does try to keep a hundred analysis sessions in
flight; nothing clamps it. What makes that survivable is that the batch is visible and stoppable —
the ledger renders its live counts, and **Stop** marks it canceled so the pump stops spawning.
Cancel stops the *queue*, not the analyses already running: killing those would throw away work
already paid for, and what a runaway batch needs stopped is the spawning.

## The analysis session

Clicking Analyze spawns a Zimmer session that reads the target transcript over MCP and saves its
result back. It is:

- on the **`general-agent`** root — analysis needs the transcript, not the analyzed session's
  repository, so the generic root keeps the clone small;
- carrying the **`analyze-transcript-outcomes`** catalog skill, when the catalog has it (see below);
- wired to **`zimmer-sessions`** (`/mcp?tool_groups=sessions`), the least-privileged server that
  carries the save tool;
- **`spot`**-classed, because it is batch work nobody is waiting on and it should yield to work a
  human is watching when the Claude Code quota gets tight — see
  [Spot and priority](/sessions/spot-and-priority/);
- marked in `metadata` with the session it is analyzing, so a 400-session batch is identifiable and
  is kept out of the Outcomes ledger itself.

All three artifact names are overridable per deployment with `OUTCOME_ANALYSIS_SKILL_ID`,
`OUTCOME_ANALYSIS_MCP_SERVER`, and `OUTCOME_ANALYSIS_AGENT_ROOT`.

If the skill is not in the catalog, Zimmer spawns without it rather than failing the click, shows a
banner on the ledger saying so, and relies on the spawn prompt — which carries the whole contract —
to let the session do the job unaided.

## Saving an analysis

Two write paths, one implementation, so they cannot drift.

**MCP** — `save_outcome_analysis`, in the `sessions` tool group (so both the `zimmer` and
`zimmer-sessions` catalog servers carry it; see [Zimmer's MCP server](/extend/mcp-server/)):

```
save_outcome_analysis({
  session_id:          number | string,   // the archived session that was analyzed
  analyzer_session_id: number | null,     // the session that produced the analysis
  schema_version:      "1",
  root:                Segment,
  notes:               string | null
})
```

**REST** — the same payload at `POST /api/v1/outcome_analyses`, with `GET /api/v1/outcome_analyses`
for the list (no trees) and `GET /api/v1/outcome_analyses/:session_id` for one analysis with its
tree.

Both validate the whole tree before storing anything — id scheme, enum values, explanation presence
and length, nesting, and structural ceilings — and reject a malformed one with every problem named
rather than storing it half-understood. A rejected save writes nothing, so retrying after a fix is
safe.

## Why the list pages stay fast

The Segment tree lives in a `jsonb` column that **no list page ever reads**. Everything the ledger
and the stats view filter, group, or sort on — agent root, harness, model, the analyzed session's
`created_at`, the root outcome, the segment and failure counts, the depth — is denormalized onto the
analysis row at save time.

So the ledger is one query joining archived sessions to their current analysis with an explicit
column list that excludes the tree, and the stats view is one `GROUP BY` over an index. Neither
degrades as the number of analyses grows, and neither parses a single JSON document.

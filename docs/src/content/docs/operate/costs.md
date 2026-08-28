---
title: Token spend
description: Zimmer's own ledger of what inference costs — how usage is captured, why it is deduplicated by request id, and why the money is computed on read rather than stored.
sidebar:
  order: 5
---

Zimmer records every Anthropic API call its agents make, and prices them at current list
rates on the **Costs** page. This is Zimmer's own accounting. It is a different thing from
[Quotas](/sessions/spot-and-priority/), which reads Anthropic's rate-limit headers to answer
"how much headroom is left in the window". Costs answers "what did we spend it on". Neither
substitutes for the other, and they can disagree without either being wrong.

## The tables

| Table | Holds | Keyed on |
| --- | --- | --- |
| `session_token_usages` | Inference an agent session did — the bulk of spend | `request_id` |
| `adhoc_token_usages` | Inference Zimmer's own code made outside any session | `request_id` |

A third table, `token_usage_features`, splits each session request across the
context-management features it was carrying. It is an estimate rather than a measurement —
see [Context features](#context-features).

The split is not cosmetic. Ad hoc calls — auto-generated session titles, push-notification
summaries, the CLI status probe — have no session to hang off, so they would be invisible in
the session table by construction. They are also the population most likely to contain a bug
that bills quietly forever, which is a good reason to give them a page of their own rather
than folding them into a total.

## `request_id`, not `uuid`

This is the one detail worth internalising before trusting any number here.

A single API call is written to the transcript JSONL as **several** assistant lines — a
`thinking` block and a `text` block are separate lines — and **every one of those lines
repeats the same `usage` object**. On top of that, resuming a session replays its whole
prior history into a new file, so the same call recurs across files too.

Summing per line, or per line `uuid`, therefore counts one API response once per content
block. Measured against this deployment's own corpus that over-counts tokens by **79%**.
The API's `requestId` is one call, and a unique index on it is what makes the count correct
and the ingestion idempotent.

Two consequences follow from the unique index:

- Re-scanning a file is free, so the recurring sweep and a full backfill can run at once.
- A line with no `requestId` is **skipped** rather than stored under a substitute key.
  Inventing a key is what produced the 79% error in the first place.

Lines whose model is `<synthetic>` are skipped too: those are locally-generated error and
interrupt notices that never reached the API.

## Volumes are stored; prices are not

The tables hold token counts. Dollars are computed on read by `TokenPricing`.

Rates change, models get added, and the useful questions are comparative — *what would this
workload have cost on Sonnet*, *what does last month look like at today's rates*. Baking
dollars into the rows would foreclose all of that and leave a column that silently ages.
Nothing needs a backfill when a price changes; the page just reports differently.

The same reasoning is why the REST API returns its rate table alongside every figure: a
dollar amount without the rates that produced it is not reproducible.

### Cache tokens are three columns, not one

`cache_creation_tokens` is split into `cache_creation_5m_tokens` and
`cache_creation_1h_tokens`, because the two bill differently:

| Bucket | Rate, relative to that model's base input |
| --- | --- |
| Cache read | 0.1× |
| Cache write, 5-minute TTL | 1.25× |
| Cache write, 1-hour TTL | 2× |

A single collapsed `cache_tokens` column cannot be priced at all. The distinction is not
academic: on this deployment cache **writes** are the largest single line item — several
times the cost of everything the models actually produced — and 95% of them are on the
1-hour TTL. A page that showed one cache number would hide both facts.

Older transcript lines predate the `cache_creation` sub-object. Those are charged at the
1-hour rate, the conservative reading and the right one here.

## How usage gets in

`TokenUsageIngestionService` reads the runtime's transcript files and upserts rows. Two jobs drive
it, and **both run themselves** — there is no step here that needs a shell on the production box:

- **`TokenUsageIngestionJob`**, on a 10-minute cron, scanning only files modified in the last
  two hours. The lookback overlaps the interval generously so a missed run, a deploy, or a
  late-written transcript closes itself on the next pass.
- **`TokenUsageBackfillJob`**, on a 5-minute cron, sweeping the whole corpus once. It works
  against a `token_usage_backfills` row — one row per sweep — in two-minute slices, recording a
  cursor after each committed chunk. On the first tick after a deploy, if no sweep has ever
  finished, it starts one. Once one has, the job is an indexed lookup and nothing else, on that
  deploy and every deploy after it.

```sh
bin/rails token_usage:backfill   # same object, no budget, in the foreground — for a developer
bin/rails token_usage:summary    # what is stored, and how far back it goes
```

The rake task is a convenience, not the delivery mechanism. It resumes the run already in flight
rather than starting a competing one.

### Why a job and not a rake task

Getting history into the ledger used to mean somebody SSH'ing into production and running
`rake token_usage:backfill`. That is an operational step this deployment is not supposed to have:
[deploy is the delivery mechanism for ops actions](/operate/deploying/#ops-actions-ship-with-the-deploy),
and the Costs page was quietly wrong until a human found the time.

The property that makes an unattended sweep safe is the one the unique index already gave us:
ingestion is idempotent on `request_id`. A re-swept directory writes nothing, so a slice that dies
mid-chunk, a recurring sweep overlapping the backfill, and a full re-scan all cost time and nothing
else. The cursor only advances on a committed chunk, so an interrupted run resumes rather than
restarting.

`TokenUsageBackfillJob` runs on the `default` queue, deliberately not `pollers`: it holds its
thread for minutes, and `pollers` has three threads shared by the latency-sensitive singleton
pollers.

### How complete is the page?

`TokenUsageBackfill.coverage` is the single answer, rendered three ways so the surfaces cannot
disagree:

| Surface | Shows |
| --- | --- |
| The Costs page | A panel: backfilled or not, progress while sweeping, the date the ledger starts, and a **Re-scan history** button |
| `GET /api/v1/costs` | A `ledger_coverage` object alongside every rollup |
| `get_costs` (MCP) | A **Partial history** warning while sweeping; the covered window once finished |
| Supervisor | `token_usage_backfills` — every sweep, its cursor, counters and last error, read-only |

`covers_since` is the oldest call actually stored — the only defensible answer to "how far back
does this go". Before a backfill it is roughly the deploy that shipped ingestion; after one it is
the oldest transcript on disk.

A re-scan can be asked for from the page's button, `POST /api/v1/costs/backfill`, or the
`backfill_token_usage` action on the `action_health` MCP tool. All three are the same idempotent
request: they join a sweep already in flight rather than starting a second.

Ingestion deliberately does **not** hook into `TranscriptPollerService`. That service is a
live-broadcast path running inside `AgentSessionJob`, so hanging accounting off it would put
a write on a hot path — and it would still miss both sessions that finished before the
feature existed and the app's own `claude -p` calls, which have no session and therefore no
poller.

### How a transcript is attributed

Transcripts live under `~/.claude/projects/<sanitized-working-directory>/`, and that
directory name is the only evidence of what produced them.

| Directory | Goes to | Labelled |
| --- | --- | --- |
| `-home-rails--zimmer-clones-…` | `session_token_usages` | agent root from the clone subdirectory |
| `-rails` | `adhoc_token_usages` | `cli_status_probe` |
| `…headless-inference…` | `adhoc_token_usages` | `session_title` |
| anything else | `adhoc_token_usages` | `unknown` |

Linking a row back to a `Session` uses two strategies, because neither covers the corpus
alone: the transcript filename is `<session_id>.jsonl` for a main transcript, and the clone
directory (created per session) covers `agent-*.jsonl` subagent files and resumed sessions
whose runtime uuid drifted. A row that matches neither is still stored — spend that happened
is still spend — and shows up as unattributed rather than disappearing.

## Picking a window

The Costs page carries both a set of one-click horizons — 24 hours, 7 days, 30 days,
90 days, 1 year — and an explicit from/to calendar range. Both resolve through `CostWindow`,
which is also what every drilldown link on the page carries, so clicking into a breakdown
never silently changes the window under you.

The calendar fields are plain `<input type="date">` elements. That is the control a phone
renders as its own native calendar, and it needs no JavaScript. A reversed range is swapped
rather than rejected, a half-filled one still resolves, and a span longer than a year is
clamped to the most recent 365 days rather than handed to Postgres as a full-table scan.

The same window is expressible over MCP and REST: `get_costs` takes `days`, or `from`/`to`
as `YYYY-MM-DD`; `GET /api/v1/costs` takes `days`, or `from`/`to` as ISO-8601 instants.

## Drilling in

The daily-spend chart and the breakdown tables both reveal what is behind a figure.

- Each bar in the daily chart is a **button**. Hovering it on a pointer device, or tapping
  it on a phone, fills the readout strip below the chart with that day's session/ad-hoc
  split, tokens, calls, and biggest agent roots. The readout sits in normal flow rather
  than floating over the bar, which is what makes it legible at a 375px viewport.
- Each row in a breakdown table is a `<details>` element. It opens on click, on tap, on
  Enter, and with JavaScript disabled; `hover_details_controller.js` adds hover-to-open on
  pointer devices only, and a row you opened deliberately stays open when the pointer leaves.

Every figure a drilldown shows is precomputed in the same cached snapshot as the page — the
per-day and per-root detail come from one extra grouped query each, not one query per bar.

## Per-session cost

Each dashboard card and each session detail page carries the session's own total, in muted
gray. It is a secondary signal, not a headline: it sits beside the session id and the
timestamp rather than anywhere prominent.

The figure comes from `SessionTokenUsage.cost_by_session`, one grouped query per rendered
collection, warmed by `preload_session_costs` in each partial that renders a list of cards.
A per-card lookup would be a per-card round trip on a page that renders hundreds of them.

A session with no stored usage renders **nothing** rather than `$0.00` — usually it just
means its transcript has not been swept yet, and a zero would assert it was free.

## Burn rate by harness + model

The Costs page answers "what did we spend"; the scheduler needs "what does a minute of this cost".
`BurnRateRecomputeJob` derives the second from the first every 20 minutes and writes it to
`harness_model_burn_rates`, one row per (harness, model).

The rate is **dollars per minute of elapsed session time**: for each of the last
`HarnessModelBurnRate::SAMPLE_SESSIONS` (25) sessions of that combination, the cost of its calls over
the span from its first to its last, summed across the sample before dividing. Summing before
dividing is deliberate — averaging per-session rates would give a two-call session the same weight as
a two-hour one. A session with a single call is floored at one minute rather than dividing by zero.

`harness` is the **agent root**, the same dimension the by-root table above breaks spend down by,
because that is what predicts a session's spend shape: a router turn and a merge-gate turn move very
different money on the same model.

The prices are `TokenPricing`'s, applied through the same `cost_sum_sql` the rest of this page uses.
There is deliberately no second pricing path — a rate priced differently from the page would make
"this session burns $0.40 a minute" and "this root spent $6,116 this week" two numbers nobody could
reconcile.

The [spot gate](/sessions/spot-and-priority/#the-gate) multiplies these by its re-check interval to
project what admitting one more session will spend before anyone looks again. A combination that has
never been sampled is priced at the cost-weighted fleet average rather than at nothing, so an unknown
harness cannot look free; a combination with no spend in the last 30 days has its row dropped rather
than left to inform the scheduler forever.

## Context features

`token_usage_features` answers a question the usage tables cannot: not *what did this call
cost*, but *what was it carrying*. The injected goal block, the session hierarchy, the
human-message record, skill bodies, MCP responses, tool output, extended thinking — each is
a decision someone made, each bills again on every turn it stays in the context, and none of
them is individually visible in a bill.

### These numbers are estimates, and the page says so

The API reports one `usage` total per request with **no per-content-block decomposition**.
Nothing it returns says how many input tokens were the goal text versus a skill definition
versus an MCP tool result. So a per-feature figure cannot be measured — it can only be
estimated from what the transcript records, and the estimate is built so it cannot mislead:

1. `ContextFeatureAttributor` walks each transcript in order, measuring the characters each
   feature contributes.
2. Characters convert to tokens at a fixed ratio — **3.7**, which is measured rather than
   guessed. Between two consecutive requests the fixed prompt prefix cancels, so the change
   in billed tokens over the change in transcript characters reads the ratio directly; over
   2,782 such pairs on this deployment the median is 3.57 and the mean 3.93. Re-measure with
   `rake token_usage:calibrate_chars_per_token`.
3. Every share is divided by `max(estimated, actual)`, so the parts can never exceed the
   request's real totals. When the estimate overshoots, all shares scale down together
   rather than any one being trusted.
4. Whatever is left is carried as an explicit **unattributed** line, never spread across the
   features.

That residual is large, and its size is the finding rather than a defect: on this
deployment about **56% of tokens** are unattributed. It is the fixed prompt prefix — the
harness system prompt and the tool schemas of every MCP server attached to the session —
plus per-request web-search charges. None of it appears in a transcript. Because it is a
per-request *constant*, the lever that shrinks it is attaching fewer tools to a session,
not writing shorter prompts.

### Marginal, not cumulative — and why dollars ≠ tokens

Content added at turn 3 is in the prompt for every turn after it, so "the goal block is
3,600 characters" does not answer "what did the goal cost". The attributor keeps two buckets
per conversation:

| Bucket | What it holds | What it is billed as |
| --- | --- | --- |
| `carried` | everything already in the prompt | cache **read**, at 0.1× base input |
| `pending` | everything added since the last request | cache **write**, at 1.25× or 2× |

`cache_read_tokens` splits across `carried`; `input_tokens + cache_creation_*` across
`pending`; `output_tokens` across the assistant's own blocks. This is why the page reports
both tokens and dollars and why they rank differently: a feature re-appended to every turn
is cache-written at up to 2× on every turn, while one that lands once in the prefix is
written once and read back at a tenth forever after. **Dollars is the column that decides.**

### Adding a feature

Append one entry to `ContextFeatureRegistry` and re-run ingestion:

```ruby
feature(
  key: "my_thing",
  label: "My thing",
  blurb: "One line the page shows under the bar.",
  owner: :zimmer,
  pattern: %r{<my-thing>[\s\S]*?</my-thing>}   # or a block: { |block| block.type == "tool_result" }
)
```

That is the whole procedure. Because ingestion is a re-runnable scanner over the transcripts
on disk, a detector written today is backfilled over everything still retained — no
instrumentation at the call site, no waiting for fresh data.

**Retention bounds the backfill.** Claude Code prunes `~/.claude/projects` on its own
schedule; on this deployment the corpus goes back about **30 days** in bulk. A new detector
can therefore see roughly the last month, not all history. The usage rows already ingested
keep their totals — only the per-feature split is limited.

`owner` is what makes the table actionable. `:zimmer` marks the features this repository
chose to inject and can therefore choose to stop injecting, shrink, or serve from a cheaper
model; `:harness` and `:work` are cost you can see but not directly legislate.

### When a feature moves rather than disappears

Dropping an injected block usually means the content still gets read — it just arrives another
way. Provenance is the worked example: `session_hierarchy` and `human_messages` are no longer
injected at all, and what a session fetches with `get_session_provenance` instead lands on its own
`provenance_tool` line rather than in the shared "MCP responses" bucket. Without that third line the
change would read as pure savings while the bytes had merely moved. When you stop injecting
something, give what replaces it a line of its own, placed **before** the generic detector that
would otherwise swallow it.

**Keep the detector for the block you stopped injecting.** Ingestion re-scans the transcripts still
on disk, so a removed detector does not zero a line — it strands a month of history in the residual.
`session_hierarchy` and `human_messages` still match, and trending to zero on new transcripts while
`provenance_tool` picks up is the before/after.

### What the attribution cannot see

- **Extended thinking is under-counted.** The harness writes `thinking: ""` into the
  transcript and keeps only the cryptographic signature — across 955 thinking blocks in this
  deployment's recent corpus, not one retained its text. The signature is counted; the
  reasoning is not, and the difference lands in the residual. No detector can fix this.
- **System reminders are rarely persisted**, so the CLAUDE.md contents injected on the first
  turn usually fall into the residual too.
- **Server-tool charges are not split.** A web search bills per request, not per token, and
  there is no defensible way to divide a per-request charge across the content features
  inside that request. It stays on the parent row and lands in the residual.
- **Volume.** The table grows at roughly the number of features detected per request — about
  8× the parent table. `request_id` carries a foreign key to the parent's unique index, so
  deleting a usage row takes its attribution with it.

Check the reconciliation yourself at any time:

```sh
bin/rails token_usage:attribution_report DAYS=30
bin/rails token_usage:calibrate_chars_per_token
```

## Experimental settings

An **experimental setting** is a global switch that changes how Zimmer drives its agents —
MCP tool search is the first, `Settings → Experimental` is where they live, and
`ExperimentalSettingsRegistry` is the catalogue. Every session is tagged with what each one
was **when it started** and **when it last ran**, and the Costs page compares the cohorts
that tagging produces.

The registry is the single edit point. One entry there gives a setting its toggle on the
settings page, its write path in `AppSettingsController`, its per-session tag, and its
section in the report. A setting cannot be togglable and untracked.

### Two values, not one

`session_experimental_flags` stores `value_at_start` and `value_at_end` per (session,
setting). Intermediate toggles are deliberately not tracked; the pair exists to answer a
different question — *is this session's cohort label safe?* A session whose two ends
disagree ran under both values of the setting, so it is bucketed as `mixed` and excluded
from both cohorts rather than rounded into one.

### Observed, not derived

The value could be re-derived at read time from the session's date and the date the setting
shipped. That works exactly once, for the single step change a setting makes when it lands,
and stops working the moment the setting is toggled back. Storing what was actually observed
is what lets cohorts interleave in time — which is the difference between an A/B test and a
before/after chart.

The date-derived path exists only for history that predates the table.
`ExperimentalFlagBackfillJob` labels those sessions from `landed_at` in the registry entry:
`created_at` decides the start value, the session's last recorded API call decides the end
value, and rows written that way are marked `source = "backfilled"`. The report shows how
many of each it is reading.

**The job cannot reach forward past the first live observation**, and that bound is
load-bearing. `landed_at` describes exactly one step change, so it knows nothing about a later
toggle. Without the cutoff, a session parked in `waiting` would be labelled from its creation
date, then run under whatever the setting had since become, and land in `mixed` — the backfill
would silently destroy exactly the interleaved cohort a deliberate toggle was flipped to
collect. The cutoff is `MIN(first_observed_at)` over the observed rows, falling back to an hour
ago on the one tick where nothing has been observed yet and every session really is history.

For `mcp_tool_search` the boundary is **2026-08-22 13:55:34 UTC** (`b59d9ad7`, which shipped
it on for everyone).

### Retiring a setting

When the question a setting was asking has been answered and the losing branch is deleted, its
registry entry and its `AppSetting` column go with it. The `session_experimental_flags` rows already
written under that key are left alone — they honestly record what those sessions ran under — and the
report simply stops rendering a section for a key the registry no longer knows. `provenance_via_mcp`
went that way: the answer was to stop injecting provenance entirely, so there is no longer a switch
to compare across, and the before/after lives on the context-features table instead.

### Why the report hedges as hard as it does

The settings are global, so nothing is randomized and a cohort is "whoever ran while it was
on". For a backfilled setting the cohorts are literally *before this date* and *after this
date*, which perfectly confounds the setting with everything else that changed around then —
including other merges landing the same afternoon. That is stated on screen, next to the
number, rather than in a footnote.

Three things follow from it:

- **Cost per API call is the headline**, not cost per session. Per-session cost mostly
  measures how long sessions happened to be, which is task mix. Per-session is still shown —
  it is what the bill feels like — and labelled as the confounded one.
- **Sample sizes are always on screen**, and a side thinner than 5 sessions or 50 API calls
  in the window prints no percentage at all. A dramatic-looking delta over four sessions
  reads exactly like a real one, which is the failure this refuses.
- **The same agent root is compared against itself** in a drilldown, using only roots present
  on both sides. Holding the root constant removes the largest single source of task mix. It
  does not remove the rest.

The honest reading of a thin report is that the data cannot yet support a claim. That is a
correct outcome, not a broken page.

### Adding a setting

Append an entry to `ExperimentalSettingsRegistry::BUILT_INS` with the `AppSetting` boolean
column that backs it, plus a migration for the column. Set `landed_at` only when the setting
shipped as a step change for everyone; leave it nil and only sessions from then on get
tagged, which is the more honest default for a setting that ships off. A Zimmer Extension
flagged experimental needs nothing at all — it is picked up from
`Zimmer::ExtensionRegistry.experimental` automatically.

## Reading it back

- **Web:** the Costs page, alongside Quotas.
- **REST:** `GET /api/v1/costs` for rollups, `GET /api/v1/costs/records` for the rows
  themselves, paginated and filterable by session, agent root, model, or source. See
  [the REST API](/extend/rest-api/).
- **MCP:** the `get_costs` tool, in the `health` group. Fleet-wide by default; scopeable to
  one agent root or one session, and windowed by `days` or by an explicit `from`/`to`. Every
  report carries the context-feature split, always labelled as an estimate, and the
  experimental-setting cohorts, always labelled as observational.

## What the dollar figures are not

They are **not a bill**. These accounts are subscription-billed, so list price here is a
comparable unit across models — the thing that lets you say Opus cost 4× what Sonnet would
have on the same volumes — rather than money owed.

A model with no rate configured prices at **zero** and is named explicitly on the page, in
the API response, and in the MCP output. That is deliberate: a wrong rate is worse than a
visibly missing one, because it lands inside a total that reads as authoritative. A new
model id showing up in that warning is the signal to add it to `TokenPricing::RATES`.

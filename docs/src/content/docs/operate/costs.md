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

## Two tables

| Table | Holds | Keyed on |
| --- | --- | --- |
| `session_token_usages` | Inference an agent session did — the bulk of spend | `request_id` |
| `adhoc_token_usages` | Inference Zimmer's own code made outside any session | `request_id` |

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

## Reading it back

- **Web:** the Costs page, alongside Quotas.
- **REST:** `GET /api/v1/costs` for rollups, `GET /api/v1/costs/records` for the rows
  themselves, paginated and filterable by session, agent root, model, or source. See
  [the REST API](/extend/rest-api/).
- **MCP:** the `get_costs` tool, in the `health` group. Fleet-wide by default; scopeable to
  one agent root or one session.

## What the dollar figures are not

They are **not a bill**. These accounts are subscription-billed, so list price here is a
comparable unit across models — the thing that lets you say Opus cost 4× what Sonnet would
have on the same volumes — rather than money owed.

A model with no rate configured prices at **zero** and is named explicitly on the page, in
the API response, and in the MCP output. That is deliberate: a wrong rate is worse than a
visibly missing one, because it lands inside a total that reads as authoritative. A new
model id showing up in that warning is the signal to add it to `TokenPricing::RATES`.

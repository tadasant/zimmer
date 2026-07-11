---
title: Architecture
description: How Zimmer is put together — the Rails app, the GoodJob worker, agent subprocesses, and the path from a prompt to a running agent.
sidebar:
  order: 3
---

Zimmer is a Rails 8 monolith with an unusual job: its background workers spawn and supervise
long-lived OS subprocesses that write to the filesystem and talk to the internet.

## The whole system

```mermaid
flowchart TB
    subgraph browser["Browser"]
        UI["Hotwire UI<br/>Turbo Streams + Stimulus"]
    end

    subgraph web["Web process (Puma / Thruster)"]
        RC["Controllers<br/>sessions · triggers · quotas · mcp_oauth"]
        API["REST API<br/>/api/v1/* · X-API-Key"]
        PCR["PeriodicCatalogRefresher<br/>(background thread, 300s)"]
    end

    subgraph worker["Worker process (GoodJob)"]
        ASJ["AgentSessionJob<br/>spawn + monitor loop"]
        CRON["Cron jobs<br/>pollers · token refresh · cleanup"]
    end

    subgraph data["Data"]
        PG[("PostgreSQL<br/>app + solid_cable DB")]
        RD[("Redis<br/>cache")]
    end

    subgraph host["Host filesystem"]
        CLONE["~/.agent-orchestrator/clones/&lt;session&gt;/<br/>git clone · .mcp.json · .claude/skills/"]
        CRED["~/.claude/.credentials.json<br/>~/.codex/auth.json"]
    end

    subgraph proc["Agent subprocess"]
        CLI["claude / codex (headless)"]
        MCP["MCP servers (child processes)"]
    end

    EXT["External<br/>GitHub · Slack · Anthropic · OpenAI"]

    UI <-->|"HTTP + Turbo Stream over Action Cable"| RC
    RC --> PG
    API --> PG
    PG -.->|"solid_cable"| UI
    RC --> RD
    ASJ --> PG
    CRON --> PG
    ASJ -->|"AirPrepareService<br/>(shells out to air CLI)"| CLONE
    ASJ -->|"spawn(pgroup: true)"| CLI
    CLI <--> CLONE
    CLI --> MCP
    CLI -->|"reads"| CRED
    ASJ -->|"polls JSONL transcript"| CLONE
    CLI <--> EXT
    CRON <--> EXT
    PCR --> RD
```

## The processes

**Web (Puma, fronted by Thruster in production).** Serves the UI and the REST API. It runs
no cron. It *does* run one background thread, `PeriodicCatalogRefresher`, which re-runs
`air update` every 300 seconds, because the catalog cache lives on a per-container
filesystem and the web container would otherwise serve a catalog frozen at boot.

**Worker (GoodJob).** Everything that matters happens here: `AgentSessionJob` spawns agents
and monitors them, and roughly two dozen cron jobs poll GitHub, poll Slack, refresh OAuth
tokens, reap zombies, and clean up clones. In development GoodJob runs `:async` (in-process
with Puma); in production and staging it's `:external`, meaning a separate `bundle exec
good_job start` process is required.

:::danger[The shipped Terraform does not run a worker]
`infra/terraform/cloud-init.yaml.tftpl` renders a `docker-compose.yml` with exactly three
services — `app`, `redis`, and (staging only) `db`. There is no worker service and no
`good_job start` anywhere in `infra/`, the Dockerfile, or the workflows, while
`config/environments/production.rb:59` sets `execution_mode = :external`.

On a droplet provisioned by this repo's Terraform, sessions enqueue and never run, and no
cron ever fires. The staging health check only curls `/up`, so it passes anyway. You must
add a worker service yourself. See
[Known limitations](/limitations/#the-shipped-terraform-provisions-no-job-worker).
:::

**Agent subprocess.** A real headless `claude` or `codex` process, spawned with
`pgroup: true` so the whole process group can be killed as a unit. Its stdin and stdout go
to `/dev/null`; stderr goes to a log file inside the clone. The transcript file on disk is
the only channel Zimmer reads output from: both CLIs are launched with a JSON streaming
flag, but the stream itself is discarded.

## Data

**PostgreSQL** holds everything: sessions, logs, transcripts (the entire JSONL file is stored
as a string on `sessions.transcript`), triggers, notifications, OAuth credentials, and the
catalog snapshot. It also backs Action Cable via `solid_cable`, on a second database
(`zimmer_<env>_cable`) that must exist before boot.

**Redis** is the Rails cache only. There is no Redis-backed queue — GoodJob uses Postgres.

**The filesystem** is load-bearing and under-appreciated. Clones live in
`~/.agent-orchestrator/clones/`. Agent credentials live in `~/.claude/.credentials.json` and
`~/.codex/auth.json`, and are read by the CLI, written by Zimmer, and *also* rewritten by the
CLI behind Zimmer's back. See [Agent harness credentials](/auth/harness/).

## From prompt to running agent

This is the path a session takes on `waiting → running`, driven by `AgentSessionJob`:

```mermaid
sequenceDiagram
    autonumber
    participant U as You (UI or API)
    participant S as Session (Postgres)
    participant J as AgentSessionJob (worker)
    participant G as GitClone
    participant A as AIR CLI
    participant Au as RuntimeAuthProvider
    participant P as Agent process

    U->>S: create (prompt, git_root, agent_root, mcp_servers…)
    Note over S: status = waiting
    S->>J: enqueue AgentSessionJob
    J->>S: start! (waiting → running, guard: git_root present)
    J->>G: clone repo into ~/.agent-orchestrator/clones/{slug}
    G-->>J: working_directory
    J->>A: air prepare {adapter} --target WD --without-defaults<br/>--skill … --mcp-server … --hook … --plugin …
    Note over A: writes .mcp.json, .claude/skills/,<br/>.claude/hooks/, substitutes ${SECRETS}
    A-->>J: {configFiles, skillPaths}
    J->>J: post-process MCP config (Claude JSON / Codex TOML)
    J->>J: check MCP OAuth credentials
    alt an MCP server needs OAuth
        J->>S: fail! (failure_reason = oauth_required)
        Note over U: UI shows "Authorize" buttons
    end
    J->>Au: inject_for_session! (write ~/.claude/.credentials.json)
    J->>J: OrchestratorSystemPromptBuilder.build
    J->>P: spawn(claude --dangerously-skip-permissions …<br/>pgroup: true, stderr → claude_stderr.log)
    P-->>J: pid
    loop monitor loop
        J->>P: alive?
        J->>J: poll JSONL transcript → normalize → Turbo Stream to UI
    end
    P-->>J: exit
    J->>S: pause! (running → needs_input) or fail!
```

The steps that most often surprise people:

- **The clone happens before AIR runs**, because AIR's prepare step needs a target directory
  and auto-detects the root from the git remote (though Zimmer passes `--root` explicitly).
- **OAuth is a gate, not a prompt.** If a remote MCP server needs OAuth and has no valid
  credential, the session *fails* with `failure_reason: oauth_required` and the UI renders
  Authorize buttons. Completing the flow resumes it. See [MCP server OAuth](/auth/mcp-oauth/).
- **`--without-defaults` is passed deliberately.** Zimmer stores the final resolved artifact
  lists on the session row, so AIR must not re-add root defaults on top. See
  [How Zimmer consumes AIR](/air/zimmer-integration/).

## Runtimes are a bundle of seams

Zimmer supports two agent harnesses today, `claude_code` and `codex`, and a third would be
additive. A "runtime" is a `RuntimeRegistry::Bundle` struct rather than a class, with twelve
slots, one per place where driving a vendor CLI differs: the CLI adapter, the retry strategy,
the transcript source and normalizer, the MCP status detector, the prompt contribution, the
config post-processor, the auth provider, the credential writer.

Core code never says "Claude." It asks the registry. See
[Adding an agent harness](/extend/agent-harness/).

## Extensions

A thin seam on top of that: `Ao::Extension` lets optional behavior override the CLI adapter,
supply a print-inference backend, or contribute spawn environment variables — without core
naming it. Exactly one ships (`mcp_tool_search`), and the Docker image excludes
`app/extensions/*/` entirely. See [Extensions](/extend/extensions/).

---
title: Skills, plugins, hooks, references
description: The four non-root, non-MCP artifact types — what ships in Zimmer's catalog, and how to add one.
sidebar:
  order: 4
---

## Skills

A skill is a markdown procedure the agent can invoke: "how to run tests here," "how to deploy
staging." It lives in `skills/<id>/SKILL.md` and is registered in `skills/skills.json`.

At prepare time AIR copies it into `.claude/skills/<id>/` in the clone, along with any references it
declares.

**The five that ship**, all `default_in_roots: ["zimmer"]`:

| Skill | What it does |
| --- | --- |
| `sync-docs` | Pre-PR step: update docs that the branch diff made stale. **Always-on by convention.** |
| `zimmer-run-tests` | Run the test suite the way this repo expects. |
| `zimmer-start-dev-server` | Bring up a local instance for e2e verification. |
| `zimmer-deploy-staging` | Drive the staging deploy workflow. |
| `zimmer-change-ai-artifact` | The guide to changing the catalog itself. |
| `awaken-waiting-sessions` | The wake policy for quota-parked spot work. Defaults into `fleet-maintenance` only, and is not user-invocable — the `quota_available` trigger is what runs it. |

The generic workflow skills are vendored here too, under `category: workflow`:

| Skill | What it does |
| --- | --- |
| `open-pr` | Commit, push, open the PR, self-review, subagent-review, wait for CI, then its two terminal steps: apply the `ready to merge` label, and schedule a bounded self-wake so the session sleeps on the PR instead of parking in the action queue. Bundles the `git-workflow` reference. |
| `wait-for-ci` | Block until CI passes or fails on the current PR, in the foreground — and if the turn will end with checks still pending, schedule a bounded self-wake before ending it. On green it hands the `ready to merge` label back to `open-pr`. Bundles the `git-workflow` reference. |
| `recover-from-compaction-thrashing` | Delegate verbose tool calls to subagents so compaction doesn't erase your work. |

:::note[The catalog is the only source of skills]
A standalone Zimmer install inherits nothing from an outside orchestrator, so anything a session
needs — generic or Zimmer-specific — is vendored into `skills/` and registered in `skills.json`.
Everything resolves under a single `@local/` scope, so there is
[no cross-scope shortname collision](/air/zimmer-integration/#the-catalog-is-self-contained-and-offline)
to design around. Do still avoid registering the same id twice: a genuinely broken catalog
hard-fails the resolve and, thanks to the boot-time pre-warm,
[reddens the whole test suite](/air/zimmer-integration/#the-blast-radius-is-the-entire-test-suite).
:::

## References

A markdown document that many skills can share. Broken out from skills deliberately — one reference
(your git workflow, your engineering conventions) shouldn't be copy-pasted into every skill that
needs it.

Zimmer's catalog ships five: `engineering-practices`, `brand`, `brand-voice`,
`anti-slop-rubric`, and `git-workflow`, mapping to `references/ENGINEERING_PRACTICES.md`,
`BRAND.md`, `BRAND_VOICE.md`, `ANTI_SLOP_RUBRIC.md`, and `GIT_WORKFLOW.md`. The `sync-docs`
skill declares three of them; `open-pr` and `wait-for-ci` declare `git-workflow`.

At prepare time, each skill's declared references are bundled into
`.claude/skills/<skill-id>/references/`.

## Plugins

A named bundle that composes existing skills, MCP servers, and hooks. The index entry points at a
directory; the directory holds `.plugin/plugin.json`.

```json
// plugins/ci-workflow/.plugin/plugin.json
{
  "name": "ci-workflow",
  "title": "CI Workflow",
  "version": "1.0.0",
  "skills": ["zimmer-run-tests"],
  "mcp_servers": [],
  "hooks": ["git-push-ci-reminder"]
}
```

**The four that ship:**

| Plugin | Default in | Bundles |
| --- | --- | --- |
| `ci-workflow` | `agent-orchestrator` | `zimmer-run-tests` + `git-push-ci-reminder` |
| `screenshots-videos` | `agent-orchestrator` | screenshot/video capture tooling |
| `figma-design-workflow` | — | Figma design tooling |
| `meeting-wrangling` | — | meeting tooling |

A plugin is a **macro**: at prepare time AIR unions its constituents into the activated set, and they
materialize through the same code path as directly-selected artifacts. Select both a plugin and a
skill it bundles, and you get one copy.

:::note[Inline plugin bodies are deprecated]
AIR 0.13.0 moved plugin bodies out of the index and into `<path>/.plugin/plugin.json`. Zimmer's
catalog already uses the externalized form.
:::

## Hooks

A lifecycle script registered into the agent's *own* settings — `.claude/settings.json`, tagged with
`_airHookId` so AIR knows which entries it owns. Fired on agent events (a tool call, a git push).

On the Pi runtime there is no such settings file to register into, and `air prepare pi` ignores hook
entries outright. `PiAirBridge` writes a generated index that `@tadasant/pi-hooks` reads instead —
see [Pi is the runtime that supplies nothing](/extend/agent-harness/#pi-is-the-runtime-that-supplies-nothing).
The `HOOK.json` below is unchanged either way; what differs is the body's contract, described under
[Writing a body that runs on more than one runtime](#writing-a-body-that-runs-on-more-than-one-runtime).

Zimmer's catalog declares exactly one: `git-push-ci-reminder`. `hooks/hooks.json` registers it, and
`hooks/git-push-ci-reminder/` holds the body:

```
hooks/git-push-ci-reminder/
├── HOOK.json                  # when it fires and what it runs
└── git-push-ci-reminder.mjs   # the script
```

`HOOK.json` is what the Claude adapter reads to write the `.claude/settings.json` entry:

```json
{
  "event": "post_tool_call",
  "matcher": "Bash",
  "command": "node",
  "args": ["./git-push-ci-reminder.mjs"],
  "timeout_seconds": 10
}
```

`event` is an AIR lifecycle name (`session_start`, `pre_tool_call`, `post_tool_call`, `stop`, …) or
the Claude event name directly (`PostToolUse`); an unrecognized one is warned about and skipped.
`matcher` filters by tool name. A `./`-prefixed `command` or arg is rewritten at install time to
`"$CLAUDE_PROJECT_DIR/.claude/hooks/<id>/…"`, so it resolves no matter where the agent has `cd`'d to.

This hook reads the tool-call payload on stdin, and when the shell command that just ran was a
`git push` (a `--dry-run` isn't), returns a reminder to confirm CI before calling the work done.
Everything else is a no-op, and it always exits 0 — a hook must never fail the tool call it observes.

#### Writing a body that runs on more than one runtime

`HOOK.json` is portable. The body it names is not, unless you write it that way — the two runtimes
that execute AIR hooks today disagree about both halves of the contract:

| | stdin payload | how context reaches the model |
| --- | --- | --- |
| Claude Code (`PostToolUse`) | `{tool_name, tool_input, tool_response}` | `hookSpecificOutput.additionalContext` |
| Pi (`@tadasant/pi-hooks`) | `{event, toolName, input, content}` | `{"content": …}`, which **replaces** the tool result |

A body that reads `tool_name` gets `undefined` on Pi and returns early; one that writes
`hookSpecificOutput` has its output ignored. Both are silent — the hook loads, matches, spawns and
exits 0, having done nothing.

`@tadasant/pi-hooks` sets `PI_HOOK=1` on every hook process, which is the signal to answer in its
dialect. `git-push-ci-reminder.mjs` normalizes either payload and renders either response, and it is
worth copying that shape. Note the asymmetry in the right-hand column: Pi's `content` **replaces**
the tool result rather than appending to it, so the Pi branch has to echo the command's own output
back before its own text or the model never sees what the command actually did.

`plugins/ci-workflow/.plugin/plugin.json` bundles this hook alongside `zimmer-run-tests`, and
`ci-workflow` is `default_in_roots: ["agent-orchestrator"]`, so sessions on that root get it
automatically.

:::caution[A missing body is not a dangling reference]
AIR validates references *between* entries, but never checks that a hook's (or skill's) `path`
exists on disk. A registered artifact with no body resolves clean, slips past Zimmer's stderr marker
check, and is silently skipped at `air prepare` with a warning nobody reads. Always create the body.
`HooksConfig`'s test suite asserts every registered hook has a `HOOK.json`, and that any
`./`-prefixed command it names really ships in the directory.
:::

Don't confuse these with [transcript hooks](/extend/transcript-hooks/), which are a Ruby-side
plugin system that runs inside Zimmer when transcript messages arrive. Different thing, same word.

## Adding an artifact

The full procedure lives in `skills/zimmer-change-ai-artifact/SKILL.md`. The short version:

1. Add the body (`skills/<id>/SKILL.md`, `hooks/<id>/HOOK.json`, `references/<file>.md`).
2. Register it in the index (`skills/skills.json`, etc.).
3. Add `default_in_roots: ["<root>"]` to make it default-on for that root.
4. Verify with `air resolve` before pushing. A dangling reference will not fail the resolve — it
   will exit 0, drop your artifact's reference, and then break the test suite.

```bash
# From the repo root
AIR_CONFIG=$PWD/air.json npx @pulsemcp/air-cli@0.13.0 resolve --json --no-scope
```

Watch stderr, not the exit code. Lines containing `references unknown` and `Dropping the
reference` are what Zimmer treats as a hard failure.

## Pointing an instance at your own catalog

The public image ships a small, self-contained catalog (`air.production.json` at the image root,
resolving `./roots.json`, `./mcp.json`, etc.). That is what a stock deployment — and **staging** —
serves. It's deliberately minimal; it is not meant to be *your* catalog.

To run a deployment on your **own** catalog (private agent roots, MCP servers, skills), you deliver a
catalog onto the box and point the app at it with the **`AIR_CONFIG`** env var:

- `config/environments/production.rb` reads `config.air_json_path` from `AIR_CONFIG`, falling back to
  the in-image `air.production.json` when `AIR_CONFIG` is unset **or set to a path that doesn't exist
  yet**. So a not-yet-delivered catalog degrades to the in-image one instead of zero roots; once your
  catalog is on disk and the app restarts, `AIR_CONFIG` wins.
- AIR resolves a catalog's index paths **relative to the `air.json`/`air.production.json` file's own
  directory**. So keep your `air.production.json` and its `artifacts/` (or `roots.json`, `mcp.json`, …)
  siblings in one directory, and point `AIR_CONFIG` at that file.

### How Tadas's production does it (a worked example)

Production's real catalog lives in a private companion repo (`air.json` +
`artifacts/`). It is delivered like this — the same pattern any self-hoster can copy:

1. **Mount two persistent host directories** into both the `web` and `worker` roles
   (`config/deploy.production.yml`), and set `AIR_CONFIG`:
   ```yaml
   volume:
     - /opt/zimmer/catalog:/rails/catalog:ro                 # your air.production.json + artifacts/
     - /opt/zimmer/credentials:/rails/config/credentials:ro  # your production.yml.enc (mcp_secrets)
   env:
     clear:
       AIR_CONFIG: /rails/catalog/air.production.json
   ```
   Bind-mounting host paths (not the container's writable layer) is what makes the catalog **survive a
   Kamal deploy** — a new container re-attaches the same mounts. Mounting on **both** roles is what makes
   agent sessions (which run in the `worker`) see the same catalog and `mcp_secrets` as the web UI.
2. **Deliver the catalog + credentials** to those host paths with a workflow
   (an `artifacts-sync-prod.yml` in that private companion repo): it SSHes to the box and writes
   your `air.json → /opt/zimmer/catalog/air.production.json`, `artifacts/ → /opt/zimmer/catalog/artifacts`,
   and `production.yml.enc → /opt/zimmer/credentials/`, then restarts the app so the catalog cache
   refreshes. Re-run it whenever your catalog changes; it does **not** need to re-run after a normal
   deploy, because the mount persists.

`mcp_secrets` (the `${VAR}` values your `mcp.json` references) come from
`config/credentials/production.yml.enc`, decrypted by `RAILS_MASTER_KEY`. Deliver the `.enc` file the
same way (mounted alongside), and pass `RAILS_MASTER_KEY` as a Kamal secret.

#### Private `github://` catalog sources need `AIR_GITHUB_TOKEN`

If your `air.json` composes catalog content from a **private** `github://` source (via the
`@pulsemcp/air-provider-github` extension), that source is fetched by shelling out to the AIR CLI
during **catalog resolution** (`air resolve` / `air update`), not just at session `air prepare` time.
The provider authenticates to GitHub by reading `AIR_GITHUB_TOKEN` from the resolve process's
environment. Add that PAT (with `repo` read on the private catalog repo) to `mcp_secrets` under the
name `AIR_GITHUB_TOKEN`: Zimmer bridges just that one value from `mcp_secrets` into the `air resolve` /
`air update` subprocess environment so the fetch is authenticated. (Session `air prepare` already had
it — that path merges *all* of `mcp_secrets` into its subprocess env; the gap was specifically the
catalog resolve/update path, which built a minimal `AIR_CONFIG`-only env and merged no secrets.)
Without the token the fetch runs unauthenticated, GitHub returns 401, and AIR silently drops the
private source — leaving only your locally-indexed artifacts and none of the github-composed ones.

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

:::caution[Only Zimmer-specific skills belong in `skills/`]
Generic workflow skills (`pr`, `wait-for-ci`, `code-review`, …) come from the orchestrator's
default skill set, injected separately. Duplicating one in Zimmer's catalog collides on shortname
and AIR hard-fails the entire resolve — which, thanks to the boot-time pre-warm,
[reddens the whole test suite](/air/zimmer-integration/#the-blast-radius-is-the-entire-test-suite).
:::

## References

A markdown document that many skills can share. Broken out from skills deliberately — one reference
(your git workflow, your engineering conventions) shouldn't be copy-pasted into every skill that
needs it.

Zimmer's catalog ships four: `engineering-practices`, `brand`, `brand-voice`, and
`anti-slop-rubric`, mapping to `references/ENGINEERING_PRACTICES.md`, `BRAND.md`,
`BRAND_VOICE.md`, and `ANTI_SLOP_RUBRIC.md`. The `sync-docs` skill declares the last three.

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

Zimmer's catalog declares exactly one: `git-push-ci-reminder`.

:::danger[The one hook that ships has no body]
`hooks/hooks.json` declares:

```json
"git-push-ci-reminder": {
  "title": "Git Push CI Reminder",
  "description": "Reminder to monitor CI status after git push.",
  "path": "git-push-ci-reminder"
}
```

But `hooks/` contains only `hooks.json` — there is no `hooks/git-push-ci-reminder/` directory.

And `plugins/ci-workflow/.plugin/plugin.json` bundles this hook, and `ci-workflow` is
`default_in_roots: ["agent-orchestrator"]`. So every session on the `agent-orchestrator` root
activates a hook whose body doesn't exist.
Tracked in [#65](https://github.com/tadasant/zimmer/issues/65).

This slips past resolve-time validation (a missing *body* is not a dangling *reference*, so it
doesn't trip Zimmer's stderr marker check), and surfaces at `air prepare` when the adapter tries to
copy a directory that isn't there. See [Known limitations](/limitations/#the-only-hook-in-the-catalog-has-no-body).
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

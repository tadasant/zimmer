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

Zimmer's catalog ships exactly one: `engineering-practices` →
`references/ENGINEERING_PRACTICES.md`.

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
activates a hook whose body doesn't exist. Tracked in [#65](https://github.com/tadasant/zimmer/issues/65).

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

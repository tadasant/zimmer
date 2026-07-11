# AGENTS.md — Zimmer

Guidance for humans and coding agents working in this repository. (`CLAUDE.md` is
a symlink to this file.)

## What this is

Zimmer is a Rails 8 app (Ruby 3.4.6) that orchestrates AI coding agents. Key
stack: PostgreSQL, Redis, GoodJob, Hotwire (Turbo + Stimulus), Tailwind.

## Working here

- Always run Rails/bundler commands from the repo root (this is the app root).
- Use a feature branch off the latest `main`; `main` is protected and lands via PR.
- Run **targeted** tests locally; let CI run the full suite:
  `bin/rails test test/models/session_test.rb`
- Lint with `bin/rubocop`, security-scan with `bin/brakeman`.

## Architecture (orientation)

- `app/models/session.rb` — the core Session state machine (AASM):
  waiting → running → needs_input → failed / archived. See
  [docs/SESSION_STATE_MACHINE.md](docs/SESSION_STATE_MACHINE.md).
- `app/jobs/agent_session_job.rb` — spawns and monitors agent processes.
- `app/services/` — service objects (process management, transcript polling,
  runtime registry, config services).
- Pluggable runtimes: [docs/ADDING_AN_AGENT_HARNESS.md](docs/ADDING_AN_AGENT_HARNESS.md).
- Removable extensions: [docs/AO_EXTENSIONS.md](docs/AO_EXTENSIONS.md).
- REST API: [docs/REST_API.md](docs/REST_API.md) — keep it in sync with
  `app/views/api_docs/show.html.erb` when you change endpoints.

## AI artifacts (the AIR catalog)

Zimmer ships a **self-contained** AIR catalog: the top-level artifact indexes are
the catalog, resolved offline by the `@pulsemcp/air` CLI. `air.json` (dev/test)
and `air.production.json` (in-image) wire six types:

| Type | Index | Bodies |
| --- | --- | --- |
| Skills | `skills/skills.json` | `skills/<id>/SKILL.md` |
| Agent roots | `roots.json` | — |
| MCP servers | `mcp.json` | — |
| Plugins | `plugins/plugins.json` | `plugins/<id>/.plugin/plugin.json` |
| Hooks | `hooks/hooks.json` | `hooks/<id>/` |
| References | `references/references.json` | `references/<file>.md` |

The app reads all six through `AirCatalogService` (which shells out to
`air resolve`); `SkillsConfig` / `AgentRootsConfig` / `PluginsConfig` /
`ReferencesConfig` are thin readers over it. Never parse the indexes directly.

Two rules worth internalizing before you touch them:

- **Only Zimmer-specific skills belong in `skills/`.** Generic workflow skills
  (`pr`, `wait-for-ci`, …) come from the orchestrator's default skill set;
  duplicating one here collides on shortname and AIR hard-fails the whole resolve.
- **No dangling references.** A skill/MCP/hook/plugin/root reference to something
  that does not exist makes AIR drop it, which `AirCatalogService` treats as a
  failed resolve — degrading the app to a stale snapshot and failing the test
  suite globally (`test/test_helper.rb` pre-warms the catalog at boot).

`skills/zimmer-change-ai-artifact/SKILL.md` is the full guide, including how
`default_in_roots` makes an artifact default-on and how to verify with
`air resolve` before pushing.

## Conventions

- Keep controllers thin; put logic in models/services.
- No temporal comments ("now", "used to be") — write code as the canonical state.
- Don't add backwards-compat shims during refactors; update all call sites.
- Never commit secrets. Secrets flow through environment variables / GitHub
  Actions secrets / Terraform variables, never files in git.

## Known coupling

Session creation validates `agent_root` against an artifact **catalog**. Standalone
that catalog is not yet wired, so session-creating tests currently fail — see
[CONTRIBUTING.md](CONTRIBUTING.md#known-coupling-the-agent-artifact-catalog).

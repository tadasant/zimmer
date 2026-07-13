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

## Documentation lives in `docs/` — update it in the same PR

`docs/` is the Zimmer documentation site (Astro Starlight, deployed to Cloudflare
Pages). It is the canonical prose for how Zimmer works, and the premise is that it
stays true commit-by-commit.

**If your PR changes behavior, update the page that describes that behavior in the
same PR.** If it introduces a limitation, a hack, or a known-broken edge, add it to
`docs/src/content/docs/limitations.md` — that page is a feature, not a confession.

| You changed… | Update… |
| --- | --- |
| `app/models/concerns/session_state_machine.rb` | `sessions/lifecycle.md` |
| `app/jobs/agent_session_job.rb`, the CLI adapters | `sessions/spawning.md` |
| `config/routes.rb`, `app/controllers/api/**` | `extend/rest-api.md` **and** `app/views/api_docs/show.html.erb` |
| `air.json`, `roots.json`, `mcp.json`, `skills/`, `plugins/`, `hooks/` | `air/*.md` |
| `RuntimeRegistry`, a new runtime | `extend/agent-harness.md` |
| `app/extensions/**` | `extend/extensions.md` |
| OAuth, `ClaudeAccount`, `McpOauthCredential` | `auth/*.md` |
| `infra/`, `.github/workflows/**`, `Dockerfile*` | `operate/deploying.md`, `operate/provisioning.md` |
| `config/goals.json` | `sessions/goals.md` |
| any cron job | `operate/background-jobs.md` |
| `config/initializers/otel_logs_exporter.rb`, `config/initializers/sentry.rb`, `lib/tasks/obs.rake` | `operate/observability.md` |

Pages are `docs/src/content/docs/**`. A new page must also be added to the `sidebar`
array in `docs/astro.config.mjs` — Starlight does not auto-discover it. `cd docs &&
npm run build` is what CI runs; the `docs_site` job fails the PR if it breaks.

Diagrams are Mermaid fenced code blocks, rendered client-side. Keep them accurate to
the code rather than illustrative.

**Brand and voice.** All user-facing prose (docs, README, UI copy) follows
`references/BRAND.md` (what Zimmer is and who it's for — a single circle of trust,
not teams or enterprise) and `references/BRAND_VOICE.md` (plain, direct, honest, no
AI slop). Both travel with the `sync-docs` skill. Write new prose in that voice;
don't leave slop behind when you fix a stale fact.

## Architecture (orientation)

- `app/models/session.rb` + `app/models/concerns/session_state_machine.rb` — the core
  Session state machine (AASM): waiting → running → needs_input → failed / archived.
- `app/jobs/agent_session_job.rb` — spawns and monitors agent processes.
- `app/services/` — service objects (process management, transcript polling,
  runtime registry, config services).
- `app/services/runtime_registry.rb` — the pluggable-runtime seam (`claude_code`, `codex`).
- `app/services/zimmer/` — the removable-extension seam.

The prose for all of the above is in `docs/`.

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

Session creation validates `agent_root` — and `catalog_skills` — against the
artifact catalog above. The catalog is wired and self-contained, so this resolves
offline and the suite is green. But the coupling is real and global: a catalog
that fails to resolve does not fail one test, it fails **all** session-creating
tests at once (`test/test_helper.rb` pre-warms the catalog at boot, before
`parallelize` forks its workers). A sudden wave of `ActiveRecord::RecordInvalid`
across unrelated session tests almost always means a broken catalog, not a broken
model — see [CONTRIBUTING.md](CONTRIBUTING.md#known-coupling-the-agent-artifact-catalog).

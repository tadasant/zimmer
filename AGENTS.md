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

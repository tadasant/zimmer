# Zimmer

Zimmer is a self-hostable orchestrator for AI coding agents. It gives you a web
UI and background workers to spawn, monitor, and manage long-running coding-agent
sessions (starting with Claude Code and Codex), stream their transcripts in real
time, and drive them through a REST API.

Zimmer is a standalone open-source extraction of an internally-developed agent
orchestrator. It is a Rails 8 application (Ruby 3.4, PostgreSQL, Redis, GoodJob,
Hotwire, Tailwind).

> **Status:** early. See [Known limitations](#known-limitations) before relying on it.

## Features

- Create and manage agent **sessions** with a state machine (waiting → running →
  needs_input → failed / archived).
- Real-time **transcript streaming** over Hotwire/Turbo.
- **REST API** (`/api/v1`) for programmatic session control — see [docs/REST_API.md](docs/REST_API.md).
- Pluggable **agent runtimes** (Claude Code, Codex) — see
  [docs/ADDING_AN_AGENT_HARNESS.md](docs/ADDING_AN_AGENT_HARNESS.md).
- Removable **AO Extensions** for optional behavior that isn't part of core —
  see [docs/AO_EXTENSIONS.md](docs/AO_EXTENSIONS.md).

## Quick start (development)

Prerequisites: Ruby 3.4.6, PostgreSQL 14+, Redis, Node.js.

```bash
bundle install
cp .env.example .env          # then set ANTHROPIC_API_KEY
bin/rails db:setup
bin/dev                        # starts Rails + Tailwind watcher + GoodJob (async)
# app on http://localhost:3000
```

Run the app on a random free port with `PORT=0 bin/dev`.

## Running with Docker

The production image is published to `ghcr.io/tadasant/zimmer`. It builds `FROM`
a base image (`ghcr.io/tadasant/zimmer-base`) that carries the heavy
dependencies (Node, Playwright, gh CLI). Build the base once via the **Build base
image** workflow, then every push to `main` publishes a versioned app image (see
[Image versioning](#image-versioning)).

```bash
docker run -d -p 80:80 \
  -e SECRET_KEY_BASE=$(openssl rand -hex 64) \
  -e DATABASE_URL=postgres://... \
  -e REDIS_URL=redis://... \
  ghcr.io/tadasant/zimmer:latest
```

## Deploying

Zimmer is designed to run on a single DigitalOcean droplet on a Tailscale VPN, so
the UI is reachable only by you and your CI. The infrastructure is fully defined
in Terraform under [`infra/terraform`](infra/terraform), and the deploy is a
manually-triggered GitHub Actions workflow. See
[docs/DEPLOYING_ON_DIGITALOCEAN.md](docs/DEPLOYING_ON_DIGITALOCEAN.md) — including
how to do it with a coding agent.

## Image versioning

`VERSION` holds a floor semver (e.g. `0.1.0`). On every push to `main` the
**Release image** workflow publishes `ghcr.io/tadasant/zimmer:MAJOR.MINOR.PATCH`
where the patch auto-increments with each commit. To cut a minor/major bump, edit
`VERSION` in a PR. Old versions are pruned to ≤50 by a scheduled retention
workflow whose selection logic is unit-tested in
[`scripts/ghcr_retention.rb`](scripts/ghcr_retention.rb).

## Extensions

Extensions live in `app/extensions/<id>/` but are **not** baked into the core
image. The registry auto-skips a missing extension directory and falls back to
native behavior, so operators opt in per extension:

```bash
scripts/install-extension.sh mcp_tool_search --container zimmer
```

See [docs/EXTENSIONS_INSTALL.md](docs/EXTENSIONS_INSTALL.md).

## Known limitations

- The full test suite currently depends on an external agent-artifact **catalog**
  (agent roots / skills / plugins / references). Wiring a public catalog for
  standalone use is in progress; see [CONTRIBUTING.md](CONTRIBUTING.md) and the
  open issues.

## License

MIT — see [LICENSE](LICENSE).

# Contributing to Zimmer

Thanks for your interest in Zimmer! This is an early-stage project extracted from
an internal orchestrator, so expect some rough edges.

## Development setup

See the [README](README.md#quick-start-development). In short: Ruby 3.4.6,
PostgreSQL, Redis, then `bundle install && bin/rails db:setup && bin/dev`.

## Branch & PR workflow

- Work on a feature branch off the latest `main`.
- `main` is protected: changes land via pull request with green CI.
- Keep PRs scoped; write a clear description of what changed and why.

## Tests, lint, and security

CI runs on GitHub-hosted runners (`.github/workflows/ci.yml`):

- **Lint:** `bin/rubocop`
- **Security:** `bin/brakeman`
- **Lockfile:** `bundle lock` must leave `Gemfile.lock` unchanged
- **Tests:** `bin/rails test` (Postgres + Redis service containers)
- **Retention logic:** `ruby scripts/ghcr_retention_test.rb`

Run targeted tests locally rather than the whole suite:

```bash
bin/rails test test/models/session_test.rb
```

## Known coupling: the agent-artifact catalog

Zimmer's session model validates a session's `agent_root` (and `catalog_skills`)
against a **catalog** of agent roots / skills / plugins / hooks / references. In
the upstream project that catalog is resolved at runtime from external
repositories via the "AIR" CLI. Zimmer instead ships its **own self-contained
catalog** in this repo — `air.json` plus the top-level artifact indexes
(`skills/`, `roots.json`, `mcp.json`, `plugins/`, `hooks/`, `references/`) — so it
resolves fully offline, with no network and no private GitHub catalogs.
`test/test_helper.rb` pre-warms it for the suite.

The coupling that remains is worth knowing about, because it fails **globally**
rather than locally. The pre-warm happens at boot, before `parallelize` forks its
workers, so a catalog that does not resolve takes down every test that creates a
session (anything through `Session.create_from_agent_root!`) with
`ActiveRecord::RecordInvalid` — not just the test you were editing.

`AirCatalogService` is strict on purpose here: AIR drops an unresolvable reference
and still exits 0, so the service treats any dropped reference as a **failed
resolve** rather than persisting a structurally-incomplete catalog. That means a
single dangling reference — a plugin bundling a skill that no longer exists, a
`default_in_roots` naming an unknown root — reddens the whole suite.

So if you see a broad wave of `ActiveRecord::RecordInvalid` in session tests,
suspect the catalog before your change. Verify it resolves cleanly:

```bash
AIR_CONFIG=$PWD/air.json <air-cli>/air resolve --json --no-scope --git-protocol https \
  >/tmp/resolve.json 2>/tmp/resolve.err
cat /tmp/resolve.err   # MUST be empty — any "Dropping the reference" is a failure
```

Entry points: `AirCatalogService`, `AgentRootsConfig`, `SkillsConfig`,
`PluginsConfig`, `ReferencesConfig`, and the pre-warm block in
`test/test_helper.rb`. To add or change an artifact, follow
`skills/zimmer-change-ai-artifact/SKILL.md`.

## Extensions

Optional behavior lives in `app/extensions/<id>/` and must be fully removable —
deleting the directory leaves a working app. See
[docs/AO_EXTENSIONS.md](docs/AO_EXTENSIONS.md) and
[docs/AUTHORING_AN_AO_EXTENSION.md](docs/AUTHORING_AN_AO_EXTENSION.md).

## License

By contributing you agree that your contributions are licensed under the MIT
License (see [LICENSE](LICENSE)).

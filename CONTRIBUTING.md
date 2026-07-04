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

Zimmer's session model validates a session's `agent_root` against a **catalog**
of agent roots / skills / plugins / references. In the upstream project this
catalog is resolved at runtime from external repositories via an "AIR" CLI, and
`test/test_helper.rb` pre-warms that catalog for the suite.

Standalone, there is no catalog wired yet, so tests that create sessions
(anything going through `Session.create_from_agent_root!`) currently fail with
`ActiveRecord::RecordInvalid` because the resolved catalog is empty. **Decoupling
Zimmer from the private catalog — by shipping a small public default catalog and
seeding it in `test_helper` — is the top priority to get the full suite green.**
If you pick this up, the entry points are `AirCatalogService`, `AgentRootsConfig`,
`SkillsConfig`, `PluginsConfig`, `ReferencesConfig`, and the pre-warm block in
`test/test_helper.rb`.

## Extensions

Optional behavior lives in `app/extensions/<id>/` and must be fully removable —
deleting the directory leaves a working app. See
[docs/AO_EXTENSIONS.md](docs/AO_EXTENSIONS.md) and
[docs/AUTHORING_AN_AO_EXTENSION.md](docs/AUTHORING_AN_AO_EXTENSION.md).

## License

By contributing you agree that your contributions are licensed under the MIT
License (see [LICENSE](LICENSE)).

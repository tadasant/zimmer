# Contributing to Zimmer

Thanks for your interest in Zimmer! This is an early-stage project extracted from
an internal orchestrator, so expect some rough edges.

## How to contribute: issues, not pull requests

Zimmer is maintained as a single circle of trust, so **it does not accept pull
requests** — every change lands through the maintainer, and PRs opened against this
repo are closed unmerged with a friendly pointer back to this policy. It's not
personal; it keeps the project coherent.

The most useful thing you can send is a **detailed issue**, and those are triaged
quickly:

- 🐞 **[Report a bug](https://github.com/tadasant/zimmer/issues/new?template=bug_report.yml)** — exact reproduction steps, real output, impact, and version.
- 💡 **[Request a feature](https://github.com/tadasant/zimmer/issues/new?template=feature_request.yml)** — the problem, a concrete proposal, and any precedent in the repo.
- 💬 **[Ask a question](https://github.com/tadasant/zimmer/discussions)** in Discussions.

**Forking is welcome** — it's MIT-licensed, so fork it, run it, and build on it. The
rest of this guide helps you get it running and find your way around the code.

## Development setup

See the [README](README.md#try-it-locally). In short: Ruby 3.4.6,
PostgreSQL, Redis, then `bundle install && bin/rails db:setup && bin/dev`.

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
[Extensions](https://docs.zimmer.tadasant.com/extend/extensions/).

## Documentation

The docs site lives in [`docs/`](docs) (Astro Starlight → Cloudflare Pages) and is
published at [docs.zimmer.tadasant.com](https://docs.zimmer.tadasant.com/). The maintainer's
rule is to **update the relevant page in the same change as the behavior it describes** — the
mapping from code area to page is in
[AGENTS.md](AGENTS.md#documentation-lives-in-docs--update-it-in-the-same-pr). New
limitations, hacks, and known-broken edges belong on the
[Known limitations](https://docs.zimmer.tadasant.com/limitations/) page; it is a feature, not a confession.
If you spot a doc that's drifted from the code, that's a great thing to open an issue about.

`cd docs && npm run build` is what the `docs_site` CI job runs.

## License

By contributing you agree that your contributions are licensed under the MIT
License (see [LICENSE](LICENSE)).

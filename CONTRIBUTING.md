# Contributing to Zimmer

Thanks for your interest in Zimmer! This is an early-stage project extracted from
an internal orchestrator, so expect some rough edges.

## How to contribute: issues, not pull requests

Zimmer *is* a software factory — a system for shipping reviewed, CI-green code by
running agent sessions against a repo. Feature work on Zimmer is done through that
factory, so **it doesn't accept pull requests**: a patch that arrives out of band
hasn't been through the pipeline that makes changes here trustworthy, and merging it
would mean redoing that work by hand. PRs opened against this repo are closed unmerged
with a friendly pointer back to this policy. It's not personal — it's just easier and
safer to feed the factory than to bypass it.

The most useful thing you can send is a **detailed issue** — the work order the factory
runs from. Those are triaged quickly:

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

A targeted run loads only the files you name, so a test file must require the bundled gems it uses
instead of inheriting them from whatever the full suite loaded first. `ostruct` is the one that bites:
it is not required for you, and a file naming `OpenStruct` without `require "ostruct"` passes in CI and
raises `NameError` on its own. `test/contracts/ostruct_require_contract_test.rb` enforces the require.

### Capturing log output in a test

Use `capture_log_entries` (`test/support/log_capture_helpers.rb`), which attaches a
sink with `Rails.logger.broadcast_to`. Do not assign `Rails.logger`. Assignment is
invisible to anything holding a reference to the original logger, and Rails hands out
several: most importantly `Rails.application.env_config["action_dispatch.logger"]`,
which is memoized once per process and merged over every request env, and is what
`ActionDispatch::DebugExceptions` writes an unhandled exception to. A test that assigns
`Rails.logger` therefore *misses* exactly the ERROR records a logging test usually
exists to assert on. `test_helper.rb` resolves `env_config` before the parallel workers
fork so that entry is always the real boot logger; see issue #337 for the flake that
taught us this.

`test/contracts/log_capture_contract_test.rb` enforces the rule for tests that can
issue a request (`test/integration`, `test/controllers`, `test/system`, `test/e2e`).
Unit tests elsewhere still use the older assign-and-restore idiom; it is inert there
because they never build a request env, but new code should not add more of it.

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

---
title: Testing philosophy
description: What CI runs, what it doesn't, the contract tests that keep runtimes honest, and the catalog coupling that can redden the whole suite at once.
sidebar:
  order: 5
---

## What CI runs

`.github/workflows/ci.yml`, on every PR and every push to `main`:

| Job | What |
| --- | --- |
| `lint` | `bin/rubocop -f github --parallel`, then the migration drop/rename guard (pure Ruby, no Rails boot — see [Deploying](/operate/deploying/#the-guard)) |
| `security` | `bin/brakeman --no-pager -q` |
| `verify_lockfile` | `bundle lock` then `git diff --exit-code Gemfile.lock` |
| `test-unit` | `bin/rails test` — unit + integration; Postgres 16 + Redis 7 service containers |
| `test-system` | `bin/rails test:system` — the Chrome-driven browser suite; `PARALLEL_WORKERS=1` |
| `schema_verify` | `bin/rails db:schema:verify` — round-trips `db/schema.rb` against `db/migrate/`, the dump and a catalog of what the dump cannot describe, on a scratch Postgres 16 container |
| `retention_logic` | `ruby scripts/ghcr_retention_test.rb` (pure Ruby, no Rails boot) |
| `docs_site` | Builds this documentation site |
| `image_excludes_docs` | Asserts `docs/` is absent from the image build context — see [Deploying](/operate/deploying/#the-docs-never-ship-in-the-image) |
| `shellcheck` | ShellCheck at `--severity=info` over every tracked `*.sh` file |
| `all-checks-pass` | Aggregate gate — `needs:` every job above and fails if any failed or was cancelled |

## The single branch-protection gate

`all-checks-pass` is the one status check to require under **Settings → Branches → main**, instead
of enumerating every job. It runs with `if: ${{ !cancelled() }}`, fails if any dependency reported
`failure` or `cancelled`, and treats a `skipped` dependency — the fork-guarded jobs skip on fork
PRs — as neither a pass nor a failure.

`!cancelled()` rather than `always()`, and rather than a bare `needs:`. A bare `needs:` job is
skipped when any dependency fails, which would leave the required check perpetually "skipped" and
block the branch. `always()` overshoots the other way: this workflow sets `cancel-in-progress:
true`, so every superseded run would reach the gate, see `cancelled` in `needs.*.result`, and exit
1 — turning a cancelled run into a failed one and tripping the CI-failure alert, which deliberately
stays quiet on `cancelled`.

## The browser suite runs

`test-system` runs `test/system/*.rb` through Capybara + Selenium against headless Chromium. It is a
separate job from `test-unit` because `bin/rails test` does not descend into `test/system`, because
the shared runner has a companion system-test semaphore keyed on the `test-system` job name, and
because it pins `PARALLEL_WORKERS=1` — the persistent per-worker `--user-data-dir` in
`test/application_system_test_case.rb` does not tolerate concurrent Chrome instances. Chrome is
assumed pre-provisioned on the runner; the CI branch of that file points Selenium at
`/usr/bin/chromium-browser` with `--no-sandbox`. This closes
[#87](https://github.com/tadasant/zimmer/issues/87).

## Shell scripts are linted, not just parsed

`shellcheck` runs over every `*.sh` file `git ls-files` reports — `scripts/`, `.github/scripts/`
and `.agent-containers/`. The scripts in the first two are not conveniences: they run as root on
the droplets, over SSH, out of the deploy path. `clear-root-password-expiry.sh` rewrites root's
password ageing, `tailnet-reap-node.sh` removes tailnet nodes, `worker-watchdog.sh` sends `kill
-9` to container shims and `rm -rf`s containerd task directories, `install-worker-watchdog.sh`
writes systemd units, and `install-needrestart-sysbox-dropin.sh` writes into
`/etc/needrestart/conf.d`. `bash -n` proves those parse and nothing more.

**The floor is `--severity=info`, and that is the load-bearing part.** SC2086 — an unquoted
expansion, so `rm -rf $dir/foo` becomes `rm -rf /foo` when `$dir` is empty — is an *info*-level
check, not a warning. A script whose whole body is `d=$1; rm -rf $d/foo` draws zero findings at
`--severity=warning` and one at `--severity=info`. A `warning` floor would have been a green job
that ignored the defect class it was added for. The tree is clean at `--severity=style` too, so
tightening further is a one-word change.

The job downloads a pinned, checksummed shellcheck release into `$RUNNER_TEMP`. The shared
self-hosted runner has no shellcheck on it and CI jobs there do not run as root, so `apt-get
install` is not an option; putting it in the runner image would mean a different repository.

Three guards keep the job from passing while checking nothing. It fails on an empty file list; it
fails if any of the four root-privileged scripts above has dropped out of the set, which is the
failure mode a glob invites; and it fails on a repo-root `.shellcheckrc` or a file-level `#
shellcheck disable=` above a script's first command, either of which switches checks off wholesale
while the job stays green. Per-site directives are fine and are what the scripts use — they sit
against one statement and carry their reason.

The extensionless bash under `bin/` (`bin/dev`, `bin/docker-entrypoint`, `bin/agent-dev`,
`bin/ensure-playwright-browsers`, `bin/preinstall-mcp-packages`) is **not** covered. Those draw 12
findings between them, all benign on inspection, but clearing them means editing the production
container entrypoint — not something to do inside a CI change.

## What CI does not run

The Playwright scripts under `test/e2e/*.js` (`account_rotation`, `browser_extension`,
`chat_bubble`, `joystick_menu`, `skills_catalog`) are **not** run in CI — the AO parent never ran
them either. They are standalone runners that need a Playwright browser the runner is not
provisioned for, and `account_rotation_test.js` drives the real Claude Code binary against a mock
Anthropic server. The `test-system` job covers the overlapping UI through the Ruby browser suite.
Tracked in [#162](https://github.com/tadasant/zimmer/issues/162).

`browser_extension_test.js` is the one proof of the
[browser extension](/extend/browser-extension/) as a whole: it loads the real unpacked extension
into a full Chromium (`channel: 'chromium'` — the headless shell cannot load extensions), arms it
on a real page, drops a pin, sends, and reads the session back. It needs a running server and a
Quick Router key: `BASE_URL=http://localhost:3000 QUICK_ROUTER_KEY=zmr_… node test/e2e/browser_extension_test.js`.

## The migrations are replayed, in their own job

`test-unit` and `test-system` build the database with `bin/rails db:test:prepare`, which *loads*
`db/schema.rb` and never runs a migration. On its own that leaves a `schema.rb` disagreeing with
`db/migrate/` green all the way to whoever next migrates an empty database. The `schema_verify` job
is what closes that:

```bash
RAILS_ENV=test bin/rails db:schema:verify
```

It migrates a scratch database from zero and dumps it, loads the committed schema into another and
dumps that, then diffs — printing the unified diff of whichever file disagrees, because a CI log is
the only place most readers will ever see the failure. It drops and recreates databases several
times, which is why it gets its own Postgres service container instead of a step inside `test-unit`,
and why it refuses to run outside `RAILS_ENV=test`. The same command is what you run locally.

Comparing two dumps only sees what the dumper writes down, and Rails' Ruby dumper writes down
tables, indexes, constraints, enums and extensions. So each pass also reads a **catalog** straight
from Postgres: functions, aggregates, triggers, event triggers, views, materialized views, rules,
row-level security and its policies, custom types, standalone sequences, exclusion constraints, and
how each table is stored (partitioning, inheritance, `UNLOGGED`, storage parameters). The job fails
if the two catalogs differ, and prints the difference.
Without that, a migration could install something with `execute` that existed in production and
silently did not exist in CI or test ([#780](https://github.com/tadasant/zimmer/issues/780)).

The job deliberately does **not** set `CI=true`, unlike the two test jobs. That variable's only
effect in the test environment is to turn on eager loading, and eager-loading the app while
migrating from zero means model code meeting a half-built schema.

`test/migrations/schema_dump_test.rb` still covers the cheap half inside `test-unit`, where it
answers in milliseconds: the dumps are in the running Active Record version's format, and
`schema.rb` is at the newest migration on disk.

**The check found real drift both times it has been run end to end.** The first, in
[#182](https://github.com/tadasant/zimmer/issues/182): `db/migrate/` was not replayable from zero
because `20260613193000_add_session_maintenance_indexes` built a partial index on
`sessions.transcript`, a column no migration created —
`20260613192900_add_missing_session_columns_for_migration_replay` fixed that. The second, when the
job was wired in ([#318](https://github.com/tadasant/zimmer/issues/318)): `logs.session_id` was a
`bigint` in `20251112023554_create_logs` and an `integer` in every database that exists. See
[Known limitations](/limitations/#logssession_id-is-an-integer-referencing-a-bigint-primary-key).

The task takes some care to see any of this at all: `db:migrate` against a database with no
`schema_migrations` table does **not** run the migrations — it loads `db/schema.rb` and stamps every
version as applied. So the from-zero pass moves the schema files out of the way first. Without that,
both passes just re-dump the committed schema and the check reports OK for any drift.

Its replay half is scoped to databases that actually have migrations, which today means the primary
one. solid_cable's `cable` database is installed by loading `db/cable_schema.rb` — the gem ships
that file and no migration, and the `migrations_paths` its config names (`db/cable_migrate`) is not
a directory in this repo — so a from-zero migrate dumps it empty by design. It is still covered by
the load-and-dump half, which is the only comparison that means anything for a schema-only database.

### Functions and triggers are dumped; other DDL is refused

`db/schema.rb` carries functions and triggers.
`config/initializers/schema_dump_functions_and_triggers.rb` appends each one to the end of the dump
as an `execute` block holding the SQL Postgres reports for it (`pg_get_functiondef`,
`pg_get_triggerdef`). A migration can install one with `execute`, re-dump, and every database built
from the dump has it. `gate_decisions_append_only` is the one in use: it refuses the `UPDATE` and
`DELETE` statements on `gate_decisions` that skip `GateDecision`'s callbacks.

Anything else in the catalog is not dumped, so `schema_verify` fails the PR that adds one: a view, a
rule, a policy, a domain. Build it from something the dump carries, or extend the initializer to
dump that kind too, and let the check tell you whether a schema load reproduces it.

The alternative is `config.active_record.schema_format = :sql`, which dumps `db/structure.sql` with
`pg_dump` and carries everything. Zimmer does not use it. `pg_dump` would be needed everywhere a
migration is written, and the agent worker image, where most migrations here are written, has no
Postgres binaries. `pg_dump` also refuses to dump a server newer than itself, so every machine that
runs `db:migrate` would need a matching version. The extra dump code needs only a database
connection.

## Tests that skip themselves

Several tests `skip` when a credential or file is absent — which in CI means they never run at all:

| Test | Skips when |
| --- | --- |
| `preregistered_oauth_config_test.rb:189` | "OAuth credentials not available (CI environment)" |
| `secrets_loader_test.rb:158` | "Credentials key not available (CI environment)" |
| `sessions_test.rb` "changing agent root updates MCP server selection…" | Needs **two** agent roots with `default_mcp_servers`. Only `playwright-custom` declares `default_in_roots` (→ `zimmer`), so exactly one root qualifies and the test always skips — the root→MCP-defaults switch has no system coverage. |

The catalog-pinning tests used to be the worst case on this list — eight tests across four files,
which left the whole feature with zero CI coverage — plus
`references_config_test.rb`'s file-existence test, which skipped on a path bug rather than a missing
fixture. All nine now run ([#69](https://github.com/tadasant/zimmer/issues/69)).

The lesson is worth keeping. The eight skipped for want of a `github://` catalog Zimmer
deliberately does not run, but a *configuration* is what the code reads, not the environment: a
synthetic air.json in a tmpdir, a stub on `pinnable_catalogs`, and a local `git init` standing in
for the provider cache cover the whole path offline, with no network and no token. And two of the
eight had rotted while dormant — one built its cache clone under the wrong owner directory, another
expected a list the implementation dedupes — which is exactly what an unrun test does.

## Tests that would never run — and the one that looked like it

A test method that is not public is a test method Minitest never runs.
`Minitest::Runnable.runnable_methods` collects `public_instance_methods` only, so a test defined
while its class body's default visibility is private is dropped silently: no failure, no skip, no
line in the run count. That is worse than a red test, because the suite stays green.

Three definition styles sit under a class-level `private`, and they do not behave the same way:

```ruby
private

def test_thing; end               # private -> dormant
define_method(:test_thing) { }    # private -> dormant
test "thing" do ... end           # public  -> runs
```

The third one runs because `ActiveSupport::Testing::Declarative#test` calls `define_method` from
inside a method body. Default visibility is a property of the class-body frame; a call out to a
helper does not carry it, so the method lands public no matter what precedes the `test` block.
`define_method` written *literally* in the class body is a different story — that one is in the
frame, and it goes private.

This distinction is why [#350](https://github.com/tadasant/zimmer/issues/350) — "143 tests never
run", counting `test` blocks below a class-level `private` in nine files — was a false alarm. All
143 were running. A suite-wide sweep found **zero** private or protected `test_*` methods across 398
test classes and 7,920 collected test methods.

`test/contracts/dormant_test_contract_test.rb` is what keeps that true. It works both ends:

- **Runtime** — walks `Minitest::Runnable.runnables` and fails if any loaded test class has a
  private or protected `test_*` method. This is ground truth: it asks the loaded classes what
  Minitest would collect. Its blind spots are what the process did not load — `bin/rails test` never
  descends into `test/system` — and methods a test class picks up from an included module, which
  `private_instance_methods(false)` does not report.
- **Static** — parses every `.rb` under `test/` with Prism, tracks each class or module body's
  default visibility, and fails on a `def test_...`, a `private def test_...`, a `private :test_...`,
  or a literal `define_method(:test_...)` left non-public. It follows a `private` through `if`,
  `case`, `begin`/`rescue`, `send(:private)`, `module_function`, and `included do ... end`. It covers
  the system suite and `test/support` shared modules, neither of which the runtime half can see from
  the `test-unit` job.

The static half only flags inside a body that could contribute a Minitest test — a class named
`*Test`, a class descending from a `*Test`/`*TestCase`, or any module. A plain helper class is
exempt, because `test_`-prefixed is a legitimate method name outside a test case:
`FakeParameterStore#test_iam_permissions` fakes the GCP `testIamPermissions` endpoint and is
correctly private. `class << self` is skipped for the same reason in reverse — those are singleton
methods, and Minitest collects instance methods.

The file also carries a `VisibilityProbe` that defines all three styles under a `private` and
asserts which ones `runnable_methods` returns, so the claim above is pinned to real Ruby semantics
rather than to a comment. It is the one file excluded from the on-disk scan, for the obvious reason.

## Flaky tests and the root causes behind them

A run of CI flakes ([#2](https://github.com/tadasant/zimmer/issues/2),
[#3](https://github.com/tadasant/zimmer/issues/3), [#5](https://github.com/tadasant/zimmer/issues/5),
[#10](https://github.com/tadasant/zimmer/issues/10), [#114](https://github.com/tadasant/zimmer/issues/114),
[#138](https://github.com/tadasant/zimmer/issues/138),
[#148](https://github.com/tadasant/zimmer/issues/148)) turned out to be almost the same bug wearing
different hats: **a global stub, mock, or expectation on a process-wide singleton, in a parallel suite
with live background threads.** The suite runs `parallelize(workers: N)` with the default `:processes`,
so there is no cross-*test* bleed — but each worker process still runs GoodJob schedulers, the OTel log
exporter, and the catalog refresher on their own threads. When a test replaces `File.read`, `Dir.glob`,
or `Rails.logger.warn` process-wide, one of those threads can hit the replacement with an argument shape
the stub never anticipated, and the test fails on something it never called.

The fixes all pull the seam in rather than patching the global:

- **`ClaudeModelConfigurationAudit`** takes an injectable `reader:` (defaulting to `File`); the
  unreadable-settings test passes a small double instead of stubbing `File.file?`/`File.read` for the
  whole process.
- **`SessionsControllerTest#refresh_all`** writes real transcript files to the path the controller
  computes, so there are no `Dir`/`File` mocks to race.
- **`TriggerTest`** captures log output through a swapped-in `StringIO` logger and asserts a substring,
  which is indifferent to a concurrent `BroadcastService` circuit-breaker warn — where a strict
  `expects(:warn)` rejected it as an unexpected invocation.
- **`CleanupOrphanedSessionsJobTest`** scopes its no-enqueue assertion to the session under test rather
  than to a job class the cleanup sweep may legitimately enqueue for other orphans.
- **The whole constant graph is eager-loaded** in `test/test_helper.rb` (`Rails.application.eager_load!`)
  before `parallelize` forks, so no worker thread can race a lazy Zeitwerk autoload. This replaced a
  brittle per-constant "resolve gate" that force-loaded `GoodJob::Job` and `TranscriptFileLocator` one
  hand-added line at a time; leaving *any* leaf constant lazy meant an unlucky `--seed` could poison a
  worker if a killed background thread consumed its one-shot autoload. Eager-loading up front leaves no
  pending autoload for any constant, so new leaves never need a new line.

The rule that prevents the next one: **do not stub, mock, or set expectations on a shared global
(`File`, `Dir`, `Kernel`, `Rails.logger`) in this suite.** Inject a seam, point at a real temp file, or
capture output — anything scoped to the object and lifetime under test.

### The host is not a fixture: a test must not see the machine's processes

The rule above has a sharper edge than flakiness. `HealthMonitorService#cleanup_orphaned_processes`
defines an orphan as *a live `claude` process this uid owns whose pid no `running` or `waiting` session
in the database records*, and it terminates every one it finds. Run from a test, the database half of
that is the test database, whose fixtures record no real pid — so every live agent process on the
machine is an orphan. On the production droplet, where agent sessions run their own targeted tests
beside a fleet of live agents, `bin/rails test test/controllers/health_controller_test.rb` killed the
session running it, three times over ([#1095](https://github.com/tadasant/zimmer/issues/1095)). CI
never noticed because a CI container has no other agent to kill.

The seam is `HostProcessDiscovery`, the one object that runs the `pgrep`. `HealthMonitorService` takes
one as `process_discovery:`, and when none is given it builds whichever `config.x.host_process_discovery`
names: the real scanner everywhere but `config/environments/test.rb`, which sets `:none` and gets
`HostProcessDiscovery::None`, which sees nothing. That covers every caller that constructs the service
the way production does — the two controllers, the `action_health` and `get_system_health` MCP tools,
`SystemHealthMonitorJob` — including tests that have not been written yet. It also means an unstubbed
`process_health` in a test reports zero active processes, which the section already reports as "not
observable from here" whenever a session records an agent process it cannot probe, rather than as
"none exist".

The setting is one line in one file, and anything other than exactly `:none` builds the real scanner,
so `test/test_helper.rb` checks it once in the parent process, before `parallelize` forks: a service
built without an explicit discovery must come back with `HostProcessDiscovery::None`, or the suite
aborts before any test body runs. Two per-case tripwires sit behind that: `HealthControllerTest` posts
to the action with `HostProcessDiscovery.expects(:new).never` and
`ProcessTerminationService.any_instance.expects(:terminate).never`, which fail on the constructor
before anything is signalled, and `HealthMonitorServiceTest` asserts the same service is blind here
and that `cleanup_orphaned_processes` reaches no termination even when every pid it could see would
count as an orphan. A test *of* the scanner constructs a `HostProcessDiscovery` and stubs its own
`pgrep_output` — the instance, never `Open3`.

### Process-global caches leak between tests in the same worker

The other in-process shape is not a stub at all — it is a cache. `AirCatalogService` holds its resolved artifact
tree in ivars on the class, and `test/test_helper.rb` resolves it once at boot so every forked worker
inherits a warm one. A warm cache is not a nicety here: committing a write to any session attribute the
sessions index shows broadcasts the session card, and `sessions/_session_card.html.erb` renders
`Session#agent_root_key` → `AgentRootsConfig.find_for_session` → `AirCatalogService.entries_for(:roots)`.
On a cold cache that is a real `air resolve` subprocess, fired from the middle of whatever test happens
to be running.

`AirCatalogServiceTest` has to control that cache to test the service, so its teardown calls
`AirCatalogService.reset!` — and hands the next test in that worker a cold one. At `--seed 40537` the
next test was the comment poller's `ignores a merge gate review comment` case (then
`GithubCommentPollerJobTest`, now `Github::CommentEvaluatorTest`),
which asserts `Open3.expects(:capture3).never`; its `persist_comments!` write broadcast the card, the
card resolved the catalog, and the run went red on `main` for a subprocess the test never asked for. The
test was not wrong. Its premise — a warm cache — was being satisfied by whichever test drew the slot
before it, so a reshuffled seed moved the failure to a different victim.

`test/support/air_catalog_cache_warmer.rb` snapshots the boot-resolved tree, and a
`setup(prepend: true)` on `ActiveSupport::TestCase` re-installs it before every test. The `prepend` is
load-bearing: setup callbacks otherwise run in declaration order, and a callback added to a base class is
merely *appended* to the chain of every descendant that already exists — so the framework test cases
`rails/test_help` defines would run their own setups first. Prepending puts the warm-up at the head of
every chain regardless, while still leaving `AirCatalogServiceTest`'s own `setup` to reset the cache on
purpose afterwards. Every other test starts from the same real catalog no matter what ran before it,
which makes the `.never` expectations true by construction rather than by seed luck — and closes the
mirror-image leak too, where a tree left behind by a stubbed resolve makes an unrelated `catalog_skills`
validation reject a skill that does exist.

The snapshot is deep-frozen rather than deep-duped per test. Duping it ~10,000 times would cost more than
the flake, but handing every test one shared *mutable* tree would be worse than the state it replaces: an
in-place mutation used to heal itself at the next resolve, and would now survive `reset!` and poison the
rest of the worker. Frozen, that mutation is a `FrozenError` at the site that causes it.

The rule that generalizes: **a cache on a class object is suite-wide mutable state.** If a test clears
or replaces one, something has to put it back before the next test reads it.

### A `setup` that raises leaves `Rails.cache` swapped out

`Rails.cache` is the same kind of global, one level up. About twenty test files replace the test
environment's `:null_store` with a real `MemoryStore`, because a store that agrees with everything
cannot exercise a hysteresis streak, a cooldown or a heartbeat:

```ruby
setup do
  @original_cache = Rails.cache
  Rails.cache = ActiveSupport::Cache::MemoryStore.new
end

teardown { Rails.cache = @original_cache }
```

That pairing is correct right up until the `setup` raises *before* the capture line. Minitest runs the
`teardown` anyway, `@original_cache` is `nil`, and `Rails.cache` is now `nil` — not for that file, for
every test that draws a later slot in the same parallel worker.

It happened on `main` in September 2026. [#1119](https://github.com/tadasant/zimmer/pull/1119) added
`AlertService.stubs(:raise_alert)` near the top of a `setup`, ahead of the line that captures the cache;
[#1121](https://github.com/tadasant/zimmer/pull/1121) deleted `AlertService`; each was green on its own
branch and neither ran against the other's merge. CI's run of `main` came back with 87 errors. The tests
that named the missing constant failed on it, which is honest. The rest were `NoMethodError` on `nil` —
`Rails.cache.fetch` in `CostAnalytics`, `cache.read` in `GlobalRateLimitTracker` — in files with no
connection to alerts, queues or the cache, picked out by `--seed`. [#1128](https://github.com/tadasant/zimmer/pull/1128) removed the dead
references; what follows is what keeps the next one from spreading.

`test/support/cache_isolation_guard.rb` snapshots the boot store before `parallelize` forks, and
`ActiveSupport::TestCase` checks it on **both** edges of every test. The `teardown` check names the test
that leaked. The prepended `setup` check exists because that is not enough on its own: ActiveSupport
stops running `:teardown` callbacks at the first one that raises, and every teardown a test file or a
later helper module declares runs before the shared one — so a teardown that raises after botching its
restore takes the check down with it, and the leak has to be catchable from the far side too. Neither
check raises; each records its failure on the test instead. A raise from the setup check would skip the
test's own `setup`, capture and all, and send its teardown straight back to restoring `nil`. Both edges
put the boot store back, which is what keeps one broken file to one broken file instead of a worker's
worth of unrelated errors.

The check reads the value Rails holds — `Rails.cache` is a plain `attr_accessor` — rather than calling
the reader. That is what keeps it from flagging a mocha `Rails.stubs(:cache)`, which `BroadcastServiceTest`
uses: mocha replaces the reader, not the value, and takes the stub off itself only after ActiveSupport's
teardown callbacks have run.

If you are writing the swap, capture the original **first**, before anything in the `setup` that can
raise, and make the restore tolerate a `setup` that never got there:

```ruby
teardown { Rails.cache = @original_cache if @original_cache }
```

### The browser suite has its own root cause: the moving target

The system suite flakes for a different reason, and it has its own one-line answer.

Selenium clicks by coordinate. It reads the element's bounding rect, checks the element is really on
top at that point, then asks Chrome to dispatch a pointer event there — separate round trips. An
element that is animating has *moved* by the time the event is dispatched, so the click lands on
whatever slid into those coordinates instead. Nothing raises: the interactability check passed when it
ran. The test just fails later, somewhere else, on an assertion about a page it never meant to be on.

That is exactly how "the session detail drawer closes via the close button and Escape"
([run 29343563011](https://github.com/tadasant/zimmer/actions/runs/29343563011)) failed. The drawer
panel slides in under
`transition-transform duration-300`. The test waits for the lazy Turbo Frame to render, which can
resolve inside those 300ms, then clicks Close while the panel is still travelling. The click landed a
few dozen pixels to the right of the button — on the adjacent "open full page" link, which carries
`data-turbo-frame="_top"` and navigates the entire document to the session page. The drawer, and the
dashboard behind it, ceased to exist; the assertion that the panel is `aria-hidden='true'` reported "no
matches", pointing at a close handler that was never the problem.

`test/application_system_test_case.rb` sets `Capybara.disable_animation = true`, which serves every page
with `transition: none !important; animation-duration: 0s`. CSS-animated elements snap to their final
position, so they are never moving targets. Waiting out the animation test-by-test would have fixed this
one test and left the trap armed for the next one.

The drawer itself has since been taught the same lesson, for the user's sake rather than the suite's:
the panel carries `pointer-events: none` while it slides, so a click aimed at a control that is still
travelling lands on nothing instead of on whatever slid into those coordinates. The gate lifts on
`transitionend` **or** a timer read from the panel's own computed transition duration, whichever comes
first — a zero-duration transition (this suite, or a `prefers-reduced-motion` user) never fires
`transitionend` at all, and a gate keyed on it alone would leave those users an inert drawer forever.
`test/contracts/session_drawer_timing_test.rb` pins that arrangement so the CSS duration and the JS
timing cannot drift apart again.

One gap survives, so know where it is: the injected CSS does **not** defeat a JS-driven
`scrollIntoView({ behavior: "smooth" })` — per CSSOM-View, an explicit `behavior` in the options beats
the CSS `scroll-behavior` property. The select/autocomplete controllers (`goal`, `agent-root-select`,
`catalog-multiselect`, `slash-command`, `subagent-accordion`) scroll
their options that way, so a test clicking an option mid-scroll is still aiming at a moving target.

The rule: **never wait out an animation to make a click land — remove the motion.** And when a system
test fails only on the runner, look at the screenshot: `test-system` uploads `tmp/capybara/` (that is
where `capybara/rails` points `Capybara.save_path`) as the `system-test-screenshots` artifact. The
picture of the wrong page is usually the whole diagnosis.

The upload runs on success too, and that is deliberate. A test may deliberately
`page.save_screenshot` a UI it has just driven — `test/system/dashboard_turbo_actions_test.rb` writes
`proof-*.png` this way — so a PR can show the change working.

CI's Chrome is no longer the only place a screenshot can come from. An agent session can boot the app
itself with [`bin/agent-dev`](/sessions/dev-server/) and drive it with the Playwright browsers already
in the image — provided the `devdb` accessory is running on that host.

### The detached node: a stale handle Chrome reports as something else

The other way a browser test dies on a page it never meant to be on is subtler, because it does not
look like a test problem at all. The backtrace names Selenium and Capybara and contains no line of
ours.

Capybara resolves a set of candidate elements, then calls back on each handle as a separate round
trip: *is it displayed?*, *what is its text?* Replace the document in between and the handle belongs
to a document that no longer exists. WebDriver's answer for that is `StaleElementReferenceError`,
which Capybara lists in `invalid_element_errors`; its `synchronize` loop swallows those and retries
by re-resolving against the page that exists now. That retry is why a Capybara suite tolerates a
re-rendering page at all. Chrome answers with a generic `UnknownError` carrying a CDP payload
instead:

```
Selenium::WebDriver::Error::UnknownError: unknown error: unhandled inspector error:
{"code":-32000,"message":"Node with given id does not belong to the document"}
```

That matches nothing in the list, so it escapes the retry and errors the test.

The exposure is wider than "tests that hold an element across a re-render", which is the shape you go
looking for and mostly will not find. `Capybara::Node::Document#text` is `find(:xpath, "/html")`
followed by a text read on the result, so **`assert_text` runs the visibility filter and then a text
read against the `<html>` element itself** — two calls on a handle no test ever named. Any document
swap can detach it mid-query: a `data: { turbo: false }` form submit, a Turbo visit, a Turbo Stream
replacing a subtree. (`page.evaluate_script` is safe: `Capybara::Session` sends it straight to the
driver rather than through the document node.)

That is [run 33249577977](https://github.com/tadasant/zimmer/actions/runs/33249577977), where
`CostsMobileTest#test_the_calendar_range_is_reachable_and_usable_on_a_phone` errored on the page load
its own Apply button had started. One error in 296 runs, on a commit that touched nothing near the
Costs UI.

`test/support/detached_node_error_translation.rb` translates the error back into the one Chrome
should have raised, and `test/application_system_test_case.rb` installs it. The failure then lands in
the retry Capybara already has, which re-resolves and asks the document that exists. A test that
genuinely wants an element that is gone still fails on its own assertion once the wait expires.

The translation is a net under two rules, not a replacement for them:

- **After an interaction that navigates, wait on something only the new page can satisfy.** The
  calendar test waited on `assert_text "Showing"`, a word that is on the page *before* Apply too, so
  it was satisfied by the outgoing document and everything after it raced the swap.
  `assert_current_path` reads the driver's URL rather than resolving an element, which makes it the
  one wait that cannot observe a detached node.
- **Set an `<input type="date">` from a `Date`, not from its `iso8601` string.** Capybara sets a Date
  through the value property; hand it a String and it falls back to typing characters into the
  field's segments, which land in whatever order the browser's locale puts them. The same calendar
  test submitted `2026-08-26`, applied a range in the year **828**, and passed, because the only
  assertion on the result was that the word "Showing" appeared somewhere.

### The post-`visit` readiness check: a wait pinned to one element

The third one fires before the test body runs at all, which is what makes it hard to read. The
backtrace names `visit` and nothing else:

```
Capybara::ExpectationNotMet: Item does not match the provided selector
    test/application_system_test_case.rb:196:in 'ApplicationSystemTestCase#visit'
    test/system/queued_messages_workflow_test.rb:259:in 'block in <class:QueuedMessagesWorkflowTest>'
```

That message is not ours and not Capybara's `visit` either. turbo-rails wraps `visit` on every system
test — `config.turbo.test_connect_after_actions` defaults to `%i[visit]`, and its engine defines
`def visit(...) = super.tap { connect_turbo_cable_stream_sources }` on `ActionDispatch::SystemTestCase`
— so its readiness check runs after every navigation in the whole suite. Its implementation resolves
the unconnected `<turbo-cable-stream-source>` elements **once**, then waits on each resolved handle:

```ruby
all(:turbo_cable_stream_source, connected: false, wait: 0).each do |element|
  element.assert_matches_selector(:turbo_cable_stream_source, connected: true)
end
```

`assert_matches_selector` re-runs the query and asserts the handle it is holding is in the result.
Two *separate* failures fall out of that, and this app is exposed to both.

**It waits `Capybara.default_max_wait_time`, which is 2 seconds.** This app's own
`cable_reconnect_controller.js` treats a source as merely slow until `grace` (3000ms) has passed, and
doubles from there — so re-subscribes land at roughly t=3s, 9s, 21s. A harness that gives up at 2s
expires *before* the page has made its first re-subscribe attempt: it is not waiting long enough to
see the recovery the app is built around. No stale node is involved here; the element is simply still
unconnected.

**It is pinned to one element object.** `cable-reconnect` re-subscribes a stuck source by
`replaceWith`-ing it out of the document and back in; a Turbo Stream or a frame swap can replace the
subtree outright. Then the identity check is asking about a node the page has moved on from, so the
wait cannot succeed however long it runs — it burns the full timeout and raises.

The two are different failures that produce the *same* message, which is why a run that hit one
cannot be told apart from a run that hit the other. That is
[run 33949817772](https://github.com/tadasant/zimmer/actions/runs/33949817772), where
`QueuedMessagesWorkflowTest#test_deleting_message_updates_remaining_message_positions` errored on its
`visit` on a commit that touched nothing near queued messages — and whose failure screenshot shows the
page fully rendered, three queued messages and all. Rerunning the job passed.

`test/support/turbo_stream_connection_wait.rb` replaces the wait with a poll of the *document*: it
re-reads every source on each tick through `page.evaluate_script`, so a source the page replaced
mid-wait is simply the next reading rather than a wait that can never be satisfied.
`ApplicationSystemTestCase` overrides `connect_turbo_cable_stream_sources` by name, so the fix lands
wherever turbo-rails calls it — including any action added to `test_connect_after_actions` later — and
`wait_for_turbo_streams_connected`, the helper tests call after a navigation that does not go through
`visit`, runs the same poll. A failure now names the channels still pending instead of an element that
went stale.

There are two ceilings because the two callers want different amounts of the re-subscribe ladder. The
post-`visit` one is 5s and covers the *first* re-subscribe: it is spent after every navigation in the
suite, so buying the second attempt there would multiply the dead time of a systemic ActionCable
failure for a signal the first attempt already gives. `wait_for_turbo_streams_connected` is 10s and
covers the first two, because a test that waits explicitly before triggering a broadcast cannot
proceed at all without a subscriber. Neither is paid when the cable is healthy — the poll returns on
its first reading. The unit test reads the 3000ms grace out of the Stimulus controller rather than
restating it, so a controller that starts allowing a source longer than the harness waits fails there
instead of in CI.

The two rules that keep this from mattering:

- **Don't hold an element across anything that can re-render.** `find` then act is fine; `find`, wait,
  then act is a bet on the page standing still. `page.evaluate_script` is the escape hatch —
  `Capybara::Session` sends it straight to the driver rather than through a resolved node.
- **A readiness check belongs on the condition, not on an object.** "Is every stream source connected"
  is a question about the page; "did *this* element gain an attribute" is a question about a handle,
  and the page is entitled to throw the handle away.

### The lazy frame that never appeared: a fetch pinned to the viewport

The fourth one is the same shape as the third — a wait that cannot be satisfied — except that what
the wait depended on was not an element but the *window size*, which no test had set.

[Run 34060027053](https://github.com/tadasant/zimmer/actions/runs/34060027053) failed two
`LostElicitationBannerTest` cases and nothing else, both on the shared wait inside
`ApplicationSystemTestCase#open_transcript_panel`:

```
expected to find css "turbo-frame[id$='_transcript'][complete]" but there were no matches
```

The commit was a catalog-pin fix that touched no view, no controller and no test. The failure
screenshots are of a page that rendered perfectly — and they are **780x437**, where every other
screenshot the same run uploaded is 1400x757 or 375x812. That is the whole diagnosis, in the
artifact:

- **Nothing sized the window.** Rails applies a `screen_size` only to the drivers it registers
  itself; `:selenium_chrome_headless` is this suite's own registration, and it sized nothing. Each
  test got Chrome's headless default of 800x600, or whatever the last file to call `resize_to` left
  behind — which of the two, and which size, was decided by the `--seed` shuffle.
- **At 800x600 the Transcript disclosure starts below the fold.** The header alone fills a 437px
  viewport at that width, and the composer is sticky over the bottom of it.
- **`loading="lazy"` is an intersection trigger, not a layout one.** Turbo watches a lazy frame with
  an `IntersectionObserver` and fetches when it *appears in the viewport*
  (`AppearanceObserver#intersect` → `FrameController#elementAppearedInViewport`). Opening the
  `<details>` by script gave the frame layout at a document position no one had scrolled to, so
  nothing ever intersected, the frame never fetched, and it never gained `complete`. The helper then
  spent its 10 seconds waiting for a request that was never made.

Two changes, because there were two defects and only one of them was in the test:

- **`transcript-panel#loadFrame` switches the frame to `loading="eager"` when the disclosure opens**,
  so opening the panel is what fetches the rows — which is what
  [the transcript page](/sessions/transcripts/#opening-the-transcript-is-what-loads-it) had claimed
  all along. This is a product fix, not a test one: a `#message-N` link opened cold opens the panel
  under a viewport still parked at the top of the page, and a panel the server rendered *already*
  open — the `transcript=open` page the log-level filter re-fetches — fires no toggle at all, so it
  is reached through `frameTargetConnected` instead.
- **`ApplicationSystemTestCase` resizes to 1400x900 before every test.** That is the size the
  twenty-odd files that resize for a phone already restore to, so it is the suite's desktop default
  written down rather than a new one; a subclass that wants a phone still resizes in its own `setup`,
  which runs after this one.

The rule: **a browser test must not inherit its geometry.** A viewport nobody set is a hidden input
to every layout, every click target and every `IntersectionObserver` on the page, and its value is
whatever the shuffle chose. `SessionsTranscriptTest#test_opening_the_transcript_below_the_fold_still_loads_its_rows`
pins the case at the window from that run, and asserts the panel really does start off screen before
opening it — so the test cannot quietly stop covering the thing it is named for.

## The catalog coupling — read this before you debug

:::danger[A broken catalog fails every session test at once]
`test/test_helper.rb` pre-warms the AIR catalog **at boot, before `parallelize` forks its workers**. So
a catalog that fails to resolve does not fail one test. It fails every test that creates a session,
simultaneously, with `ActiveRecord::RecordInvalid`.

The triggers are subtle: a plugin bundling a skill that no longer exists, a `default_in_roots` naming an
unknown root, a skill registered in `skills.json` with no `SKILL.md` body behind its `path`.

If you see a sudden wave of `RecordInvalid` across unrelated session tests, suspect the catalog before
you suspect your change. Run `air resolve` and read *stderr*, not the exit code — AIR
[exits 0 while dropping references](/air/overview/#the-failure-semantics-matter-more-than-youd-think).
:::

## Contract tests

The one solid piece of test architecture here. Runtimes are enforced structurally rather than
by convention:

- **`test/contracts/runtime_cli_adapter_contract_test.rb`** asserts every registered adapter
  (`ClaudeCliAdapter`, `CodexRuntimeAdapter`, `PiRuntimeAdapter`, and their mocks) has
  keyword-set-identical `execute`
  and `resume` signatures — checked via `instance_method(:execute).parameters`, so a renamed kwarg fails
  the build rather than failing at spawn time.
- **`test/contracts/runtime_mcp_credential_writer_contract_test.rb`** does the same for credential writers.

:::caution[The contract test doesn't cover the whole contract]
It checks three of the retry strategy's five predicates. `auth_recovery_needed?`, which
`ProcessLifecycleManager` genuinely calls, is not among them. A new runtime can pass the contract test
and still `NoMethodError` in production. See
[Adding an agent harness](/extend/agent-harness/#retry-strategy-the-five-predicates).
:::

Two more guard a different kind of contract — not between runtimes, but between a test file and the
gems it names. Both parse the `.rb` files under `test/` with Prism, and both exist because the suite
shares one process, so the first file to require a gem silently covers every file loaded after it.
Without them, whether a file works on its own is decided by the order the runner loads files in.

- **`test/contracts/ostruct_require_contract_test.rb`** asserts that a file naming `OpenStruct`
  requires `ostruct` itself. `ostruct` ships with Ruby but is not required for you — a default gem on
  3.4, bundled from 3.5. See [#787](https://github.com/tadasant/zimmer/issues/787).
- **`test/contracts/mocha_require_contract_test.rb`** asserts the same for `mocha/minitest`: a file
  calling `stubs`, `expects`, `any_instance`, `unstub` or `stub_everything`, or naming `Mocha`, has
  to require it. `Bundler.require` loads the `mocha` gem but not its Minitest integration, which is
  what defines those methods. See [#874](https://github.com/tadasant/zimmer/issues/874).

The mocha contract carries a second assertion the ostruct one does not need, and it is the one that
makes the first meaningful. `test_helper.rb` auto-requires every non-`_test.rb` file under
`test/support/**`, so a `require` written inside a support helper is not local to that helper — it is
a **suite-wide require**, and it hides the absence of the same require everywhere else. One line in
`test/support/x_oauth_test_helpers.rb` was loading mocha for the entire suite, which is why 21 files
had accumulated an undeclared dependency on it and why
[#764](https://github.com/tadasant/zimmer/issues/764) could not be reproduced as reported. So no file
every run loads may require `mocha/minitest` — the auto-required support helpers, and `test_helper.rb`
itself along with the two other roots every test file loads by name.

A support helper that stubs is still fine — `XOauthTestHelpers` and `McpAvailabilityHelpers` both do.
It just cannot declare the dependency on its callers' behalf; the test files that call it declare it.
That is the one case neither contract can see, since each reads a single file at a time.

## Running tests

```bash
bin/rails test test/models/session_test.rb    # targeted — do this locally
bin/rails test                                # everything (let CI do this)
bin/rubocop
bin/brakeman
```

The convention in `AGENTS.md`: run **targeted** tests locally, let CI run the full suite.

A targeted run loads only the files you name, so it is the run that usually exposes a missing
`require`. A test file has to require the gems it names — `ostruct` and `mocha/minitest` today —
rather than inheriting them from whatever the full suite happened to load first. The contract tests
above enforce both.

## The philosophy, such as it is

The old `docs/TESTING_PHILOSOPHY.md` was 417 lines. The parts that survive contact with the actual
suite:

- Mock at the boundary, not in the middle. `MockClaudeCliAdapter` / `MockCodexRuntimeAdapter` exist
  so tests never spawn a real CLI, and they are held to the same contract test as the real ones.
- `FileSystemAdapter` and `ProcessManager` are injected, so process and filesystem behavior can be
  faked without stubbing globals. (Issue #10 is a test that reached for a global `File.stub` anyway,
  and now flakes.)
- The state machine is tested as a state machine — its transitions and guards, down to the individual states.

What it does *not* have is meaningful end-to-end coverage of the thing Zimmer does: spawn a
real agent against a real repo. That path is covered by running it.

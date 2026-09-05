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
| `lint` | `bin/rubocop -f github --parallel`, then the two-phase column-drop guard (pure Ruby, no Rails boot — see [Deploying](/operate/deploying/#the-guard)) |
| `security` | `bin/brakeman --no-pager -q` |
| `verify_lockfile` | `bundle lock` then `git diff --exit-code Gemfile.lock` |
| `test-unit` | `bin/rails test` — unit + integration; Postgres 16 + Redis 7 service containers |
| `test-system` | `bin/rails test:system` — the Chrome-driven browser suite; `PARALLEL_WORKERS=1` |
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
-9` to container shims and `rm -rf`s containerd task directories, and `install-worker-watchdog.sh`
writes systemd units. `bash -n` proves those parse and nothing more.

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

The Playwright scripts under `test/e2e/*.js` (`account_rotation`, `chat_bubble`, `joystick_menu`,
`skills_catalog`) are **not** run in CI — the AO parent never ran them either. They are standalone
runners that need a Playwright browser the runner is not provisioned for, and
`account_rotation_test.js` drives the real Claude Code binary against a mock Anthropic server. The
`test-system` job covers the overlapping UI through the Ruby browser suite. Tracked in
[#162](https://github.com/tadasant/zimmer/issues/162).

Neither does CI ever run a **migration**. Both test jobs build the database with `bin/rails
db:test:prepare`, which *loads* `db/schema.rb` — so a schema that disagrees with `db/migrate/` is
green here and diverges from production, which does run them. `db:schema:verify` is the check, and
it is deliberately outside the gate because it drops and recreates databases:

```bash
RAILS_ENV=test bin/rails db:schema:verify
```

It migrates a scratch database from zero, loads the committed schema into another, dumps both, and
diffs. Run it on any PR that adds a migration. `test/migrations/schema_dump_test.rb` covers the cheap
half in CI — that the dumps are in the running Active Record version's format, and that `schema.rb`
is at the newest migration on disk.

**It does not pass today, and that is the finding.** `db/migrate/` is not replayable from zero:
`20260613193000_add_session_maintenance_indexes` builds a partial index on `sessions.transcript`, and
no migration in the directory ever creates that column — `db/schema.rb` declares it, so every
environment got it from a schema load rather than from the migrations. A from-zero `db:migrate` dies
there with `PG::UndefinedColumn`. Nothing noticed because nothing has migrated from zero since.

The task takes some care to see this at all: `db:migrate` against a database with no
`schema_migrations` table does **not** run the migrations — it loads `db/schema.rb` and stamps every
version as applied. So the from-zero pass moves the schema files out of the way first. Without that,
both passes just re-dump the committed schema and the check reports OK for any drift.

## Tests that skip themselves

Several tests `skip` when a credential or file is absent — which in CI means they never run at all:

| Test | Skips when |
| --- | --- |
| `preregistered_oauth_config_test.rb:189` | "OAuth credentials not available (CI environment)" |
| `secrets_loader_test.rb:158` | "Credentials key not available (CI environment)" |
| `references_config_test.rb:79` | "references directory not found" |
| `air_catalog_ref_rewriter_test.rb:190,198` | "air.production.json not present" / "no `github://` catalogs to pin" |
| `sessions_test.rb` "changing agent root updates MCP server selection…" | Needs **two** agent roots with `default_mcp_servers`. Only `playwright-custom` declares `default_in_roots` (→ `zimmer`), so exactly one root qualifies and the test always skips — the root→MCP-defaults switch has no system coverage. |

That last pair means the catalog-pinning feature has zero CI coverage — the code path exists,
the tests exist, and neither runs. Tracked in [#69](https://github.com/tadasant/zimmer/issues/69).

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
next test was `GithubCommentPollerJobTest#test_poll_comments_for_session_ignores_a_merge_gate_review_comment`,
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
the CSS `scroll-behavior` property. The select/autocomplete controllers (`goal`, `mcp-server-select`,
`plugins-select`, `hooks-select`, `slash-command`, `subagent-accordion`) scroll their options that way,
so a test clicking an option mid-scroll is still aiming at a moving target.

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
  (`ClaudeCliAdapter`, `CodexRuntimeAdapter`, and their mocks) has keyword-set-identical `execute`
  and `resume` signatures — checked via `instance_method(:execute).parameters`, so a renamed kwarg fails
  the build rather than failing at spawn time.
- **`test/contracts/runtime_mcp_credential_writer_contract_test.rb`** does the same for credential writers.

:::caution[The contract test doesn't cover the whole contract]
It checks three of the retry strategy's five predicates. `auth_recovery_needed?`, which
`ProcessLifecycleManager` genuinely calls, is not among them. A new runtime can pass the contract test
and still `NoMethodError` in production. See
[Adding an agent harness](/extend/agent-harness/#retry-strategy-the-five-predicates).
:::

A second one guards a different kind of contract — not between runtimes, but between a test file and
the gems it names. **`test/contracts/ostruct_require_contract_test.rb`** parses every `.rb` under
`test/` with Prism and asserts that a file naming `OpenStruct` requires `ostruct` itself. `ostruct`
ships with Ruby but is not required for you (a default gem on 3.4, bundled from 3.5), and the suite
shares one process, so the first file to require it silently covers every file loaded after it.
Without the contract, whether a file works on its own is decided by the order the runner loads files
in. See [#787](https://github.com/tadasant/zimmer/issues/787).

## Running tests

```bash
bin/rails test test/models/session_test.rb    # targeted — do this locally
bin/rails test                                # everything (let CI do this)
bin/rubocop
bin/brakeman
```

The convention in `AGENTS.md`: run **targeted** tests locally, let CI run the full suite.

A targeted run loads only the files you name, so it is the run that usually exposes a missing
`require`. A test file has to require the gems it names — `ostruct` today — rather than inheriting
them from whatever the full suite happened to load first. The contract test above enforces that for
`ostruct`; `mocha/minitest` is the same hazard and is not yet covered
([#874](https://github.com/tadasant/zimmer/issues/874)), which also covers the wrinkle that a require
landing anywhere in `test/support/**` becomes a de-facto suite-wide one.

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

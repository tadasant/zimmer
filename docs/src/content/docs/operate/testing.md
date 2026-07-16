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
| `lint` | `bin/rubocop -f github --parallel` |
| `security` | `bin/brakeman --no-pager -q` |
| `verify_lockfile` | `bundle lock` then `git diff --exit-code Gemfile.lock` |
| `test-unit` | `bin/rails test` — unit + integration; Postgres 16 + Redis 7 service containers |
| `test-system` | `bin/rails test:system` — the Chrome-driven browser suite; `PARALLEL_WORKERS=1` |
| `retention_logic` | `ruby scripts/ghcr_retention_test.rb` (pure Ruby, no Rails boot) |
| `docs_site` | Builds this documentation site |
| `all-checks-pass` | Aggregate gate — `needs:` every job above and fails if any failed or was cancelled |

## The single branch-protection gate

`all-checks-pass` is the one status check to require under **Settings → Branches → main**, instead
of enumerating every job. It runs with `if: ${{ always() }}` (so a failed dependency can't leave it
perpetually "skipped" and block the branch), fails if any dependency reported `failure` or
`cancelled`, and treats a `skipped` dependency — the fork-guarded jobs skip on fork PRs — as neither
a pass nor a failure.

## The browser suite runs

`test-system` runs `test/system/*.rb` through Capybara + Selenium against headless Chromium. It is a
separate job from `test-unit` because `bin/rails test` does not descend into `test/system`, because
the shared runner has a companion system-test semaphore keyed on the `test-system` job name, and
because it pins `PARALLEL_WORKERS=1` — the persistent per-worker `--user-data-dir` in
`test/application_system_test_case.rb` does not tolerate concurrent Chrome instances. Chrome is
assumed pre-provisioned on the runner; the CI branch of that file points Selenium at
`/usr/bin/chromium-browser` with `--no-sandbox`. This closes
[#87](https://github.com/tadasant/zimmer/issues/87).

## What CI does not run

The Playwright scripts under `test/e2e/*.js` (`account_rotation`, `chat_bubble`, `joystick_menu`,
`skills_catalog`) are **not** run in CI — the AO parent never ran them either. They are standalone
runners that need a Playwright browser the runner is not provisioned for, and
`account_rotation_test.js` drives the real Claude Code binary against a mock Anthropic server. The
`test-system` job covers the overlapping UI through the Ruby browser suite. Tracked in
[#162](https://github.com/tadasant/zimmer/issues/162).

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

## Flaky tests and the two root causes behind them

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

One gap survives, so know where it is: the injected CSS does **not** defeat a JS-driven
`scrollIntoView({ behavior: "smooth" })` — per CSSOM-View, an explicit `behavior` in the options beats
the CSS `scroll-behavior` property. The select/autocomplete controllers (`goal`, `mcp-server-select`,
`plugins-select`, `hooks-select`, `slash-command`, `subagent-accordion`) scroll their options that way,
so a test clicking an option mid-scroll is still aiming at a moving target.

The rule: **never wait out an animation to make a click land — remove the motion.** And when a system
test fails only on the runner, look at the screenshot: `test-system` uploads `tmp/capybara/` (that is
where `capybara/rails` points `Capybara.save_path`) as the `system-test-screenshots` artifact on
failure. The picture of the wrong page is usually the whole diagnosis.

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

## Running tests

```bash
bin/rails test test/models/session_test.rb    # targeted — do this locally
bin/rails test                                # everything (let CI do this)
bin/rubocop
bin/brakeman
```

The convention in `AGENTS.md`: run **targeted** tests locally, let CI run the full suite.

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

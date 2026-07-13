---
title: Testing philosophy
description: What CI runs, what it doesn't, the contract tests that keep runtimes honest, and the catalog coupling that can redden the whole suite at once.
sidebar:
  order: 4
---

## What CI runs

`.github/workflows/ci.yml`, on every PR and every push to `main`:

| Job | What |
| --- | --- |
| `lint` | `bin/rubocop -f github --parallel` |
| `security` | `bin/brakeman --no-pager -q` |
| `verify_lockfile` | `bundle lock` then `git diff --exit-code Gemfile.lock` |
| `test` | `bin/rails test` — Postgres 16 + Redis 7 service containers |
| `retention_logic` | `ruby scripts/ghcr_retention_test.rb` (pure Ruby, no Rails boot) |
| `docs_site` | Builds this documentation site |

## What CI does not run

:::danger[System tests are excluded from CI]
The `test` job's own step name says it: *"Run tests (unit + integration; system tests excluded)."*

The browser suite never runs on a pull request. Combined with the fact that four of the ten open
issues are UI regressions (#12 undo toast, #13 drag order, #14 full page reloads, #15 no per-card
refresh), this is the obvious hole in the safety net. Those bugs are exactly the class a system test
would have caught. Tracked in [#87](https://github.com/tadasant/zimmer/issues/87).
:::

## Tests that skip themselves

Several tests `skip` when a credential or file is absent — which in CI means they never run at all:

| Test | Skips when |
| --- | --- |
| `preregistered_oauth_config_test.rb:189` | "OAuth credentials not available (CI environment)" |
| `secrets_loader_test.rb:158` | "Credentials key not available (CI environment)" |
| `references_config_test.rb:79` | "references directory not found" |
| `air_catalog_ref_rewriter_test.rb:190,198` | "air.production.json not present" / "no `github://` catalogs to pin" |

That last pair means the catalog-pinning feature has zero CI coverage — the code path exists,
the tests exist, and neither runs. Tracked in [#69](https://github.com/tadasant/zimmer/issues/69).

## Flaky tests and the one root cause behind them

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
- **`GoodJob::Job` autoload** is forced in `test/test_helper.rb` before `parallelize` forks, so no worker
  thread races the lazy Zeitwerk load.

The rule that prevents the next one: **do not stub, mock, or set expectations on a shared global
(`File`, `Dir`, `Kernel`, `Rails.logger`) in this suite.** Inject a seam, point at a real temp file, or
capture output — anything scoped to the object and lifetime under test.

## The catalog coupling — read this before you debug

:::danger[A broken catalog fails every session test at once]
`test/test_helper.rb` pre-warms the AIR catalog **at boot, before `parallelize` forks its workers**. So
a catalog that fails to resolve does not fail one test. It fails every test that creates a session,
simultaneously, with `ActiveRecord::RecordInvalid`.

The triggers are subtle: a plugin bundling a skill that no longer exists, a `default_in_roots` naming an
unknown root, a skill shortname colliding with one from the orchestrator's default skill set.

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

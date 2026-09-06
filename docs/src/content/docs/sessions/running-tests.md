---
title: Running tests inside a session
description: The local-verification path for an agent session — where the gems and the database come from, how to run targeted unit and system tests, and what is deliberately out of reach.
---

An agent session that changes behaviour should be able to run the test that covers it,
before it pushes. For a long time it could not: `bin/rails` did not boot at all, so every
form of verification was deferred to CI, and the first CI run was where a session found
out whether the test it had just written even ran
([#592](https://github.com/tadasant/zimmer/issues/592)).

It works now. This page is the whole recipe, and the reasoning for the two pieces of it
that are not obvious.

## The gems are already there

Nothing to install, and nothing to export. A clone of this repo at a commit that has not
touched the `Gemfile` shares the image's `/usr/local/bundle`, and `AgentSessionJob` settles
that *inline* while it sets the clone up — so `.bundle/config` is on disk before the agent
process exists:

```bash
bin/rails --version   # => Rails 8.1.3
```

If that instead prints `Bundler::GemNotFound` listing a hundred gems, the clone needs a
bundle of its own (its `Gemfile` differs from the image's) and `BundleInstallJob` is
installing one in the background. It takes a couple of minutes; the session log says when
it is done. `bin/agent-dev --skip-server` forces the same repair in the foreground.

:::note[Why there is no `export GEM_PATH=…` here]
`CliSpawnEnv` strips every `BUNDLE_*` and `GEM_*` variable from a session's environment,
deliberately, so a clone resolves its own gems rather than inheriting Zimmer's. That makes
`<clone>/.bundle/config` the single thing that decides where a clone's gems come from —
setting `GEM_PATH` in the image would not survive the spawn, and setting it by hand in one
shell does not reach the next one. See
[Giving a clone its gems](/operate/background-jobs/#giving-a-clone-its-gems).
:::

## Point at the dev database

There is no Postgres on `localhost` and no way for a session to start one — no root, no
sudo, no server binaries in the image. What there is, is the shared `devdb` Kamal
accessory on the container network, which is the same database
[`bin/agent-dev`](/sessions/dev-server/) boots against. Borrow its wiring:

```bash
export DATABASE_HOST=zimmer-devdb \
       DATABASE_PORT=5432 \
       DATABASE_USERNAME=zimmerdev \
       DATABASE_PASSWORD=zimmerdev \
       DATABASE_SSLMODE=disable \
       DATABASE_NAME="$(bin/agent-dev --print-database-name)" \
       RAILS_ENV=test
unset DATABASE_URL
```

Three of those lines are load-bearing and none of them is guesswork:

- **`DATABASE_SSLMODE=disable`.** The deployment sets `require` for DigitalOcean Managed
  Postgres; `devdb` speaks plaintext, and libpq's answer to that pairing is a refused
  connection that reads like a broken database.
- **`DATABASE_NAME` from `bin/agent-dev --print-database-name`.** Every session on the
  droplet shares one `devdb`, so the name is derived from the clone directory. Skip it and
  two sessions run each other's migrations.
- **`unset DATABASE_URL`.** It outranks every discrete variable above, and Rails' own
  `each_current_configuration` drops the *test* databases whenever it is set.

Then create the schema once per clone:

```bash
bin/rails db:test:prepare      # ~25s
```

## Run the test

```bash
bin/rails test test/jobs/bundle_install_job_test.rb
```

Targeted, by file or by `file:line`. Sessions run with `PARALLEL_WORKERS=2` — Zimmer sets
it, and a session also runs inside a 4 GiB memory cgroup of its own, so an over-parallel
run is bounded rather than a threat to the worker or to another session. If a run dies
with **exit 137** that bound is what killed it: run one file at a time rather than raising
the worker count.

**The full suite is not the point of this path and is not worth attempting** — it is
thousands of tests against a shared database on a busy droplet. CI runs it. Run what your
diff touches, and let CI be the one that runs everything.

## System tests work too

Chrome is in the image. It cannot start its setuid sandbox in this container, and
`test/application_system_test_case.rb` already carries the opt-in for exactly that case —
`CHROME_NO_SANDBOX=true`, which is deliberately *not* spelled `CI=true` (that would also
point the binary at a `chromium-browser` path only the CI image has).

One extra step first: the layout links a compiled stylesheet, and a fresh clone has none,
so every page render fails with `The asset 'tailwind.css' was not found in the load path.`

```bash
bin/rails tailwindcss:build                                   # once per clone
CHROME_NO_SANDBOX=true bin/rails test test/system/code_block_copy_test.rb
```

Screenshots land in `tmp/capybara/` — Capybara writes one automatically for every failing
system test, which is usually the fastest way to see what a session's change actually did.
Share them the way [`GIT_WORKFLOW.md`](https://github.com/tadasant/zimmer/blob/main/GIT_WORKFLOW.md)
describes: a session's filesystem is not reachable by the person reading the PR.

A system test that drives a *runtime* rather than a screen is a different matter —
`test/system/smoke_test.rb` spawns a real agent process and will not pass here. That is not
a broken recipe; it is a test that needs something this environment does not have.

## Put anything long-lived in the scratch directory

The session container is recreated on every deploy, and the clone goes with it. Anything
that has to outlive that belongs under `$AO_SESSION_SCRATCH_DIR`, which is on the durable
volume. Test databases do not need this — they live in `devdb` — but a fixture corpus or a
captured artifact does.

## What this does not cover

- **Booting the app** to click through a change: that is
  [`bin/agent-dev`](/sessions/dev-server/), which prepares the same database in the
  *development* environment and starts a server.
- **The full suite, `bin/rubocop --parallel` over the whole tree, or Brakeman.** CI owns
  those, and it is faster at them.

---
name: sync-docs
title: Sync Docs
description: >
  Pre-PR step: right before opening a pull request, review Zimmer's documentation
  against the branch diff and update whatever has gone stale — README.md,
  AGENTS.md / CLAUDE.md, CONTRIBUTING.md, docs/, the REST API reference, and the
  artifact indexes' own prose — so docs ship in the same PR and never drift from
  code. Default, always-on: run it as the final pre-PR routine after staging
  changes and before creating the PR. Scoped strictly to this repo's own docs.
user-invocable: true
---

# Sync Docs

Keep Zimmer's documentation in sync with the code change about to be PR'd. Docs
drift the moment a behavior, flag, path, command, schema, or convention changes
without the surrounding prose being updated. This skill closes that gap as the
last step before a PR is opened.

> Vendored copy of the central Reframe `sync-docs` skill
> (`reframe-systems/agentic-engineering` → `artifacts/skills/sync-docs`), adapted
> to Zimmer's documentation surface. Zimmer's artifact catalog is self-contained
> and offline by design, so the skill body lives here rather than being resolved
> from a remote catalog. Improvements worth sharing belong upstream too.

Drift has two shapes, and both are in scope. **Code-vs-docs drift** is a doc that
no longer matches the code the diff changed. **Intra-doc drift** is a doc that no
longer matches *itself*: a fact stated in several places (a summary or lead-in
paragraph *and* the detail tables beneath it) gets updated in one place but not
the others, so the doc contradicts its own body. The second kind is easy to miss
because the stale text isn't a renamed symbol you can grep for — it's a still-
plausible sentence whose *claim* is now wrong. Catch both.

## When to use

Run this **every time you are about to open a pull request** — as the final
pre-PR step, after your code changes are staged and before the PR is created. It
is a **default, always-on** skill: don't wait to be asked.

If the diff has no documentation implications (e.g. an internal refactor with no
behavior, interface, or convention change), confirm there's nothing to sync and
move on — do not invent edits.

## Zimmer's documentation surface

Cast a wide net, then narrow to what the diff actually affects:

| Surface | What it covers |
| --- | --- |
| `README.md` | Project overview, prerequisites, local setup, architecture summary. |
| `AGENTS.md` (`CLAUDE.md` is a symlink to it) | House rules for humans and coding agents: working practices, architecture orientation, conventions. |
| `CONTRIBUTING.md` | Contributor workflow and any known-broken/known-coupling caveats. |
| `docs/` | The deep references — see below. |
| `docs/AGENTS.md` | Guidance for the docs tree itself. |
| Artifact indexes | `skills/skills.json`, `roots.json`, `mcp.json`, `plugins/`, `hooks/`, `references/`, and the `air.json` / `air.production.json` that wire them. |
| Doc comments | Class/module header comments in `app/services/`, `app/models/`, `app/jobs/` — Zimmer leans on these heavily as the real explanation of a service. |

Two `docs/` pages have **hard sync requirements** that AGENTS.md calls out
explicitly — treat these as non-negotiable:

- **`docs/REST_API.md` must stay in sync with `app/views/api_docs/show.html.erb`.**
  Any endpoint, parameter, or response-shape change means editing *both*. The
  ERB view is the rendered API docs page; the Markdown is the reference. They
  drift silently because nothing tests that they agree.
- **`docs/SESSION_STATE_MACHINE.md`** documents the AASM states in
  `app/models/session.rb` (waiting → running → needs_input → failed / archived).
  Any transition, guard, or callback change belongs here.

Other `docs/` pages, by the change that should trigger them:

- `ADDING_AN_AGENT_HARNESS.md` — a new/changed pluggable runtime (`RuntimeRegistry`,
  runtime adapters, auth, staging/prod parity).
- `AO_EXTENSIONS.md`, `AUTHORING_AN_AO_EXTENSION.md`, `EXTENSIONS_INSTALL.md` —
  anything under `app/extensions/` or the extension loading/install path.
- `MCP_CONFIGURATION.md` + `mcp.schema.json` — the shape of `mcp.json` or how MCP
  servers are configured/injected.
- `DEPLOYING_ON_DIGITALOCEAN.md`, `PROVISIONING.md` — `infra/terraform/`, the
  deploy/teardown workflows, or provisioning steps.
- `OAUTH_ARCHITECTURE.md`, `CLAUDE_CODE_OAUTH_ASSUMPTIONS.md`, `CODEX_AUTH.md`,
  `X_OAUTH_TOKEN_VENDING.md`, `AUTH_ROTATION_ARCHITECTURE.html` — auth, account
  pooling, token vending.
- `TRANSCRIPT_HOOKS.md`, `OPEN_TRANSCRIPTS.md` — transcript polling, hooks, schema.
- `ELICITATION_FLOW.md` — MCP elicitation/fallback.
- `TESTING_PHILOSOPHY.md` — testing conventions.

## Scope constraint — this repo only

**Only review and update documentation inside this repository.** Do not touch:

- Other repositories or checkouts on the machine (notably the private
  `tadasant-internal` repo that owns the production deploy).
- Vendored or third-party docs under `vendor/`, `node_modules/`, build output.

If you notice docs in another repo have likely gone stale because of this change,
**report it to the user** so they can follow up — do not edit across repo
boundaries.

## Procedure

1. **Inspect the diff about to be PR'd.**

   ```bash
   git fetch origin --quiet
   git diff origin/main...HEAD
   ```

   Note renamed/removed files, changed method/flag/command/endpoint names, changed
   config keys or defaults, new or removed features, and changed conventions.

2. **Find the docs each change touches.** For every meaningful change, ask which
   documents now describe the code inaccurately. Grep for the old names, flags,
   paths, or values the diff changed — those hits are your candidate stale spots:

   ```bash
   git grep -n "<old-name-or-flag-or-path>" -- '*.md' 'docs/' '*.erb' '*.json'
   ```

   A pure internal change that no doc mentions usually needs **no** doc edit —
   don't manufacture work.

3. **Update the stale docs** so they match the code in the diff. Keep edits
   minimal and DRY: fix what's wrong, update examples/commands/output that no
   longer match, don't rewrite for style, and don't duplicate a fact across files
   that already point at a single source of truth. Zimmer's own conventions apply
   to doc prose too — **no temporal comments** ("now", "used to be", "as of this
   PR"); write the docs as the canonical current state.

4. **Reconcile each doc against itself (internal consistency).** A fact the diff
   changes is often stated more than once in the *same* document — an overview
   paragraph that headlines a number or a model, and the detail tables below it
   that spell it out. Updating one and not the other leaves the doc
   self-contradictory. For every section you touched (or that describes something
   the diff changed):
   - **Re-read the whole section top to bottom**, not just the line you edited.
   - **Reconcile overview prose against its own detail.** If the diff changed the
     headline claim (a default, a "how many", a "you must always X"), update the
     summary *and* every table, example, and callout that restates it — and check
     they now agree with each other, not just with the code.

   This is not a grep for a renamed identifier (step 2 did that); it's a
   read-for-meaning pass.

5. **Validate** what you touched:
   - Any JSON you edited still parses:
     ```bash
     for f in air.json air.production.json roots.json mcp.json skills/skills.json \
              plugins/plugins.json hooks/hooks.json references/references.json; do
       ruby -rjson -e "JSON.parse(File.read('$f')); puts '$f OK'"
     done
     ```
   - Commands and code samples in the docs are real (they exist in `bin/`,
     `scripts/`, `lib/tasks/`, or `.github/workflows/`).
   - Internal links and file paths still resolve.
   - If you touched `docs/REST_API.md`, confirm `app/views/api_docs/show.html.erb`
     says the same thing.

6. **Report** which docs you updated and why, or state explicitly that the diff
   required no doc changes. Note any out-of-scope/downstream docs that look stale
   so the user can follow up separately.

## Composition

- Runs as the documentation step of the pre-PR routine, before the commit, so doc
  edits ship in the same PR.
- Complements CI skills (`wait-for-ci`) rather than replacing them — this skill
  fixes docs, they verify code.
- Distinct from skills that merely *flag* stale docs: this one actually updates
  them, and only in this repo.

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

## Brand and voice — non-negotiable for any prose you write

Two references travel with this skill and govern every word you add or rewrite:

- **`references/brand`** (`references/BRAND.md`) — what Zimmer is, who it's for (a
  single circle of trust: personal, a couple, or partners — never teams or
  enterprise), and the opinions that follow. It decides framing: the trust model
  is intent, not apology; the human stays in control; Zimmer handles the toil.
- **`references/brand-voice`** (`references/BRAND_VOICE.md`) — how Zimmer sounds:
  plain, direct, specific, honest, and free of AI-slop tells (the antithesis
  reflex, em-dash overload, bold sprinkling, hype adjectives, filler verbs).

Read both before touching user-facing prose (docs, README, UI copy). When you fix
a stale fact, fix it *in Zimmer's voice* — don't leave slop behind just because it
was there before. When a wording or framing choice is ambiguous, the brand
reference decides it, not your instinct.

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
| **`docs/`** | **The documentation site** (Astro Starlight → Cloudflare Pages). Pages live in `docs/src/content/docs/**`. This is the canonical prose. |
| Artifact indexes | `skills/skills.json`, `roots.json`, `mcp.json`, `plugins/`, `hooks/`, `references/`, and the `air.json` / `air.production.json` that wire them. |
| Doc comments | Class/module header comments in `app/services/`, `app/models/`, `app/jobs/` — Zimmer leans on these heavily as the real explanation of a service. |

### Which docs-site page does this diff touch?

Pages are under `docs/src/content/docs/`:

| Code area | Page |
| --- | --- |
| `app/models/concerns/session_state_machine.rb` | `sessions/lifecycle.md` |
| `app/jobs/agent_session_job.rb`, CLI adapters, `ProcessLifecycleManager` | `sessions/spawning.md` |
| `config/goals.json`, goal handling | `sessions/goals.md` |
| transcript polling / normalizers / `OpenTranscript` | `sessions/transcripts.md` |
| `Trigger`, `TriggerCondition`, trigger jobs | `sessions/triggers.md` |
| `Elicitation`, elicitation controllers | `sessions/elicitation.md` |
| `config/routes.rb`, `app/controllers/api/**` | `extend/rest-api.md` |
| `RuntimeRegistry`, a new/changed runtime | `extend/agent-harness.md` |
| `app/extensions/**`, `Zimmer::ExtensionRegistry` | `extend/extensions.md` |
| `app/services/transcript_hooks/**` | `extend/transcript-hooks.md` |
| `air.json`, `roots.json`, `mcp.json`, `skills/`, `plugins/`, `hooks/`, `AirCatalogService`, `AirPrepareService` | `air/*.md` |
| OAuth, `ClaudeAccount`, `McpOauthCredential`, `RuntimeAuthProvider` | `auth/*.md` |
| `infra/`, `Dockerfile*`, `.github/workflows/**` | `operate/deploying.md`, `operate/provisioning.md` |
| any GoodJob cron entry | `operate/background-jobs.md` |
| test conventions, CI jobs | `operate/testing.md` |
| architecture, philosophy, core vocabulary | `intro/*.md` |

**Two hard sync requirements — treat these as non-negotiable:**

- **`docs/src/content/docs/extend/rest-api.md` must stay in sync with
  `app/views/api_docs/show.html.erb`.** Any endpoint, parameter, or response-shape
  change means editing *both*. Nothing tests that they agree, so they drift silently.
- **`docs/src/content/docs/sessions/lifecycle.md`** documents the AASM states and
  events in `app/models/concerns/session_state_machine.rb`. Any transition, guard, or
  callback change belongs there — including the state diagram.

**New brittleness goes on the limitations page.** If the diff introduces (or reveals) a
hack, a hardcoded assumption, a known-broken edge, or a "we don't know yet," add it to
`docs/src/content/docs/limitations.md` *and* as an inline `:::caution` / `:::danger`
callout on the relevant page. That page is a deliberate feature of this site, not a
confession — under-reporting it is the failure mode, not over-reporting it.

**Adding a page?** It must also go into the `sidebar` array in `docs/astro.config.mjs`.
Starlight does not auto-discover pages into the nav.

**Diagrams** are Mermaid fenced code blocks. If you changed a flow that a diagram
depicts, change the diagram — they are meant to be accurate to the code, not
illustrative.

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
   git grep -n "<old-name-or-flag-or-path>" -- '*.md' 'docs/src/' '*.erb' '*.json'
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
   - If you touched `docs/src/content/docs/extend/rest-api.md`, confirm
     `app/views/api_docs/show.html.erb` says the same thing.
   - **The site still builds:** `cd docs && npm run build`. This is what the
     `docs_site` CI job runs — a bad frontmatter field or a page missing from the
     sidebar fails the PR.

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

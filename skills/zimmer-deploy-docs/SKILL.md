---
name: zimmer-deploy-docs
title: Deploy Zimmer's Docs Site
description: >
  Decide whether a docs change warrants publishing the site — and publish it if so.
  Zimmer's docs site does NOT auto-deploy: the `Deploy docs` workflow is
  workflow_dispatch-only (plus one weekly production refresh), because Cloudflare
  Pages' Git integration was rebuilding the site on every push and every PR at
  4.5–8 min of build plus up to 27 min of queue. The default answer is DO NOT
  deploy: CI already proves the site builds, so prose changes need nothing. Deploy
  when you have changed how the docs LOOK or restructured a large swath of them —
  the cases where something can plausibly be broken in a way only a rendered page
  reveals. Covers the criteria, dispatching a preview vs a production deploy, and
  reading back the URL.
user-invocable: true
---

# Deploy Zimmer's Docs Site

The docs site (`docs/`, Astro Starlight) is published to **Cloudflare Pages** at
[docs.zimmer.tadasant.com](https://docs.zimmer.tadasant.com). It is **not**
deployed by pushing. `.github/workflows/deploy-docs.yml` (workflow name:
**`Deploy docs`**) is `workflow_dispatch`-only, with a single weekly cron that
refreshes production from `main`.

That is deliberate. Cloudflare Pages' Git integration used to rebuild the site on
every push to `main` and on every push to every PR branch — 4.5–8 minutes of build
each, behind a queue measured as high as **27 minutes**, reported back as a check on
the PR. Nearly all of those builds republished byte-identical prose for a commit
that never touched `docs/`. The automatic builds are off; this workflow replaced
them.

## The decision: usually, don't

**The default is NOT to deploy.** Ask what a deploy would actually tell you that CI
has not already told you.

CI's `docs_site` job answers **"does it build?"** — broken frontmatter, a dead
internal link, a page missing from the sidebar. That job is path-conditional now, so
it runs on exactly the changes that could break the build, and its green check is
sufficient evidence for a docs change that is only words.

A deploy answers a different question: **"does it look right?"** Pay for that only
when the answer is genuinely in doubt.

### Deploy when

- **You changed how the docs look.** Custom CSS, Starlight theme or component
  overrides, `astro.config.mjs` presentation config, a new component, a logo or
  favicon, colors, typography, layout. A build cannot tell you a page renders ugly
  or a component collapses at mobile width.
- **You restructured a large swath of the docs.** A sidebar reorganization, a
  many-page move/rename/split/merge, a mass rewrite. The build proves the links
  resolve; it does not prove the navigation still makes sense to a reader, and a
  big refactor is exactly where a page ends up orphaned-but-valid.
- **You are adding something with a rendered surface you have not seen before** — a
  Mermaid diagram that could render as a wall of text, a large table, an embedded
  asset.
- **A human asked you to.** Obviously.

The through-line: **deploy when there is a real chance something broke in a way only
a rendered page reveals, and you want to go look at it.**

### Do NOT deploy when

- **Routine content changes.** Fixing a stale fact, correcting a command, adding a
  row to a table, adding an entry to `limitations.md`. This is the common case and
  it covers essentially every docs edit that rides along with a code change.
- **`sync-docs` updated a page because behavior changed.** That is the normal,
  always-on path. It produces prose; prose that builds is prose that works.
- **You just want to confirm the site still builds.** That is what CI is for. Do not
  spend a Pages deploy to learn something a green check already told you.

If you are on the fence, don't. A docs deploy is never urgent — the weekly cron
publishes `main` regardless, so nothing you merge is stranded.

## Dispatching a deploy

An agent session **can** do this: the runner holds the Cloudflare credentials, not
your session.

**Preview** — a throwaway `*.pages.dev` URL for an unmerged branch. This is what you
want when you are eyeballing your own work:

```bash
gh workflow run deploy-docs.yml \
  -f ref="$(git rev-parse --abbrev-ref HEAD)" \
  -f environment=preview
```

**Production** — publishes to `docs.zimmer.tadasant.com`. Normally you only do this
from `main`, after the change is merged:

```bash
gh workflow run deploy-docs.yml -f ref=main -f environment=production
```

`environment` defaults to **`preview`**, so an argument-less dispatch cannot
accidentally publish an unreviewed branch to the public site. Because the workflow is
`workflow_dispatch`, GitHub reads the workflow *definition* from `main`, while the
`ref` **input** selects the code to build — which is why an unmerged branch works.

## Reading back the URL

The deploy URL is the point of the exercise. The run writes it to the job summary:

```bash
run_id="$(gh run list --workflow=deploy-docs.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$run_id"
gh run view "$run_id" --json url --jq '.url'   # then read the summary on that page
```

The `Deploy to Cloudflare Pages` step logs the `*.pages.dev` URL that Wrangler
prints. **Report that URL to the user** — a preview deploy nobody looks at is pure
waste, which is the exact thing this whole setup exists to stop.

If you cannot render or screenshot the page yourself, say so and hand the user the
URL rather than claiming you verified the look of it.

## How it actually deploys

The workflow builds `docs/` **on the GitHub runner** (~30s — the same `npm ci &&
npm run build` that CI's `docs_site` job runs) and uploads the static output with
`wrangler pages deploy`. It does not ask Cloudflare to build anything, which is why
it is an order of magnitude faster than the Git-integration builds it replaced.

Wrangler decides production-vs-preview from the **branch name alone**: a deployment
whose branch is `main` (the project's production branch) goes live on the custom
domain; any other branch name gets its own preview URL. The workflow resolves that
branch from the `environment` input, and guards a detached HEAD so a tag or raw SHA
can never resolve to `main`.

It needs two Actions secrets:

- **`CLOUDFLARE_PAGES_API_TOKEN`** — an account-scoped token with **Cloudflare Pages:
  Edit**. This is deliberately a *different* secret from `CLOUDFLARE_API_TOKEN`, which
  is `Zone:DNS:Edit + Zone:Zone:Read` for ACME DNS-01 cert issuance in
  `domain-cert-staging.yml` and cannot deploy Pages.
- **`CLOUDFLARE_ACCOUNT_ID`**.

The workflow preflights both and fails with instructions if either is missing.

## The thing that will confuse you

**A merged docs change is not live.** With auto-deploy off, `main` and
`docs.zimmer.tadasant.com` are allowed to diverge, and the weekly cron
(Mondays 09:17 UTC) is what reconciles them. So:

- Do not "fix" a docs page because the public site disagrees with `main` — check
  `main` first. The site being behind is the design, not a bug.
- If a docs change genuinely needs to be public *now*, dispatch a production deploy.
  Don't wait for the cron and don't merge a second time.

## Related

- `skills/sync-docs/SKILL.md` — the always-on skill that keeps the docs true in the
  same PR. It says nothing about deploying; this skill is the deploy half.
- `skills/zimmer-deploy-staging/SKILL.md` — deploying the *app*, an unrelated axis.
- `https://docs.zimmer.tadasant.com/meta/contributing/` — the docs site's own guide,
  including how the Pages project is configured.

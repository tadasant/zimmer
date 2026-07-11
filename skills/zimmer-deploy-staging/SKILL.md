---
name: zimmer-deploy-staging
title: Deploy Zimmer to Staging
description: >
  Deploy a Zimmer change to the staging environment. Staging is on-demand and
  manual-dispatch only — the `Deploy staging` workflow takes a `ref` input, so it
  can build and deploy an UNMERGED feature branch, which is the main reason to
  use it. Covers dispatching the run, why the box is reachable only over the
  Tailscale tailnet (not a public URL), watching the deploy, tearing it back
  down, and what an agent session can and cannot do without AWS/DO credentials.
  There is NO production deploy workflow in this repo.
user-invocable: true
---

# Deploy Zimmer to Staging

Staging is **on-demand**: a DigitalOcean droplet that gets created by a deploy and
destroyed nightly. It is dispatched manually and can build from any branch, so it
is the way to exercise an **unmerged** change on a real box.

## The critical facts

- **Staging deploys are `workflow_dispatch`-only.** `.github/workflows/deploy-staging.yml`
  (workflow name: **`Deploy staging`**) never auto-deploys. It takes a `ref` input
  ("Branch/tag/SHA to build & deploy"), falling back to `github.ref`.
- **There is NO production deploy workflow in this repo.** Production lives in the
  private `tadasant-internal` repo and auto-upgrades to the newest
  `ghcr.io/tadasant/zimmer` image. `release-image.yml` (on push to `main`) builds
  and publishes that image and fires a `repository_dispatch`
  (`zimmer-image-published`) to notify it. Do not go looking for a prod deploy
  here, and do not try to deploy prod from this repo.
- **Staging is not on a public URL.** `infra/terraform/staging.tfvars.example`
  sets `domain = ""` (DNS skipped) and the DigitalOcean firewall drops public
  `:80`. The box is reachable **only over the Tailscale tailnet**, as MagicDNS
  host `zimmer-staging`. `https://docs.zimmer.tadasant.com/operate/deploying/` mentions
  `staging.zimmer.tadasant.com`, but that hostname does not resolve by default.

## Dispatching a deploy

An agent session **can** do this: `gh workflow run` is all it takes — the GitHub
runner holds the DigitalOcean and Tailscale credentials, not your session.

```bash
gh workflow run deploy-staging.yml -f ref="$(git rev-parse --abbrev-ref HEAD)"
```

Because the workflow is `workflow_dispatch`, GitHub reads the workflow
*definition* from the default branch; the `ref` **input** is what selects the code
to build and deploy. That is why a feature branch works without merging it.

Watch the run:

```bash
gh run list --workflow=deploy-staging.yml --limit 3
gh run watch "$(gh run list --workflow=deploy-staging.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

What the run does, in order: builds and pushes
`ghcr.io/tadasant/zimmer-base:staging` and `ghcr.io/tadasant/zimmer:staging-<short-sha>`
(+ `:staging-latest`) → reaps the previous droplet and firewall tagged
`zimmer-staging` → `bash scripts/tailnet-reap-node.sh zimmer-staging` (so the
redeployed box reclaims the clean MagicDNS name) → `terraform apply` in
`infra/terraform` with `staging.tfvars` → joins the tailnet → health-checks
`http://<tailnet-ip>/up`, polling 40 × 15s.

The tfstate is **ephemeral** (no remote backend) — which is exactly why the
workflow reaps the prior droplet/firewall/tailnet node by tag rather than by
state. A deploy is a full replace, not an in-place update.

## Verifying the deployed box

You need to be on the tailnet. From a machine that is:

```bash
curl -sf http://zimmer-staging/up && echo "STAGING UP"
```

If your session is **not** on the tailnet, you cannot reach staging directly —
say so rather than pretending to verify. The workflow's own health-check step
(`/up`, 40 × 15s) is legitimate evidence the deploy came up; cite the green run
and link it.

The deploy job runs in the `staging` GitHub environment and shares the
`staging-lifecycle` concurrency group with the teardown workflow, so a deploy and
a teardown can never race.

## Tearing it down

Staging self-destructs nightly at **08:00 UTC** (`teardown-staging.yml`, cron
`0 8 * * *`). Don't leave a droplet running longer than you need, but also don't
panic about cleanup — it is automatic. To do it immediately:

```bash
gh workflow run teardown-staging.yml
```

## Rolling back

There is no "redeploy previous" button. Roll back by dispatching `Deploy staging`
again with an earlier `ref` (a known-good branch or SHA):

```bash
gh workflow run deploy-staging.yml -f ref=<known-good-sha>
```

## What an agent session cannot do

The session itself holds **no** DigitalOcean, Tailscale, or GHCR credentials — the
runner assumes them. So a session **cannot** inspect infrastructure directly (no
`terraform`, `doctl`, or DO API calls against staging) and generally cannot curl
the box unless it is on the tailnet. Dispatch the workflow and read its logs;
that is the supported path. If you need something the workflow does not surface,
flag the gap rather than inventing credentials.

## Related

- `https://docs.zimmer.tadasant.com/operate/deploying/` — the full deploy guide.
- `https://docs.zimmer.tadasant.com/operate/provisioning/` — branch protection, staging secrets, Tailscale ACLs/tags.
- `infra/terraform/README.md` — running Terraform by hand.

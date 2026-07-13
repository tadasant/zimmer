---
name: zimmer-deploy-staging
title: Deploy Zimmer to Staging
description: >
  Deploy a Zimmer change to the staging environment. Staging is a PERSISTENT
  Kamal-deployed droplet, and the `Deploy staging` workflow is manual-dispatch
  only — it takes a `ref` input, so it can build and deploy an UNMERGED feature
  branch, which is the main reason to use it. Covers dispatching the run, the
  Kamal container swap, watching the deploy, rolling back, and what an agent
  session can and cannot do without DO/Tailscale credentials. There is NO
  production deploy workflow in this repo.
user-invocable: true
---

# Deploy Zimmer to Staging

Staging is a **persistent** DigitalOcean droplet reconciled through remote
Terraform state. Deploys are dispatched manually and can build from any branch, so
staging is the way to exercise an **unmerged** change on a real box.

Kamal owns everything above the host: a deploy swaps containers with a
health-gated zero-downtime cutover, it does **not** rebuild the droplet.

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
- **The droplet persists.** It is **not** torn down nightly and **not** recreated
  per deploy. `teardown-staging.yml` is manual-dispatch only. The named volumes
  (clones, Claude credentials, `gh` auth, Postgres data) survive deploys — which
  is the point, and also why a rotated `STAGING_DB_PASSWORD` can strand the app
  against an already-initialized Postgres.
- **`recreate_droplet` is for bootstrap changes only.** Terraform sets
  `ignore_changes = [user_data]`, so changing cloud-init, the Caddyfile, or the
  Kamal deploy key needs `-replace`. Normal app deploys must leave it off.
- **Staging has a domain**: `staging.zimmer.tadasant.com` (Caddy terminates TLS on
  :443 in front of kamal-proxy; the A record and cert are managed by
  `domain-cert-staging.yml`, not Terraform). It is also reachable over the
  Tailscale tailnet as MagicDNS host `zimmer-staging`.

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
(+ `:staging-latest`) → `terraform apply` against **remote state** (DigitalOcean
Spaces, `backend.staging.hcl`), which reconciles the existing droplet in place →
joins the tailnet and resolves `zimmer-staging`'s IP → prints an **observability
preflight** → `kamal deploy` (health-gated container swap) → verifies web *and*
worker → renews the domain cert.

The tfstate is **remote**, so a re-run updates in place rather than replacing the
box. A deploy is a container swap, not a rebuild.

## Verifying the deployed box

```bash
curl -sf https://staging.zimmer.tadasant.com/up && echo "STAGING UP"
# or, on the tailnet:
curl -sf http://zimmer-staging/up && echo "STAGING UP"
```

If your session cannot reach staging, say so rather than pretending to verify. The
workflow's own verification step is legitimate evidence: it health-checks `/up`
**and** asserts the worker is stably running (Running + a stable `RestartCount`),
which is the check that catches a worker crash-looping on a bad DB password. Cite
the green run and link it.

The deploy job runs in the `staging` GitHub environment and shares the
`staging-lifecycle` concurrency group with the teardown workflow, so a deploy and
a teardown can never race.

## Tearing it down

`teardown-staging.yml` is **manual-dispatch only** — there is no nightly cron, and
the droplet is meant to stay up. Destroying it throws away the durable volumes
(clones, Claude credentials, `gh` auth, Postgres data), so do it deliberately:

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

- `skills/zimmer-debug-staging/SKILL.md` — when the deploy is green but staging is
  broken, silent, or hanging.
- `https://docs.zimmer.tadasant.com/operate/deploying/` — the full deploy guide.
- `https://docs.zimmer.tadasant.com/operate/provisioning/` — branch protection, staging secrets, Tailscale ACLs/tags.
- `infra/terraform/README.md` — running Terraform by hand.

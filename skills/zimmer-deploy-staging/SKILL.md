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
- **There is NO production deploy workflow in this repo.** Production lives in a
  private companion repo and auto-upgrades to the newest
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
- **Staging has a domain, but it is still not public.**
  `staging.zimmer.tadasant.com` gets a real cert (Caddy terminates TLS on :443 in
  front of kamal-proxy; the A record and cert are managed by
  `domain-cert-staging.yml`, not Terraform) — but that A record points at the
  droplet's **tailnet IP**, and the DigitalOcean firewall opens no public TCP port
  at all (only `41641/udp`, for Tailscale itself). So the domain resolves for
  everyone and answers for nobody off the tailnet. You need the tailnet either way;
  the domain just gives you HTTPS and a stable `APP_HOST` for OAuth callbacks.

## Before you dispatch: is staging in use? (stand down, don't clobber)

Staging is a **single, shared** droplet, and a deploy is a **container swap** — it
replaces whatever is running for *everyone*, on any branch. Sessions have been
clobbering each other: one deploys branch B and swaps the box out from under
another session that was mid-test on branch A. So **before you dispatch, check
whether staging is already in use, and if it is, stand down until it frees up**
instead of deploying on top of it.

Design the check around signals a deploy session actually has. A `zimmer`-root
session has the `gh` CLI plus Zimmer's self-session tools (`wake_me_up_later`,
self-notify) and its default MCP servers (a browser) — but **not** the `zimmer` /
`zimmer-sessions` session-orchestration MCP, so you **cannot** query other sessions'
state to ask "is someone testing right now." Two things *are* universally observable
from `gh`:

**1. Is a deploy or teardown in flight?** Both workflows share the
`staging-lifecycle` concurrency group, so a queued/in-progress run means the box is
mid-swap — never dispatch on top of that.

```bash
# In-flight staging lifecycle runs (deploy OR teardown). Non-empty ⇒ stand down.
# select != "completed" catches every non-terminal status (queued, in_progress,
# requested, waiting, pending) — don't enumerate them and miss one.
for wf in deploy-staging.yml teardown-staging.yml; do
  gh run list --workflow="$wf" --json databaseId,status,headBranch \
    --jq '.[] | select(.status != "completed")
          | "IN FLIGHT: \(.headBranch) \(.status) run \(.databaseId)"'
done
```

**2. What branch/SHA currently owns the box?** Read the most recent **successful**
`Deploy staging` run's `headBranch`/`headSha`. When the deploy was dispatched with
`--ref <branch>` (the form [recommended below](#dispatching-a-deploy)), this is
authoritative: `headBranch` names the owning branch and its short `headSha` is the
deployed `ghcr.io/tadasant/zimmer:staging-<short-sha>` image tag. (If it was
dispatched with the `-f ref=` input instead, `headBranch` reads `main`; recover the
deployed SHA from that run's image tag via `gh run view <id> --log`.) Compare it to
what you are about to deploy:

```bash
gh run list --workflow=deploy-staging.yml --status success --limit 1 \
  --json headBranch,headSha,createdAt \
  --jq '"OWNS STAGING: \(.[0].headBranch) @ \(.[0].headSha[0:7]) (deployed \(.[0].createdAt))"'
echo "you want to deploy: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
```

- If the box already runs **your** SHA, you are not changing anything — proceed (or
  skip the deploy entirely).
- If it runs a **different, recent** branch/SHA, assume that session is still using
  it. Do **not** clobber it.

**If either check says staging is busy, stand down and re-check later — don't
`sleep` in a blocking loop.** Use the self-session `wake_me_up_later` tool to put
this session to sleep for a few minutes and resume it with a prompt to re-run both
checks; only dispatch once staging is free. (A blocking `sleep` ties up the worker
and dies on a deploy/teardown of *this* Zimmer instance; `wake_me_up_later` is a
durable trigger that survives it.) Re-run both checks after every wake — the box's
owner can change while you sleep — and give up gracefully (leave a note for the
user) rather than looping forever if it never frees.

**The honest limit of this check.** In-flight runs and the deployed ref are the
*only* robust signals. Whether a human or agent is *actively exercising the
already-deployed box right now* — clicking through a feature, watching a worker — is
**not observable** from a session's tools; there is no lock file and no
cross-session MCP. The deployed-ref comparison is a best-effort proxy (a recent
foreign branch on the box probably means someone still cares about it). So also
**announce your intent** before you take the box — say in your session which branch
you're about to deploy and why — so a human watching can wave you off. Treat the
checks as "don't clobber blindly," not "provably safe."

## Dispatching a deploy

Once the checks above say staging is free: an agent session **can** do this,
`gh workflow run` is all it takes — the GitHub runner holds the DigitalOcean and
Tailscale credentials, not your session.

```bash
gh workflow run deploy-staging.yml --ref "$(git rev-parse --abbrev-ref HEAD)"
```

Dispatch with **`--ref <branch>`**, not the `-f ref=` input — and prefer it
precisely because it makes the run **self-describing** for the coordination check
above. A `workflow_dispatch` deploys whatever ref you point it at without merging,
so both forms build your unmerged branch. The difference is what the run *records*:

- With **`--ref <branch>`**, `inputs.ref` is empty so `checkout` falls back to
  `github.ref` = your branch, and the run's `headBranch`/`headSha` are your branch —
  so "who owns the box" can name it. GitHub also reads the workflow *definition*
  from that ref, which means a workflow change on your branch is exercised too.
- With the older **`-f ref="$(git rev-parse --abbrev-ref HEAD)"`** input form (and a
  default `--ref`), GitHub reads the workflow definition from `main` and the box
  still gets your code via `inputs.ref` — but the run records `headBranch=main`, so
  it no longer identifies which branch owns staging, and the ownership check can
  only recover the deployed SHA from the `ghcr.io/tadasant/zimmer:staging-<sha>`
  image tag in the run's log (`gh run view <id> --log`). Use this form only when you
  deliberately need `main`'s workflow definition, or when the ref is a **bare SHA**:
  `--ref` accepts only a branch or tag, so a SHA (e.g. a rollback — see
  [Rolling back](#rolling-back)) must go through `-f ref=<sha>`.

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

Both of these require you to be **on the tailnet** — the domain's A record points at
a tailnet IP:

```bash
curl -sf https://staging.zimmer.tadasant.com/up && echo "STAGING UP"
curl -sf http://zimmer-staging/up && echo "STAGING UP"
```

If your session cannot reach staging, say so rather than pretending to verify. The
workflow's own verification step is legitimate evidence: it health-checks `/up`
**and** asserts the worker is stably running (Running + a stable `RestartCount`),
which is the check that catches a worker crash-looping on a bad DB password. Cite
the green run and link it.

The deploy job runs in the `staging` GitHub environment. Its `concurrency.group` is
the constant string `staging-lifecycle`, and `teardown-staging.yml` uses the **same
constant** — so GitHub serializes *every* run tagged with it: deploy-vs-teardown
**and** deploy-vs-deploy alike. With `cancel-in-progress: false`, a second dispatch
**queues behind** the first instead of cancelling it or racing it. So "one staging
lifecycle run at a time" is already a mechanical guarantee — no workflow change is
needed to enforce it, and none should weaken it (a templated, per-branch group
would let two deploys run at once).

That guarantee is about *workflow runs*, not the box. It stops two runs from
swapping containers simultaneously; it does **nothing** to stop a run from clobbering
an already-deployed box that another session is still *using* after its own deploy
run finished. That gap is exactly what the [stand-down check](#before-you-dispatch-is-staging-in-use-stand-down-dont-clobber)
above covers — the two are complementary, not redundant.

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

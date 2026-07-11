---
title: Provisioning and secrets
description: The Terraform variables, the GitHub Actions secrets, the Tailscale ACLs — and where secrets end up that they shouldn't.
sidebar:
  order: 2
---

## Terraform variables

**Non-secret** (set in `staging.tfvars` / `production.tfvars`):

| Variable | Notes |
| --- | --- |
| `environment` | validated `staging` \| `production` |
| `region` / `droplet_size` | default `nyc3` / `s-2vcpu-4gb` |
| `image_ref` | default `ghcr.io/tadasant/zimmer:latest` |
| `domain` | `""` by default. Set it to turn on [custom-domain HTTPS over the tailnet](/operate/deploying/#custom-domain-https-over-the-tailnet). Terraform no longer creates a DNS record — the `domain-cert` workflow owns the A record. |
| `manage_project` | `false` by default — a DO project name is account-unique and collides under ephemeral state |
| `ssh_key_fingerprints` | |
| `ghcr_username` | |
| `managed_db_cluster_name` | `""` for staging (uses the compose `db`); set for production |
| `managed_db_username` | default `doadmin` |

**Secrets** (as `TF_VAR_*`, all marked sensitive):

`do_token` · `tailscale_auth_key` · `ghcr_token` · `secret_key_base` · `managed_db_password` ·
optional `otel_logs_endpoint`, `otel_logs_token`, `sentry_dsn`.

A `lifecycle.precondition` on the droplet fails the plan if `use_managed_db` is set but
`managed_db_password` is empty.

## GitHub Actions secrets

| Secret | Used by |
| --- | --- |
| `DIGITALOCEAN_ACCESS_TOKEN` | deploy + teardown (droplet reaping) |
| `TAILSCALE_AUTH_KEY` | the droplet's cloud-init `tailscale up` |
| `TS_CI_AUTHKEY` | **CI's own** tailnet join, for the health check |
| `TS_API_CLIENT_ID` / `TS_API_CLIENT_SECRET` | reaping the stale tailnet node |
| `GHCR_PULL_TOKEN` | `docker login ghcr.io` on the droplet |
| `STAGING_SECRET_BASE` | Rails `SECRET_KEY_BASE` for staging |
| `OTEL_LOGS_EXPORTER_ENDPOINT` / `_BEARER_TOKEN`, `SENTRY_DSN_BACKEND` | optional observability |

:::caution[`TS_CI_AUTHKEY` must be a pre-minted auth key, not an OAuth client]
A Tailscale OAuth client cannot mint `tag:ci` keys. `deploy-staging.yml`'s own comment says so.
`docs/DEPLOYING_ON_DIGITALOCEAN.md` told you to use `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET`; that was
wrong and would fail.
:::

## Where secrets end up that they shouldn't

:::danger[Secrets are baked into the droplet's `user_data`]
The GHCR token, the Tailscale auth key, `SECRET_KEY_BASE`, and the database password are all
interpolated into the cloud-init template — which becomes the droplet's `user_data`.

That is readable from the DigitalOcean metadata service by anything running on the box, including
every agent process Zimmer spawns. It's also written into the (ephemeral, but still on-runner)
Terraform state.
:::

:::danger[Staging's Postgres password *is* `secret_key_base`]
`local.db_password` in `main.tf` falls back to `secret_key_base` when no managed-DB password is set.
For staging, that's always.
:::

:::danger[SSH is open to `0.0.0.0/0`]
`digitalocean_firewall.zimmer` allows `22/tcp` from anywhere. The comment says "lock down to your admin
CIDRs in tfvars if desired" — but there is no variable to do that with.
:::

:::danger[Nothing is encrypted at rest in the database]
No model declares `encrypts`; there is no `active_record.encryption` config. Anthropic and OpenAI
refresh tokens, MCP OAuth access and refresh tokens, client secrets, and PKCE verifiers are all
plaintext columns — and the [unauthenticated `/supervisor` panel](/auth/overview/) renders them.
:::

## The three env vars the deploy forgets

`RAILS_MASTER_KEY`, `API_KEYS`, and `APP_HOST` are all consumed by the app and none appear in
`cloud-init.yaml.tftpl`. On a stock droplet:

- the REST API 401s on everything (`API_KEYS` empty),
- every MCP OAuth callback URL points at `localhost:3000` (`APP_HOST` defaults there),
- anything reading Rails encrypted credentials (`mcp_secrets`, `mcp_oauth_clients`) fails.

## Managed Postgres (production)

Not created by Terraform — referenced as a read-only data source. Per
`infra/terraform/data-stores/README.md`, it must already exist:

- Cluster `zimmer-production-pg`, PG16, `db-s-1vcpu-1gb`, 1 node, `nyc3`
- User `doadmin`
- A tag-scoped firewall allowing the `zimmer-production` tag
- Two databases: `zimmer_production` and `zimmer_production_cable` — both must pre-exist. The
  second is Action Cable's, via `solid_cable`.

The app connects over the cluster's `private_host` with `sslmode=require`.

## Tailscale ACLs

The droplet joins the tailnet with `--hostname zimmer` (or `zimmer-staging`) and `--ssh`. MagicDNS then
gives you `http://zimmer`.

:::caution[Tag naming drifts across the docs and the code]
`docs/PROVISIONING.md` said `tag:zimmer-ci`. `deploy-staging.yml` and the README say `tag:ci`. The
DigitalOcean tags are `zimmer` and `zimmer-<env>`. These are three different naming schemes for
overlapping concepts.

`PROVISIONING.md` also required an `ssh` block in the ACL "so CI can SSH in for an in-place upgrade."
This repo's deploy never SSHes — cloud-init's own comment calls SSH ACLs brittle. That ACL is only
needed by the author's private production auto-upgrade workflow.
:::

## Ephemeral Terraform state

There is no backend block. State lives on the CI runner and evaporates.

The deploy compensates by hand-reaping the droplet and firewall through the DigitalOcean API before
every `apply`. A project is account-unique and would 409 on a re-run, which is why `manage_project`
defaults to `false`. (Terraform no longer manages a DNS record at all — the `domain-cert` workflow owns
the A record now, out of band.)

Terraform can never converge, and `terraform destroy` can never work properly. This is a known,
accepted trade-off for a single-operator staging environment, documented in the README. It would not
survive a second operator.

## Hostname stability

`scripts/tailnet-reap-node.sh` deletes the stale tailnet node so the MagicDNS name doesn't drift to
`zimmer-staging-1`, `-2`, …

:::caution[It silently no-ops when `TS_API_CLIENT_*` are unset]
And then the name *does* drift. The health check compensates by trying **every** online peer named
`zimmer-staging` — which works, but means you can end up with a pile of dead nodes in your tailnet and
no error telling you.
:::

---
title: Provisioning and secrets
description: The Terraform variables, the GitHub Actions secrets, the Tailscale ACLs — and where secrets end up that they shouldn't.
sidebar:
  order: 2
---

## Terraform variables

**Non-secret** (set in `staging.tfvars` / `production.tfvars`):

Terraform only provisions the **host**. The app image, its env, and the data stores are Kamal's
(`config/deploy.*.yml`) — they are no longer Terraform variables at all.

| Variable | Notes |
| --- | --- |
| `environment` | validated `staging` \| `production` |
| `region` / `droplet_size` | default `nyc3` / `s-2vcpu-4gb` |
| `domain` | `""` by default. Set it to turn on [custom-domain HTTPS over the tailnet](/operate/deploying/#custom-domain-https-over-the-tailnet) — cloud-init runs a Caddy terminator on `:443` fronting kamal-proxy. Terraform does not create the DNS record; the `domain-cert` workflow owns the A record. |
| `manage_project` | **`true`** by default now — with remote state, Terraform reconciles the account-unique project name instead of 409ing |
| `ssh_key_fingerprints` | |
| `managed_db_cluster_name` | `""` for staging (Kamal runs a throwaway Postgres accessory); set for production |

**Secrets** (as `TF_VAR_*`):

`do_token` · `tailscale_auth_key` · `deploy_ssh_pubkey` (public half of the Kamal deploy key;
cloud-init authorizes it for root) · optional `ssh_host_ed25519_key` / `_pub` (pins the droplet's SSH
host identity so it survives a rebuild — see [Hostname stability](#hostname-stability)).

A `lifecycle.precondition` on the droplet fails the plan if `deploy_ssh_pubkey` is empty, since Kamal
could not reach the box.

## GitHub Actions secrets

| Secret | Used by |
| --- | --- |
| `DIGITALOCEAN_ACCESS_TOKEN` | `terraform apply` / `destroy` (the DO provider) |
| `SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY` | the Terraform **state backend** on DO Spaces (passed as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) |
| `KAMAL_SSH_KEY` / `KAMAL_SSH_PUBKEY` | Kamal's SSH control channel to the droplet (private half in CI; public half baked into cloud-init) |
| `TAILSCALE_AUTH_KEY` | the droplet's cloud-init `tailscale up` |
| `TS_CI_AUTHKEY` | **CI's own** tailnet join, to resolve the droplet's IP and health-check it |
| `TS_API_CLIENT_ID` / `TS_API_CLIENT_SECRET` | reaping the stale tailnet node |
| `GHCR_PULL_TOKEN` | Kamal's registry login, so the droplet can pull the image |
| `STAGING_SECRET_BASE` | Rails `SECRET_KEY_BASE` for staging (also the throwaway Postgres password) |
| `STAGING_API_KEYS` | REST API bearer keys |
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

## Remote Terraform state (DigitalOcean Spaces)

State lives in a **DigitalOcean Spaces** bucket (`zimmer-tfstate`) via the S3-compatible backend, with
S3-native locking (`use_lockfile`, Terraform ≥ 1.10 — Spaces has no DynamoDB). The backend block in
`main.tf` is deliberately empty; each environment supplies bucket/key/endpoint through
`-backend-config=backend.<env>.hcl`, which is what keeps `main.tf` byte-identical to the production
mirror.

```bash
terraform init -input=false -backend-config=backend.staging.hcl
```

The Spaces access keys are passed as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (the
`SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY` Actions secrets).

This is what lets `apply` **converge**. Previously state evaporated with the CI runner, so the deploy
had to hand-reap the droplet and firewall through the DigitalOcean API before every run, `apply` could
never reconcile, `terraform destroy` never worked properly, and `manage_project` had to default to
`false` because an account-unique project name would 409 on a re-run. All of that is gone:
`manage_project` is now `true`, teardown is a real `terraform destroy`, and there are no reap loops.

## Hostname stability

Because the droplet is now persistent, a rebuild is rare — which is the main reason its identity stops
drifting. Two things pin it when a rebuild does happen:

- **`digitalocean_reserved_ip`** keeps the public IP stable across a `create_before_destroy` rebuild.
- **`ssh_host_ed25519_key`** (optional; empty on staging) pins the SSH **host key**, so a rebuild does
  not invalidate an SSH client's `known_hosts`. Without it, every re-provision rotates the host key and
  breaks anything keyed to it.

`scripts/tailnet-reap-node.sh` deletes the stale tailnet node so the MagicDNS name doesn't drift to
`zimmer-staging-1`, `-2`, …

:::caution[It silently no-ops when `TS_API_CLIENT_*` are unset]
And then the name *does* drift. The health check compensates by trying **every** online peer named
`zimmer-staging` — which works, but means you can end up with a pile of dead nodes in your tailnet and
no error telling you.
:::

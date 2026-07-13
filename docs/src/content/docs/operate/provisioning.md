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
| `manage_project` | still `false`. Remote state fixes the case where Terraform *created* the project, but a **pre-existing** one (both envs have one) still 409s on its account-unique name. Turning it on needs a one-time `terraform import` first; a DO Project is just a console folder, so it isn't worth the failure mode. |
| `admin_ssh_pubkeys` | Operator/tooling public keys cloud-init authorizes for `root`, on top of the Kamal deploy key. Per environment, and the environments are **[deliberately not the same](/operate/ssh-access/#who-is-authorized-where)** — do not reconcile them. `[]` by default: set it in `*.tfvars`, never as a module default, so a fork does not silently authorize someone else's key. It rides cloud-init, so a key added here [reaches only a rebuilt box](/operate/ssh-access/#adding-a-key-does-not-touch-a-running-droplet). |
| `ssh_key_fingerprints` | DigitalOcean-registered keys. **Leave it empty.** It is `ForceNew` on `digitalocean_droplet`, so adding a key makes the deploy workflow's auto-approved `terraform apply` *destroy and recreate the droplet* — skipping the tailnet-node reap that only runs behind `recreate_droplet`, which lands the replacement as `zimmer-<env>-1` and breaks the hostname the deploy resolves. Use `admin_ssh_pubkeys`: it rides cloud-init, which is under `ignore_changes`, so it can never force-replace the box. |
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
| `STAGING_SECRET_BASE` | Rails `SECRET_KEY_BASE` for staging |
| `STAGING_DB_PASSWORD` | the staging Postgres accessory's password — a stable secret, deliberately *not* derived from `SECRET_KEY_BASE` (rotating the latter must stay safe; `POSTGRES_PASSWORD` only takes effect on first initdb) |
| `STAGING_API_KEYS` | REST API bearer keys |
| `STAGING_RAILS_MASTER_KEY` | decrypts the committed `config/credentials/staging.yml.enc` (`mcp_secrets`: `SLACK_BOT_TOKEN`, `ENG_ALERTS_SLACK_CHANNEL_ID`). Optional — without it the deploy still succeeds, but Slack and every credential-bearing MCP server go quiet ([why](/limitations/#rails_master_key-is-optional-on-staging-and-silently-degrades-when-absent)) |
| `STAGING_OTEL_LOGS_EXPORTER_ENDPOINT` / `STAGING_OTEL_LOGS_EXPORTER_BEARER_TOKEN` | ship staging's WARN/ERROR/FATAL logs over OTLP. **Both** are required — either one missing is a silent no-op ([observability](/operate/observability/)) |
| `STAGING_SENTRY_DSN_BACKEND` | staging's GlitchTip DSN. Must be a **staging-only project**, never production's — a DSN selects a project, and GlitchTip's alert rules are per-project with no environment filter |
| `STAGING_OPERATOR_SSH_KEY` | base64 of the operator SSH **private** key — the identity agent sessions SSH with ([below](#the-ssh-identity-an-agent-session-holds)). Optional: without it the app boots fine and only the `ssh-*` MCP servers fail |
| `SLACK_BOT_TOKEN` / `SLACK_ALERTS_CHANNEL_ID` | `alert-ci-failure.yml`, posting main-branch CI failures to #alerts ([below](#slack-ci-failure-alerts)) |

:::caution[`TS_CI_AUTHKEY` must be a pre-minted auth key]
A Tailscale OAuth client cannot mint `tag:ci` keys. `deploy-staging.yml`'s own comment says so.
`docs/DEPLOYING_ON_DIGITALOCEAN.md` told you to use `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET`; that was
wrong and would fail.
:::

## Slack CI failure alerts

[`alert-ci-failure.yml`](/operate/deploying/#ci-failure-alerts) needs a Slack bot token and the ID of
the channel to post into.

The Slack side already exists and does not need rebuilding: the **`github_ci_alerts`** app in the
Tadasant workspace holds the `chat:write` scope and is already a member of **#alerts** (a bot cannot
post to a channel it is not in — that is the usual way this breaks, and it surfaces as
`not_in_channel` in the run log). Its bot token lives in **1Password → Zimmer vault → "GitHub CI
alerts SLACK_BOT_TOKEN (Tadasant)"**.

What each repo needs is the two secrets. `tadasant` is a personal GitHub account, not an org, so
there are **no org-level secrets** — every repo that runs this alerting workflow needs its own
copy, under **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
| --- | --- |
| `SLACK_BOT_TOKEN` | the `xoxb-…` token from 1Password above |
| `SLACK_ALERTS_CHANNEL_ID` | the `C0…` ID of #alerts (click the channel name in Slack; it's at the bottom of the dialog) |

Then smoke-test without breaking anything: **Actions → CI failure alert → Run workflow** on `main`.
It posts a smoke-test message to #alerts instead of a real alert. If the job goes red, the error
annotation names the exact cause (`not_in_channel`, `invalid_auth`, `missing_scope`, …) and what to
do about it.

## SSH is tailnet-only

`digitalocean_firewall.zimmer` opens **no public TCP port at all** — the single inbound rule is
Tailscale's `41641/udp`. On the tailnet interface, SSH is two different servers: `:22` is **Tailscale
SSH** (tailnet identity, ignores publickey, and the channel Kamal deploys over), and `:2222` is **real
OpenSSH** for publickey clients (`admin_ssh_pubkeys` plus the Kamal key).

That split, how to connect through it, how to authorize an operator key on a box you cannot rebuild,
and the traps between you and a shell — socket-activated sshd, first-match-wins `sshd_config.d`,
DigitalOcean's force-expired root password — have a page of their own:
**[SSH and tailnet access](/operate/ssh-access/)**.

## The SSH identity an agent session holds

An agent session runs as a child process of the worker container, so it inherits that container's
`$HOME` (`/home/rails`). The image ships no SSH key, and none of the durable volumes cover `~/.ssh` —
so out of the box a session has **no SSH identity at all**, and every `ssh-*` MCP server dies on its
startup health check with `All configured authentication methods failed`. That reads like the host
rejected the key; there was no key.

One ed25519 keypair (comment `zimmer-production-operator`) fixes that, and it travels in two halves:

| Half | Where it lives | How it gets there |
| --- | --- | --- |
| private | the `ZIMMER_OPERATOR_SSH_KEY` env var, **base64-encoded** | a GitHub Actions secret (`STAGING_OPERATOR_SSH_KEY`; `PROD_OPERATOR_SSH_KEY` in the [private repo](/operate/companion-repo/)) → Kamal `env.secret` → `OperatorSshKeyProvisioner` decodes it to `~/.ssh/zimmer_operator_ed25519` (`0600`) at boot and at every spawn |
| public | `admin_ssh_pubkeys` in `*.tfvars` | cloud-init → `/root/.ssh/authorized_keys`, reachable only over the tailnet on `:2222` |

Four details are load-bearing:

- **Base64, not the PEM.** Kamal hands env vars to Docker through an env-file, and a Docker env-file
  cannot carry a newline. A raw PEM arrives truncated at its first line break.
- **Zimmer's own filename, not `id_ed25519`.** Every consumer is handed an explicit path, so nothing
  needs the conventional name — and writing it would clobber the personal key of a developer or
  self-hoster who sets the variable and runs `bin/rails console`. An agent that wants the plain CLI
  runs `ssh -i "$SSH_PRIVATE_KEY_PATH"` (and, since nothing seeds `known_hosts`, an explicit
  `-o StrictHostKeyChecking=accept-new`).
- **The key has to be a *path*.** `ssh-agent-mcp-server` is an ssh2 publickey client: it reads
  `SSH_AUTH_SOCK` first and `SSH_PRIVATE_KEY_PATH` second, and nothing else — it does not go looking
  in `~/.ssh`. There is no ssh-agent in the container, so `CliSpawnEnv` exports
  `SSH_PRIVATE_KEY_PATH` into the [spawn environment](/sessions/spawning/#the-spawn-environment).
- **The two runtimes reach the MCP server differently.** Claude Code hands a stdio MCP server its own
  environment, so the spawn env is enough. Codex does not: it builds each server's environment from a
  fixed whitelist plus exactly the vars the entry names in `env_vars`. So
  `CodexConfigTomlPostProcessor` adds `SSH_PRIVATE_KEY_PATH` to every stdio server's `env_vars` in
  `.codex/config.toml`. Miss that and the fix works for Claude sessions and silently does not for
  Codex ones.

The key material itself is deliberately **not** a `mcp_secret`:
`AgentSessionJob#inject_secrets_to_env_file` writes every `mcp_secret` in plaintext into the session
clone's `.env`, inside the git tree the agent operates on. `CliSpawnEnv` also unsets
`ZIMMER_OPERATOR_SSH_KEY` for the agent process — a session needs the key's path, never its bytes.

Nothing is fatal when the key is absent: the app boots, and only SSH-based MCP servers fail. The
staging deploy prints whether the secret is set for exactly that reason.

:::caution[Authorizing the public half only takes effect on a rebuild]
`admin_ssh_pubkeys` rides `user_data`, and the droplet's `lifecycle` block **ignores changes to
`user_data`** — deliberately, so a normal deploy can never force-replace the box. Adding a key
therefore produces no plan diff, and a running droplet never authorizes it: cloud-init only runs at
creation ([admin keys are add-only](/limitations/#admin-keys-are-add-only)).

To authorize the key on a **live** host, either `recreate_droplet: true` (destructive — fine for
staging, not for production), or append the public key to `/root/.ssh/authorized_keys` by hand over
Tailscale SSH. Terraform is what makes it survive the *next* rebuild; the manual append is what makes
it work *now*.
:::

:::caution[This key is root on every host that authorizes it — and production deliberately does not]
`admin_ssh_pubkeys` authorizes `root`; there is no unprivileged SSH user. So the only thing bounding
what a session can reach is **which hosts authorize the key**, and production is left out on purpose:
a session runs *on* production, and a session holding root on its own host can take the orchestrator
down with itself still inside it. Staging, the observability box, and the CI runner do authorize it —
that is the fleet these sessions exist to operate.

The full table, and the second layer that keeps a production session from even *attaching* an SSH MCP
server aimed at its own host, are in [who is authorized
where](/operate/ssh-access/#who-is-authorized-where). Do not reconcile the lists so they match.

Being a **separate identity** from the Kamal deploy key is what makes any of this revocable: dropping
one line from a key list has no effect on deploys ([admin keys are
add-only](/limitations/#admin-keys-are-add-only), so a live box also needs the line removed from
`/root/.ssh/authorized_keys`).
:::

## Where secrets end up that they shouldn't

:::caution[The Tailscale auth key is in the droplet's `user_data`]
The app secrets — `SECRET_KEY_BASE`, the database password, the GHCR token — now flow through Kamal's
`env.secret` from GitHub Actions, **not** through cloud-init. What cloud-init still interpolates into
`user_data` is the `tailscale_auth_key` (plus the deploy public key and, optionally, the SSH host
key).

`user_data` is readable from the DigitalOcean metadata service by anything on the box, including every
agent process Zimmer spawns. An ephemeral, reusable tailnet auth key limits the blast radius, but a
long-lived one there is worth avoiding.
:::

:::danger[Nothing is encrypted at rest in the database]
No model declares `encrypts`; there is no `active_record.encryption` config. Anthropic and OpenAI
refresh tokens, MCP OAuth access and refresh tokens, client secrets, and PKCE verifiers are all
plaintext columns — and the [unauthenticated `/supervisor` panel](/auth/overview/) renders them.
([#43](https://github.com/tadasant/zimmer/issues/43))
:::

## App env vars

`API_KEYS` and `APP_HOST` are set by Kamal (`config/deploy.staging.yml`), so the REST API works and
MCP OAuth callbacks resolve to the real host. `RAILS_MASTER_KEY` is set too, from the
`STAGING_RAILS_MASTER_KEY` secret — it decrypts the committed `config/credentials/staging.yml.enc`,
which is what makes `mcp_secrets` (and therefore Slack) work on staging. It stays
[optional, and degrades silently when absent](/limitations/#rails_master_key-is-optional-on-staging-and-silently-degrades-when-absent).

The staging database is a Postgres accessory container Kamal runs on the droplet — nothing external
to provision. A self-hosted production deployment supplies its own database (Terraform can reference
an existing cluster as a read-only data source rather than creating it); that lives in your own
private infrastructure, out of scope for these docs.

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
teardown is a real `terraform destroy`, and there are no reap loops. (`manage_project` stays `false`:
a pre-existing DO project 409s on its account-unique name, and importing one is not worth it.)

## Hostname stability

Because the droplet is now persistent, a rebuild is rare — which is the main reason its identity stops
drifting. Two things pin it when a rebuild does happen:

- **`digitalocean_reserved_ip`** is a separate resource, so the public IP survives a droplet rebuild
  (the droplet itself is deliberately *not* `create_before_destroy` — the tailnet hostname is fixed).
- **`ssh_host_ed25519_key`** (optional; empty on staging) pins the SSH **host key**, so a rebuild does
  not invalidate an SSH client's `known_hosts`. Without it, every re-provision rotates the host key and
  breaks anything keyed to it.

`scripts/tailnet-reap-node.sh` deletes the stale tailnet node so the MagicDNS name doesn't drift to
`zimmer-staging-1`, `-2`, …

:::caution[It silently no-ops when `TS_API_CLIENT_*` are unset]
And then the name *does* drift. The health check compensates by trying **every** online peer named
`zimmer-staging` — which works, but means you can end up with a pile of dead nodes in your tailnet and
no error telling you. ([#123](https://github.com/tadasant/zimmer/issues/123))
:::

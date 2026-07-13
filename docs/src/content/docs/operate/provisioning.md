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
| `admin_ssh_pubkeys` | Operator/tooling public keys cloud-init authorizes for `root`, on top of the Kamal deploy key. The **one** mechanism both environments use, so staging and production cannot drift on who can get in. `[]` by default — set it per environment in `*.tfvars`, never as a module default, so a fork does not silently authorize someone else's key. |
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
| `OTEL_LOGS_EXPORTER_ENDPOINT` / `_BEARER_TOKEN`, `SENTRY_DSN_BACKEND` | optional observability |
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
there are **no org-level secrets** — `zimmer`, `tadasant-internal` and `strad` each need their own
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
Tailscale's `41641/udp`. There is no `22` rule, and adding one back is the thing not to do. On the
tailnet interface, SSH is two different servers:

| Port | Server | Authenticates by | Used by |
| --- | --- | --- | --- |
| `:22` | **Tailscale SSH** (`tailscale up --ssh`) | tailnet identity — it ignores publickey entirely | Kamal's deploys, and `tailscale ssh root@zimmer-<env>` for break-glass |
| `:2222` | **real OpenSSH** (an `ssh.socket` drop-in) | publickey (`admin_ssh_pubkeys` + the Kamal key) | plain publickey clients that cannot speak Tailscale SSH — e.g. the `ssh-agent-mcp-server` MCP |

A DigitalOcean cloud firewall filters the **public** interface only; it does not filter `tailscale0`.
So tailnet peers reach both ports and the internet reaches neither, with no firewall rule for either.

Only the firewall enforces that, though — `:2222` binds `0.0.0.0`, so it is the *absence of any TCP
inbound rule* that keeps the internet out, not the bind. Detach `digitalocean_firewall.zimmer` from the
droplet and `:2222` is world-reachable immediately, with no rule in Terraform to grep for. (It is
key-only sshd, so the exposure is bounded — but the firewall is the control.)

:::caution[Three gotchas that will waste your afternoon]
Ubuntu 24.04 **socket-activates** sshd, so the listen set belongs to `ssh.socket`, not `sshd_config`:

- **Do not use `Port 2222`.** It is not ignored — `openssh-server` ships an `sshd-socket-generator`
  that turns a `Port`/`ListenAddress` line into a generated `ssh.socket` drop-in which **resets**
  `ListenStream=`. So `Port 2222` would *move* sshd off `:22` instead of adding `:2222`. A drop-in
  appends; that is why we use one.
- **The drop-in filename must sort late** (`zz-tailnet-altport.conf`). systemd applies drop-ins in
  filename order, and that generated `addresses.conf` starts with a bare `ListenStream=` reset — a
  `10-` prefix would be silently wiped the moment anyone adds a `Port` line.
- **List both address families.** The shipped `ssh.socket` sets `BindIPv6Only=ipv6-only` (the unit —
  *not* the `net.ipv6.bindv6only` sysctl, which is `0`), so a bare `ListenStream=2222` binds IPv6 only
  and every IPv4 client gets `Connection refused`.
:::

sshd itself is key-only (`10-hardening.conf`: `PasswordAuthentication no`, `PermitRootLogin
prohibit-password`). Two things about that file are load-bearing: its name sorts before
`50-cloud-init.conf` (sshd takes the **first** match), and **`ssh.service` must be restarted** for it
to take effect — `Accept=no` means one long-lived `sshd -D` parses the config once at start, not per
connection. See
[`sshd -T` is the only honest way to read sshd's config](/limitations/#sshd--t-is-the-only-honest-way-to-read-sshds-config).

This posture replaced a genuinely dangerous one: `22/tcp` open to `0.0.0.0/0` against an sshd that
accepted **root password auth**, with both droplets under a sustained brute-force flood — staging's
sshd pre-auth queue was saturated to the point that SSH was effectively down. Because
`terraform apply` runs on **every** deploy, the firewall rule in code is what keeps it shut: a
hand-fix through the DigitalOcean API is reverted by the next deploy, which is exactly what happened.

### DigitalOcean force-expires root's password, and that rejects every OpenSSH session

Create a droplet with **no DO-registered SSH key** — which is exactly what `ssh_key_fingerprints = []`
does — and DigitalOcean sets a random root password, emails it out, and marks it as needing an
immediate change (`chage -d 0 root`, i.e. `lastchg=0` in `/etc/shadow`).

That flag is not cosmetic. `pam_unix`'s **account** stack refuses a session outright when
`lastchg == 0`, *after* publickey auth has already succeeded:

```console
$ ssh -p 2222 -i ~/.ssh/id_ed25519 root@zimmer-staging 'hostname'
You are required to change your password immediately (administrator enforced).
Password change required but no TTY available.
```

So `:2222` authenticates you and then throws the session away — the publickey path is unusable, and
the `ssh-agent-mcp-server` MCP fails its healthcheck. Tailscale SSH on `:22` never notices, because it
authenticates by tailnet identity and does not run `pam_unix` at all: Kamal deploys, CI health checks,
and every `tailscale ssh` break-glass keep working on a box whose OpenSSH is entirely dead. It is a
failure only a *real* OpenSSH client can see.

cloud-init therefore drops the password before `ssh.socket` comes up:

```yaml
- usermod -p '*' root
- chage -d $(date +%Y-%m-%d) -M -1 root
```

Root is key-only here, so the password has no legitimate use — removing it also invalidates the one
DigitalOcean emailed. `usermod -p '*'` sets an **invalid** hash; `passwd -d` would leave an *empty*
one, which means "no password required" rather than "no password login". `-M -1` disables aging, so it
cannot re-expire.

:::caution[cloud-init only runs at creation — live boxes need the converge]
A droplet that already exists keeps `lastchg=0` forever; nothing re-runs `runcmd`. That is why
`scripts/clear-root-password-expiry.sh` exists and why the staging deploy runs it on **every** deploy
(idempotent, and it connects over Tailscale SSH on `:22` — the one path the expiry does not block).
Production is repaired on its next rebuild, or by pointing the same script at it. Production's OpenSSH
works today only by accident: its root password happened to be changed at some point, which reset
`lastchg`.
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

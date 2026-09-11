# Zimmer infrastructure (Terraform / DigitalOcean)

Terraform provisions one droplet as a **Kamal-ready host** — Docker, a Tailscale
join (the app is reachable **only over the VPN**), the TLS/proxy prep, and the
authorized SSH keys — plus a reserved IP and the firewall (no public app ingress).
It creates **no** DNS record: a separate `domain-cert` CI workflow upserts the
Cloudflare record. It does **not** run the app either: [Kamal](https://kamal-deploy.org/) owns the
app stack (a `web` role and a `worker` role, with Redis — and, on staging, a
throwaway Postgres — as accessories). Production points Kamal at a DigitalOcean
Managed Postgres cluster instead, so the database survives a droplet rebuild.

The same module serves staging and production — the only difference is the
`.tfvars`, the backend config, and the secret values.

## Files

- `main.tf` — provider, `terraform`/`backend "s3"` block, variables, droplet,
  reserved IP, firewall (no public app ingress), outputs (incl. the managed-DB
  connection details the production Kamal deploy consumes). No DNS resource — the
  `domain-cert` CI workflow owns the Cloudflare record.
- `cloud-init.yaml.tftpl` — droplet bootstrap for a **Kamal-ready** host: installs
  Docker, joins Tailscale, runs **Caddy** as the TLS-terminating edge proxy
  (fronting kamal-proxy on `:8080`) and — only when a domain is set — bootstraps a
  self-signed cert for it, and authorizes the Kamal deploy key + admin/tooling keys
  for root, and — only when `node_exporter_enabled` is set — a tailnet-bound
  `node_exporter`. It deliberately does **not** pull the image or start the app (nor
  kamal-proxy) — Kamal does that over its SSH control channel after Terraform
  finishes.
- `backend.staging.hcl` — partial S3-backend config (bucket/key/endpoint) for
  staging's remote state on DigitalOcean Spaces; passed at `terraform init` with
  `-backend-config`. Production uses a mirrored copy.
- `staging.tfvars.example` — non-secret staging config to copy to `staging.tfvars`.
  (Production values live in your private ops repo.)
- `data-stores/README.md` — the one-time `doctl` runbook for the production
  Managed Postgres cluster (see "Managed database" below).

## Secrets — never commit these

### Terraform variables (`TF_VAR_*`)

Passed as environment variables — GitHub Actions secrets in CI, your shell locally.
Only these are Terraform's:

| Variable | Purpose |
|----------|---------|
| `TF_VAR_do_token` | DigitalOcean API token |
| `TF_VAR_tailscale_auth_key` | Ephemeral, pre-authorized Tailscale auth key |
| `TF_VAR_deploy_ssh_pubkey` | Public half of the Kamal deploy keypair, authorized for root by cloud-init |
| `TF_VAR_ssh_host_ed25519_key` | Optional pinned SSH host **private** key (stable host identity across rebuilds); its public half is `TF_VAR_ssh_host_ed25519_key_pub` |

`admin_ssh_pubkeys` (break-glass operator keys) holds public keys, not secrets —
but it is still **not** in the committed `staging.tfvars.example`, because that
file is copied verbatim by the deploy and this repo is public, so a key in it
would be authorized for root on every fork's droplet. CI supplies it as
`TF_VAR_admin_ssh_pubkeys` from the `ADMIN_SSH_PUBKEYS` Actions *variable*
(a JSON list of strings); unset falls through to the `[]` default. Locally,
export the same `TF_VAR_`.

### Backend (Spaces) credentials — passed at `init`, not as `TF_VAR_*`

The S3 backend authenticates to DigitalOcean Spaces with `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` env vars at `terraform init` time.

### NOT Terraform's — the app and database secrets are Kamal's

`SECRET_KEY_BASE`, the GHCR pull token, the database password, and
`RAILS_MASTER_KEY` are **Kamal** secrets (`.kamal/secrets.{staging,production}`,
wired from GitHub Actions secrets by `deploy-staging.yml`), delivered to the app
container at deploy time. They are not Terraform variables and do not appear in
`main.tf`.

## Usage

```bash
cd infra/terraform
cp staging.tfvars.example staging.tfvars   # edit non-secret values

export TF_VAR_do_token=...  TF_VAR_tailscale_auth_key=...  TF_VAR_deploy_ssh_pubkey=...
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...     # Spaces keys, for the backend
export TF_VAR_admin_ssh_pubkeys='["ssh-ed25519 AAAA... you@laptop"]'  # optional; [] otherwise

terraform init -backend-config=backend.staging.hcl
terraform apply -var-file=staging.tfvars
```

Remote state lives on DigitalOcean Spaces (S3-compatible). The `backend "s3" {}`
block is already in `main.tf`; it is intentionally *empty* there and filled in
per-environment via `-backend-config` (`backend.staging.hcl`, and a mirrored
production copy) so the same code reconciles the long-lived staging and production
droplets instead of colliding on account-unique names.

## Managed database (production)

Production sets `managed_db_cluster_name` to an **existing** DigitalOcean Managed
Postgres cluster, which `main.tf` reads as a **data source** (never a managed
resource — Terraform has no destroy path to the one irreplaceable thing in the
system). The cluster and its `zimmer_production` / `zimmer_production_cable`
databases are created once by hand per `data-stores/README.md`; its connection
details are surfaced as outputs for the production Kamal deploy to wire into
`DATABASE_HOST`. Staging leaves `managed_db_cluster_name` empty and runs a
throwaway Postgres accessory on the droplet.

## Applied by CI, not by hand

The **Deploy staging** workflow (`.github/workflows/deploy-staging.yml`) runs
`terraform init -backend-config=backend.staging.hcl` + `terraform apply`, then
joins the tailnet and runs a Kamal deploy to ship the app image. Staging is never
auto-deployed — it is `workflow_dispatch` only. Pass `recreate_droplet: true` to
force a droplet rebuild (needed only for the cloud-init-delivered changes that
`ignore_changes = [user_data]` otherwise pins — see
[Known limitations](../../docs/src/content/docs/limitations.md)).

## Host metrics

Two independent sources, both off-by-default-safe and both **create-time only**.

### DigitalOcean's metrics agent (`monitoring`, default `true`)

The droplet sets `monitoring = var.monitoring`, which defaults to `true`, so
DigitalOcean's (free) metrics agent is installed on every box this module creates —
host CPU, memory, disk and load history, and the only metrics DO's own resource alert
policies can evaluate. It is a variable rather than a hardcode so a downstream copy of
this module can decline it without forking the file.

It is create-time only. `monitoring` is `ForceNew` in the provider and DigitalOcean
has no droplet action to enable it, so it is also under `ignore_changes`: without
that, an apply against an existing droplet would **destroy and recreate** it, and
both environments apply with `-auto-approve`. The trade-off is that an
already-running droplet gets the agent only when it is rebuilt — DO's own remedy
is a root shell running their install script, which this deployment has no clean
path to. See [Known limitations](../../docs/src/content/docs/limitations.md) and
[zimmer#651](https://github.com/tadasant/zimmer/issues/651).

### `node_exporter` (`node_exporter_enabled`, default `false`)

Opt-in. When true, cloud-init installs a **pinned**, checksum-verified Prometheus
[`node_exporter`](https://github.com/prometheus/node_exporter) as a systemd unit and
serves `/metrics` on the droplet's **tailnet address only**, port `9100` — the
conventional `node_*` metric names, for a deployment that scrapes host telemetry into
its own monitoring plane. (Deliberately not the OpenTelemetry Collector's `hostmetrics`
receiver, which emits `system.cpu.*`-style names and would mean rewriting every
dashboard and alert rule written against the standard Prometheus host metrics.)

- **No firewall rule, and none is wanted.** The bind is the droplet's single 100.x
  address, never `0.0.0.0`, so `:9100` is reachable from tailnet peers and nowhere
  else. This module's firewall still admits exactly one inbound rule (UDP 41641).
  **The scraper must be on the tailnet.**
- **It takes effect on the next droplet creation, not on a running box.** It is
  delivered through cloud-init, and `user_data` is under `ignore_changes` — so
  flipping this to `true` produces *no plan diff* and nothing reaches a live droplet.
  A rebuild (`recreate_droplet: true`, or `terraform taint
  digitalocean_droplet.zimmer`) is what applies it; installing it on an existing
  droplet is a by-hand step over Tailscale SSH.
- **The version is pinned** in `cloud-init.yaml.tftpl`, with its SHA-256 checked
  before install. node_exporter reshapes collectors between minor releases, which
  moves metric cardinality under whatever is scraping it. Bump the version and the
  checksum together.

`terraform plan` is not how you check this one. Render the template instead:
`templatefile("cloud-init.yaml.tftpl", { ... node_exporter_enabled = true })`, or run
`bin/rails test test/infra/`, which parses the rendered cloud-config both ways.

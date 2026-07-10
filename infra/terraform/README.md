# Zimmer infrastructure (Terraform / DigitalOcean)

One droplet running the Zimmer stack (app + Redis via docker compose; staging also
runs a throwaway Postgres container, production uses Managed Postgres),
joined to a Tailscale tailnet so the app is reachable **only over the VPN**. The
same module serves staging and production — the only difference is the `.tfvars`
and the secret values.

## Files

- `main.tf` — provider, variables, droplet, firewall (no public app ingress),
  optional DNS record, outputs.
- `cloud-init.yaml.tftpl` — droplet bootstrap: Docker, Tailscale join, GHCR login,
  `docker compose up`.
- `staging.tfvars.example` — non-secret staging config to copy to `staging.tfvars`.
  (Production values live in the private `tadasant-internal` repo.)

## Secrets — never commit these

Pass as `TF_VAR_*` environment variables (GitHub Actions secrets in CI):

| Variable | Purpose |
|----------|---------|
| `TF_VAR_do_token` | DigitalOcean API token |
| `TF_VAR_tailscale_auth_key` | Ephemeral, pre-authorized Tailscale auth key |
| `TF_VAR_ghcr_token` | GHCR `read:packages` token to pull the (private) image |
| `TF_VAR_secret_key_base` | Rails `SECRET_KEY_BASE` (also the DB password for the *staging* compose Postgres) |
| `TF_VAR_managed_db_password` | Password for `managed_db_username` on the managed cluster. Required when `managed_db_cluster_name` is set (production); unused otherwise |

## Usage

```bash
cd infra/terraform
cp staging.tfvars.example staging.tfvars   # edit non-secret values
export TF_VAR_do_token=...  TF_VAR_tailscale_auth_key=...  \
       TF_VAR_ghcr_token=...  TF_VAR_secret_key_base=$(openssl rand -hex 64)
terraform init
terraform apply -var-file=staging.tfvars
```

Configure a **remote backend** (e.g. DO Spaces via the S3 backend) so CI and you
share state. This is intentionally left out of `main.tf` so the template is
portable; add a `backend "s3" { ... }` block per environment.

## Applied by CI, not by hand

The **Deploy staging** workflow (`.github/workflows/deploy-staging.yml`) runs
`terraform apply` and then joins the tailnet to redeploy the app image. Staging is
never auto-deployed — it is `workflow_dispatch` only.

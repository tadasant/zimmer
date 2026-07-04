# Deploying Zimmer on a personal DigitalOcean box

This guide stands up a single-droplet Zimmer instance on DigitalOcean, reachable
only over a Tailscale VPN. The infrastructure is defined in Terraform
([`infra/terraform`](../infra/terraform)) and applied by CI — you should not click
around the DO console by hand.

The staging environment (`staging.zimmer.tadasant.com`) is defined in this repo.
A production environment is a *sync* of the same Terraform with production
variables, kept in the private `zimmer-internal` repo — see
[Production](#production-zimmer-internal).

## Prerequisites (one-time manual setup)

These require credentials/consoles that automation cannot mint for you:

1. **DigitalOcean API token** — create at DO → API → Tokens (read+write). Store as
   the GitHub Actions secret `DIGITALOCEAN_ACCESS_TOKEN`. Never commit it.
2. **Tailscale** — a tailnet, plus:
   - an **ephemeral, pre-authorized auth key** → GH secret `TAILSCALE_AUTH_KEY`
     (used by the droplet to join);
   - a **Tailscale OAuth client** (`TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET`) so CI
     can join the tailnet;
   - a **tailnet ACL** that restricts who can reach `tag:zimmer` nodes to
     `tag:ci` and your personal devices. There is no MCP/automation for Tailscale;
     do this in the Tailscale admin console.
3. **GHCR pull token** — a PAT with `read:packages` (while the `zimmer` image
   package is private) → GH secret `GHCR_PULL_TOKEN`. Once the package is public
   this is unnecessary.
4. **DNS** — `staging.zimmer.tadasant.com` must be in DO DNS (the Terraform can
   create the A record if `domain` is set and the zone is on DO).
5. **SECRET_KEY_BASE** — `openssl rand -hex 64` → GH secret
   `STAGING_SECRET_KEY_BASE`.
6. **Base + app images** — run the **Build base image** workflow once
   (`ghcr.io/tadasant/zimmer-base`), then let **Release image** publish
   `ghcr.io/tadasant/zimmer` on pushes to `main`.

## Deploy staging

Trigger the **Deploy staging** workflow (`workflow_dispatch`), optionally choosing
a branch and image tag. It:

1. joins the tailnet (ephemeral),
2. `terraform apply`s `infra/terraform` with staging variables,
3. redeploys the app image over the tailnet,
4. health-checks `GET /up`.

Staging never auto-deploys — it only runs when you trigger it.

## Deploying with a coding agent

You can hand this whole guide to a coding agent (e.g. an Zimmer session itself):

1. Point the agent at this file and `infra/terraform`.
2. Ensure the secrets above exist as GitHub Actions secrets (the agent cannot mint
   them — it will tell you which are missing).
3. Ask it to trigger the **Deploy staging** workflow and report the run URL +
   health-check result.

The agent's job is deterministic: it runs the workflow and verifies `/up`; it does
not improvise infrastructure, because the infra is fully in Terraform.

## Production (`zimmer-internal`)

Production is the same Terraform with production `.tfvars`, kept private in
`zimmer-internal`, plus a workflow that **auto-upgrades prod to the newest
`ghcr.io/tadasant/zimmer` image** whenever a commit lands on this repo's `main`.
The flow is: change → tested in this repo's staging → synced to `zimmer-internal`
→ prod tracks the latest image automatically. See the `zimmer-internal` repo's
README and its deploy PR for the concrete instantiation of this guide.

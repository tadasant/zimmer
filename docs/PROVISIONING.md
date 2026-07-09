# Manual provisioning walkthrough

Everything here is a **manual, credential-bearing step** that automation cannot
perform for you. It is split by what each step unblocks:

- **Phase 0** — enable branch protection (repo settings)
- **Phase 1** — merge the PRs (mostly automated; nothing to provision)
- **Phase 2** — deploy **staging**
- **Phase 3** — deploy **production** (in the `tadasant-internal` repo)

You do **not** need Phase 2/3 secrets to merge the code PRs — they are only for
actually deploying.

## Phase 0 — branch protection

Branch-protection rulesets require **GitHub Pro** on private repos (the API
returns `403: Upgrade to GitHub Pro or make this repository public`). Options:

- Upgrade the account to Pro, **or**
- Make `zimmer` public (also enables rulesets for free; `tadasant-internal` stays
  private and needs Pro to protect).

The ruleset JSON is committed at `.github/rulesets/main.json`. Once eligible:

```bash
gh api -X POST repos/tadasant/zimmer/rulesets --input .github/rulesets/main.json
```

## Phase 2 — deploy staging (`zimmer` repo → Settings → Secrets → Actions)

### DigitalOcean API token — `DIGITALOCEAN_ACCESS_TOKEN`

**Why:** Terraform + the deploy workflow authenticate to the DO API to create and
manage the droplet, firewall, project, and DNS. CI runs `terraform apply`
non-interactively, so it needs the token as a secret. (An MCP server can't be used
from GitHub Actions, and can't mint API tokens.)

- DO console → **API → Tokens → Generate New Token** (read + write).
- Store as GitHub secret `DIGITALOCEAN_ACCESS_TOKEN`. Never commit it.

### Tailscale

Tags: the droplet is tagged **`tag:zimmer-staging`** and the CI runner
**`tag:zimmer-ci`** (production uses `tag:zimmer-production`). Three pieces:

1. **Droplet auth key** (the droplet joins the tailnet at boot):
   - Tailscale admin → **Settings → Keys → Generate auth key**
   - Check **Reusable**, **Ephemeral**, **Pre-approved**, tag **`tag:zimmer-staging`**
   - → GitHub secret `TAILSCALE_AUTH_KEY`
2. **CI runner auth key** (the GitHub runner joins the tailnet for the health check
   + in-place upgrade):
   - Generate another **Reusable + Ephemeral + Pre-approved** auth key, tag
     **`tag:zimmer-ci`** — a *pre-minted key*, because an OAuth client cannot mint
     tagged keys for tags it doesn't own.
   - → GitHub secret `TS_CI_AUTHKEY`
3. **API OAuth client** (keeps the MagicDNS name stable + powers nightly teardown):
   - Tailscale admin → **Settings → OAuth clients → Generate**, scope **`devices`**
     (read + write).
   - → GitHub secrets `TS_API_CLIENT_ID`, `TS_API_CLIENT_SECRET`
   - Used by `scripts/tailnet-reap-node.sh` to delete a destroyed droplet's stale
     tailnet node so the next deploy reclaims the clean `zimmer-staging` name.
     **Optional** — deploys still work without it, the name just drifts to
     `zimmer-staging-1`, `-2`, …
4. **Tailnet ACL** (admin → **Access Controls**) — declare the tags and (for the
   in-place upgrade) allow the CI runner to SSH into the boxes as root:

   ```jsonc
   {
     "tagOwners": {
       "tag:zimmer-ci":         ["autogroup:admin"],
       "tag:zimmer-staging":    ["autogroup:admin"],
       "tag:zimmer-production": ["autogroup:admin"]
     },
     "ssh": [
       { "action": "accept", "src": ["tag:zimmer-ci"], "dst": ["tag:zimmer-staging"],    "users": ["root"] },
       { "action": "accept", "src": ["tag:zimmer-ci"], "dst": ["tag:zimmer-production"], "users": ["root"] }
     ]
   }
   ```

   (Grants default to allow-all on a fresh tailnet, so no explicit `grants`/`acls`
   entry is needed for reachability; the `ssh` block is what the auto-upgrade needs.)
   There is no MCP for Tailscale config from CI — do this in the admin console.

### GHCR pull token — `GHCR_PULL_TOKEN`

**Why:** while the `ghcr.io/tadasant/zimmer` package is private, the droplet (and
`tadasant-internal`) must authenticate to pull it.

- GitHub → **Settings → Developer settings → PATs** → token with `read:packages`.
- → GitHub secret `GHCR_PULL_TOKEN`. Unnecessary once the package is public.

### Rails secret — `STAGING_SECRET_BASE`

- `openssl rand -hex 64` → GitHub secret `STAGING_SECRET_BASE` (also used as the
  Postgres password).

### One-time bootstrap

- Run the **Build base image** workflow once (publishes `ghcr.io/tadasant/zimmer-base`).
- Let a push to `main` publish the app image, then trigger **Deploy staging**.

## Staging lifecycle & billing

Staging is **destroy-on-demand**, not always-on. `Teardown staging` runs nightly
(08:00 UTC) and **destroys** the droplet + firewall; `Deploy staging` recreates it
when you need it. This matters because **a powered-off DigitalOcean droplet is still
billed** — its disk/CPU/RAM/IP stay reserved — so only destroying it stops the
charge.

**Sizing.** Staging is `s-2vcpu-4gb` ($24/mo if left up; ~$0.036/hr while testing),
sized for the **1–2 concurrent agent sessions** staging ever sees. Production is
deliberately larger (see `tadasant-internal`), since it runs many concurrent
sessions. These sizes are **estimates, not benchmarks** — each concurrent Claude Code
session is roughly a Node process plus its MCP subprocesses on top of Rails +
Postgres + Redis. If you see OOM kills, bump `droplet_size` in the tfvars and
re-provision.

## DNS — stable MagicDNS, no public DNS

Because the box is **Tailscale-only**, you reach it by its MagicDNS name over the
VPN — **public DNS is not required**:

| Environment | URL |
|---|---|
| staging | **`http://zimmer-staging`** |
| production | **`http://zimmer`** |

(Production drops the suffix — see the `tailnet_hostname` local in `main.tf`. The
DigitalOcean droplet name and the tailnet ACL tag both stay `zimmer-<environment>`.)
The fully-qualified `http://<name>.<tailnet>.ts.net` also works. With the
`TS_API_CLIENT_*` OAuth client set,
the name is **stable across redeploys** (the deploy deletes the destroyed droplet's
stale tailnet node first). Without it, each redeploy drifts the name to
`zimmer-staging-1`, `-2`, … A public `staging.zimmer.tadasant.com` A record would
point at a public IP where the app port is firewalled off, so it's only a vanity
pointer.

If you do want vanity URLs: **use Cloudflare, not Namecheap.**

- **Namecheap's API is a poor fit for automation:** it requires 20+ domains, OR
  $50+ account balance, OR $50+ spent in the last 2 years, **and** IP-whitelisting
  (IPv4 only). GitHub Actions runners have dynamic IPs, so you'd need a static-egress
  proxy just to call it.
- **Cloudflare** has a free first-class API, no IP-whitelist, and an official
  Terraform provider (`cloudflare/cloudflare`). Migrate the `tadasant.com` zone (or
  delegate `zimmer.tadasant.com`) to Cloudflare, then the IaC can manage records and
  you'd add `CLOUDFLARE_API_TOKEN` as a secret.

## Phase 3 — deploy production (`tadasant-internal` repo secrets)

Same idea as staging, production values. See `tadasant-internal`'s
`zimmer/DEPLOY.md` for the authoritative list; in brief:
`DIGITALOCEAN_ACCESS_TOKEN`, `TAILSCALE_AUTH_KEY` (tag `tag:zimmer-production`),
`TS_CI_AUTHKEY` (tag `tag:zimmer-ci`), `TS_API_CLIENT_ID` / `TS_API_CLIENT_SECRET`
(stable DNS), the GHCR pull token, the sync token, and `PROD_SECRET_KEY_BASE`. Plus:

- To make prod auto-upgrade the instant a new image publishes (not just the 30-min
  poll), the `zimmer` release workflow fires a `repository_dispatch` using a PAT
  stored as a `zimmer` secret (`GH_TADASANT_INTERNAL_DISPATCH_TOKEN`) with
  `contents:write` on `tadasant-internal`.
- Ensure the Tailscale ACL allows `tag:zimmer-ci` to SSH into `tag:zimmer-production`
  (the `ssh` block above).

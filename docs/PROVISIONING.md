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

Three pieces:

1. **Auth key** (the droplet joins the tailnet):
   - Tailscale admin → **Settings → Keys → Generate auth key**
   - Check **Reusable**, **Ephemeral**, tag **`tag:zimmer`**
   - → GitHub secret `TAILSCALE_AUTH_KEY`
2. **OAuth client** (CI joins the tailnet to reach the box):
   - Tailscale admin → **Settings → OAuth clients → Generate**
   - Scope **`auth_keys`** (write), tag **`tag:ci`**
   - → GitHub secrets `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`
3. **Tailnet ACL** (admin → **Access Controls**) — declare the tags and restrict
   who can reach the Zimmer boxes to CI + your devices:

   ```jsonc
   {
     "tagOwners": { "tag:zimmer": ["autogroup:admin"], "tag:ci": ["autogroup:admin"] },
     "acls": [
       { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:zimmer:*"] },
       { "action": "accept", "src": ["tag:ci"],          "dst": ["tag:zimmer:*"] }
     ],
     "ssh": [
       { "action": "accept", "src": ["autogroup:member", "tag:ci"], "dst": ["tag:zimmer"], "users": ["root"] }
     ]
   }
   ```

   There is no API/MCP for Tailscale config — do this in the admin console.

### GHCR pull token — `GHCR_PULL_TOKEN`

**Why:** while the `ghcr.io/tadasant/zimmer` package is private, the droplet (and
`tadasant-internal`) must authenticate to pull it.

- GitHub → **Settings → Developer settings → PATs** → token with `read:packages`.
- → GitHub secret `GHCR_PULL_TOKEN`. Unnecessary once the package is public.

### Rails secret — `STAGING_SECRET_KEY_BASE`

- `openssl rand -hex 64` → GitHub secret `STAGING_SECRET_KEY_BASE`.

### One-time bootstrap

- Run the **Build base image** workflow once (publishes `ghcr.io/tadasant/zimmer-base`).
- Let a push to `main` publish the app image, then trigger **Deploy staging**.

## DNS — optional, and a recommendation

Because the box is **Tailscale-only**, you reach it by its MagicDNS name
(`http://zimmer-staging`) over the VPN — **public DNS is not required**. A public
`staging.zimmer.tadasant.com` A record would point at a public IP where the app
port is firewalled off, so it's only a vanity pointer.

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

Same set as staging, production values: `DIGITALOCEAN_ACCESS_TOKEN`,
`TAILSCALE_AUTH_KEY`, `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `GHCR_PULL_TOKEN`,
and `PROD_SECRET_KEY_BASE`. Plus:

- To make prod auto-upgrade the instant a new image publishes (not just the 30-min
  poll), add a `repository_dispatch` step to `zimmer`'s release workflow using a
  PAT stored as a `zimmer` secret with `contents:write` on `tadasant-internal`.
- Ensure the Tailscale ACL allows `tag:ci` + your devices to reach
  `zimmer-production`.

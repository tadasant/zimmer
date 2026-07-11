# Custom-domain HTTPS over the tailnet

By default a Zimmer droplet is reachable only at its Tailscale MagicDNS name over
plain HTTP (`http://zimmer`, `http://zimmer-staging`). That works, but because the
app runs with `config.assume_ssl = true` and there is no TLS, Rails computes
`https://…` origins that never match the browser's `http://…` — which breaks every
CSRF-protected form POST (422) and every ActionCable upgrade. See the
`assume_ssl`/plain-HTTP issues in the tracker.

Setting `var.domain` puts a **real HTTPS front door** on a custom name (e.g.
`https://zimmer.tadasant.com`), still reachable only over the tailnet. That makes
`assume_ssl` true *in reality*, so the whole class of bugs goes away at the source.

## How it works — and why the droplet holds no DNS credential

TLS behind a tailnet is awkward: the firewall opens no public 80/443, so ACME
HTTP-01/TLS-ALPN-01 can't work — only **DNS-01** can. The obvious way (Caddy on the
box doing DNS-01) would park a standing Cloudflare token on the droplet. We don't
do that. Instead the work is split:

- **On the droplet** (`cloud-init.yaml.tftpl`, when `var.domain` is set): a stock,
  plugin-less `caddy:2` container on `:443` that does **no ACME**. It only serves
  the cert files at `/opt/zimmer/certs/{cert,key}.pem` and reverse-proxies to the
  app. Reached only over the tailnet. The app keeps publishing `:80`, so the
  MagicDNS `http://…` path is unchanged and a Caddy misconfig can't take the box
  down. On first boot it serves a self-signed placeholder so it can start.

- **In CI** (`scripts/domain-cert.sh`, run by `domain-cert-*.yml`): discovers the
  droplet's tailnet IP, upserts the Cloudflare `domain -> tailnet IP` A record,
  issues/renews the Let's Encrypt cert via **ACME DNS-01 through Cloudflare**, and
  pushes **only the cert** onto the droplet over `tailscale ssh`, then reloads
  Caddy. The Cloudflare token lives only in GitHub Actions — never on the box.

The A record points at the **tailnet IP** (`100.x`), so tailnet peers resolve and
reach it while everyone else gets an unroutable address — same tailnet-only
exposure as the MagicDNS name, now with a real cert.

## Renewal

`domain-cert-*.yml` runs weekly and is a no-op unless the cert is missing,
self-signed, for the wrong name, or within 30 days of expiry — so it issues only
every ~60 days, far under Let's Encrypt's rate limits. It also runs on
`workflow_dispatch` (with a `force_issue` option) and via `workflow_call` so a
fresh deploy can chain it. Certs live in a host directory, so they survive image
auto-upgrades (container recreate); a droplet **replacement** (provision) drops
them, and the next workflow run re-registers the A record and re-issues.

## Turning it on

1. **Mint a Cloudflare API token**, scoped to **Zone:DNS:Edit + Zone:Zone:Read on
   the parent zone only** (nothing broader). Add it as the `CLOUDFLARE_API_TOKEN`
   Actions secret:
   - staging → `tadasant/zimmer`
   - production → `tadasant/tadasant-internal`
2. Set `domain` in the environment's tfvars (`staging.zimmer.tadasant.com` /
   `zimmer.tadasant.com`) and deploy/provision so the Caddy terminator ships.
3. Run the `domain-cert-*` workflow once (`workflow_dispatch`) to issue the first
   real cert. Thereafter the weekly schedule renews it.

The token is the only manual credential; everything else is automated.

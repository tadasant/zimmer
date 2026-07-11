#!/usr/bin/env bash
# Out-of-band custom-domain HTTPS for a Zimmer droplet, over the tailnet.
#
# Runs in CI (never on the droplet). It:
#   1. discovers the droplet's tailnet IP,
#   2. upserts the Cloudflare A record  domain -> tailnet IP  (so tailnet peers
#      reach it and nobody else can -- a 100.64/10 address is unroutable off-net),
#   3. issues/renews a Let's Encrypt cert for the domain via ACME DNS-01 through
#      Cloudflare (only when the box's current cert is missing, self-signed, for
#      the wrong name, or expiring within 30 days), and
#   4. pushes ONLY the cert + key onto the droplet and reloads its Caddy.
#
# The Cloudflare token is used here, in CI, and is never placed on the droplet:
# the box runs a plugin-less Caddy that only serves the pushed files (see
# cloud-init.yaml.tftpl). The token needs just Zone:DNS:Edit + Zone:Zone:Read on
# the one zone.
#
# Required env:
#   DOMAIN         e.g. zimmer.tadasant.com
#   TS_HOST        tailnet hostname to reach the droplet over `tailscale ssh`
#                  (production: zimmer; staging: zimmer-staging)
#   CF_ZONE_ID     Cloudflare zone id for the parent zone
#   CF_API_TOKEN   Cloudflare token (Zone:DNS:Edit + Zone:Zone:Read)
#   ACME_EMAIL     contact email for the ACME account
# Optional env:
#   LEGO_VERSION   pinned lego release (default below)
#   ACME_CA        ACME directory URL (default: Let's Encrypt production)
#   RENEW_DAYS     re-issue when fewer than this many days remain (default 30)
#   FORCE_ISSUE    "true" to issue regardless of the current cert
set -euo pipefail

: "${DOMAIN:?}" "${TS_HOST:?}" "${CF_ZONE_ID:?}" "${CF_API_TOKEN:?}" "${ACME_EMAIL:?}"
LEGO_VERSION="${LEGO_VERSION:-v4.19.2}"
ACME_CA="${ACME_CA:-https://acme-v02.api.letsencrypt.org/directory}"
RENEW_DAYS="${RENEW_DAYS:-30}"
FORCE_ISSUE="${FORCE_ISSUE:-false}"

log() { echo "[domain-cert] $*"; }
ssh_box() { tailscale ssh "root@${TS_HOST}" "$@"; }

# ---------------------------------------------------------------- 1. tailnet IP
TS_IP="$(ssh_box 'tailscale ip -4' | tr -d '\r' | head -1)"
case "$TS_IP" in
  100.*) log "droplet tailnet IP: $TS_IP" ;;
  *) echo "::error::unexpected tailnet IP for ${TS_HOST}: '${TS_IP}'"; exit 1 ;;
esac

# ---------------------------------------------------------------- 2. A record
cf() {
  # cf METHOD PATH [DATA]
  local method="$1" path="$2" data="${3:-}"
  curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
    ${data:+--data "$data"}
}

record_id="$(cf GET "/zones/${CF_ZONE_ID}/dns_records?type=A&name=${DOMAIN}" \
  | jq -r '.result[0].id // empty')"
body="$(jq -nc --arg n "$DOMAIN" --arg c "$TS_IP" \
  '{type:"A", name:$n, content:$c, ttl:120, proxied:false}')"
if [ -n "$record_id" ]; then
  cf PUT "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$body" >/dev/null
  log "updated A record ${DOMAIN} -> ${TS_IP}"
else
  cf POST "/zones/${CF_ZONE_ID}/dns_records" "$body" >/dev/null
  log "created A record ${DOMAIN} -> ${TS_IP}"
fi

# ---------------------------------------------------------------- 3. issue?
need_issue="$FORCE_ISSUE"
if [ "$need_issue" != "true" ]; then
  # Read the cert currently on the box (may be absent or the self-signed bootstrap).
  info="$(ssh_box "openssl x509 -in /opt/zimmer/certs/cert.pem -noout -issuer -subject -enddate -checkend $((RENEW_DAYS*86400)) 2>/dev/null; echo rc=\$?" || true)"
  issuer="$(printf '%s\n' "$info" | sed -n 's/^issuer=//p')"
  subject="$(printf '%s\n' "$info" | sed -n 's/^subject=//p')"
  rc="$(printf '%s\n' "$info" | sed -n 's/^rc=//p')"
  if [ -z "$issuer" ]; then
    need_issue=true; log "no readable cert on box -> issue"
  elif [ "$issuer" = "$subject" ]; then
    need_issue=true; log "cert is self-signed (issuer==subject) -> issue"
  elif ! printf '%s' "$subject" | grep -q "CN *= *${DOMAIN}"; then
    need_issue=true; log "cert subject is not ${DOMAIN} -> issue"
  elif [ "$rc" != "0" ]; then
    need_issue=true; log "cert expires within ${RENEW_DAYS}d -> issue"
  else
    log "cert on box is valid for >${RENEW_DAYS}d and matches ${DOMAIN} -> skip issuance"
  fi
fi

if [ "$need_issue" = "true" ]; then
  log "issuing via ACME DNS-01 (Cloudflare), lego ${LEGO_VERSION}"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/lego_${LEGO_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C "$tmp" lego
  CLOUDFLARE_DNS_API_TOKEN="$CF_API_TOKEN" "$tmp/lego" \
    --accept-tos --email "$ACME_EMAIL" --server "$ACME_CA" \
    --dns cloudflare --domains "$DOMAIN" --path "$tmp/.lego" run

  crt="$tmp/.lego/certificates/${DOMAIN}.crt"
  key="$tmp/.lego/certificates/${DOMAIN}.key"
  test -s "$crt" && test -s "$key"

  # Push atomically, then reload Caddy so it re-reads the files. The cert dir is a
  # read-only bind mount into the container; the files live on the host.
  ssh_box 'cat > /opt/zimmer/certs/cert.pem.new' < "$crt"
  ssh_box 'cat > /opt/zimmer/certs/key.pem.new'  < "$key"
  ssh_box 'set -e
    cd /opt/zimmer/certs
    chmod 600 key.pem.new; chmod 644 cert.pem.new
    mv cert.pem.new cert.pem
    mv key.pem.new  key.pem
    cid=$(docker compose -f /opt/zimmer/docker-compose.yml ps -q caddy)
    docker exec "$cid" caddy reload --config /etc/caddy/Caddyfile'
  log "pushed cert and reloaded Caddy"
fi

# ---------------------------------------------------------------- 4. verify
# The runner is a tailnet peer, so it resolves ${DOMAIN} (public A record) to the
# tailnet IP and reaches it over the tunnel. Assert 200 AND a real (non-self-signed)
# issuer, so a stuck self-signed placeholder can't pass as success.
for i in $(seq 1 10); do
  if issuer_now="$(curl -fsS --max-time 8 -o /dev/null -w '%{ssl_verify_result}\n' "https://${DOMAIN}/up" 2>/dev/null)" \
     && [ "$issuer_now" = "0" ]; then
    log "https://${DOMAIN}/up OK with a publicly-trusted cert"
    exit 0
  fi
  log "waiting for https://${DOMAIN} to serve a trusted cert ($i/10)..."
  sleep 6
done
echo "::error::https://${DOMAIN}/up did not serve a publicly-trusted cert in time"
exit 1

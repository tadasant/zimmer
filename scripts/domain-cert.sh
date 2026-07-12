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
#   4. pushes ONLY the cert + key onto the droplet and restarts its Caddy.
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

# GitHub runners get no MagicDNS, so `tailscale ssh root@<name>` cannot resolve the
# hostname ("lookup <name> ... server misbehaving") -- and after a droplet rebuild a
# stale node can briefly shadow the name too. Resolve the box's tailnet IP from
# `tailscale status --json` (the online peer with this hostname) and SSH to the IP,
# the same technique the deploy workflow uses. Resolved once, before any ssh_box call.
TS_IP="$(tailscale status --json 2>/dev/null \
  | jq -r --arg h "$TS_HOST" '.Peer[]? | select(.HostName==$h and .Online==true) | .TailscaleIPs[0]' \
  | head -1)"
case "$TS_IP" in
  100.*) log "resolved ${TS_HOST} -> tailnet IP $TS_IP" ;;
  *) echo "::error::could not resolve an online tailnet IP for ${TS_HOST} (got '${TS_IP}')"; exit 1 ;;
esac

# Push over key-based SSH when a deploy key is provided (CERT_SSH_KEY) -- this works
# on any runner and does not depend on the tailnet SSH policy (self-hosted CI runners
# do not reliably satisfy the `tailscale ssh` identity check). Fall back to
# `tailscale ssh` when no key is set, for environments that rely on it.
if [ -n "${CERT_SSH_KEY:-}" ]; then
  ssh_box() { ssh -i "$CERT_SSH_KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@${TS_IP}" "$@"; }
else
  ssh_box() { tailscale ssh "root@${TS_IP}" "$@"; }
fi

# ---------------------------------------------------------------- 2. A record
# Keep the token out of the process argv (it would show in `ps`): write the auth
# header to a 0600 curl config once (printf is a builtin, so no argv exposure) and
# feed it with -K. cleanup() tears this down (and the lego tmp dir) on any exit.
CURL_CFG="$(mktemp)"; chmod 600 "$CURL_CFG"
printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" > "$CURL_CFG"
cleanup() { rm -f "${CURL_CFG:-}"; rm -rf "${tmp:-}"; }
trap cleanup EXIT
cf() {
  # cf METHOD PATH [DATA]
  local method="$1" path="$2" data="${3:-}"
  curl -fsS -K "$CURL_CFG" -X "$method" "https://api.cloudflare.com/client/v4${path}" \
    -H "Content-Type: application/json" \
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
  # The remote command always ends `echo rc=$?`, so ssh_box exits 0 whenever the
  # SSH transport itself worked -- a non-zero exit here means we could NOT reach the
  # box, which we must treat as fail-closed: skip issuance and keep serving the
  # current cert, rather than mistaking an unreachable box for a missing cert and
  # burning a Let's Encrypt issuance on every transient blip.
  if info="$(ssh_box "openssl x509 -in /opt/zimmer/certs/cert.pem -noout -issuer -subject -ext subjectAltName -checkend $((RENEW_DAYS*86400)) 2>/dev/null; echo rc=\$?")"; then
    issuer="$(printf '%s\n' "$info" | sed -n 's/^issuer=//p')"
    subject="$(printf '%s\n' "$info" | sed -n 's/^subject=//p')"
    rc="$(printf '%s\n' "$info" | sed -n 's/^rc=//p')"
    # Match the domain against the Subject Alternative Name, not the Subject CN:
    # Let's Encrypt is phasing out the CN (SAN-only certs), so a CN match would go
    # stale and force a needless re-issue every run. Space-normalize the whole blob
    # and look for the literal token "DNS:${DOMAIN}" (dots literal -- no regex).
    covers_domain=false
    case "$(printf '%s' "$info" | tr -d ' ')" in
      *"DNS:${DOMAIN}"*) covers_domain=true ;;
    esac
    if [ -z "$issuer" ]; then
      need_issue=true; log "no readable cert on box -> issue"
    elif [ "$issuer" = "$subject" ]; then
      need_issue=true; log "cert is self-signed (issuer==subject) -> issue"
    elif [ "$covers_domain" != "true" ]; then
      need_issue=true; log "cert SAN does not cover ${DOMAIN} -> issue"
    elif [ "$rc" != "0" ]; then
      need_issue=true; log "cert expires within ${RENEW_DAYS}d -> issue"
    else
      log "cert on box is valid for >${RENEW_DAYS}d and covers ${DOMAIN} -> skip issuance"
    fi
  else
    log "could not reach ${TS_HOST} to inspect its cert -> fail closed, skip issuance this run"
  fi
fi

if [ "$need_issue" = "true" ]; then
  log "issuing via ACME DNS-01 (Cloudflare), lego ${LEGO_VERSION}"
  tmp="$(mktemp -d)" # removed by cleanup() on exit
  curl -fsSL "https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/lego_${LEGO_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C "$tmp" lego
  CLOUDFLARE_DNS_API_TOKEN="$CF_API_TOKEN" "$tmp/lego" \
    --accept-tos --email "$ACME_EMAIL" --server "$ACME_CA" \
    --dns cloudflare --domains "$DOMAIN" --path "$tmp/.lego" run

  crt="$tmp/.lego/certificates/${DOMAIN}.crt"
  key="$tmp/.lego/certificates/${DOMAIN}.key"
  test -s "$crt" && test -s "$key"

  # Push atomically, then restart Caddy so it re-reads the files. The cert dir is a
  # read-only bind mount into the container; the files live on the host. The private
  # key is created with a 0600 umask so it is never briefly world-readable on disk.
  ssh_box 'cat > /opt/zimmer/certs/cert.pem.new' < "$crt"
  ssh_box '(umask 077; cat > /opt/zimmer/certs/key.pem.new)' < "$key"
  ssh_box 'set -e
    cd /opt/zimmer/certs
    chmod 600 key.pem.new; chmod 644 cert.pem.new
    mv cert.pem.new cert.pem
    mv key.pem.new  key.pem
    # restart (not `caddy reload`): the Caddyfile sets `admin off`, so the admin
    # API reload endpoint is unavailable. A restart re-reads the cert files from the
    # bind-mounted /certs; the app keeps serving on :80 through the ~1s blip.
    #
    # Two shapes exist while the Kamal migration rolls out: a Kamal host runs Caddy
    # as the standalone `zimmer-caddy` container (no compose file), while a not-yet
    # -migrated host still runs it as a compose service. Try the Kamal one first and
    # fall back, so this shared script keeps renewing certs on BOTH.
    docker restart zimmer-caddy 2>/dev/null \
      || docker compose -f /opt/zimmer/docker-compose.yml restart caddy'
  log "pushed cert and restarted Caddy"
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

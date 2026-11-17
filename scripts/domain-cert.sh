#!/usr/bin/env bash
# Out-of-band custom-domain HTTPS for a Zimmer droplet, over the tailnet -- or, for a
# droplet that runs without Tailscale, over plain SSH to an address the caller names.
#
# Runs in CI (never on the droplet). It:
#   1. discovers the droplet's tailnet IP (or takes CERT_HOST_IP as given),
#   2. upserts the Cloudflare A record  domain -> tailnet IP  (so tailnet peers
#      reach it and nobody else can -- a 100.64/10 address is unroutable off-net),
#   3. issues/renews a Let's Encrypt cert for the domain via ACME DNS-01 through
#      Cloudflare (only when the box's current cert is missing, self-signed, for
#      the wrong name, or expiring within 30 days), and
#   4. pushes ONLY the cert + key onto the droplet and restarts its Caddy.
#
# With CERT_HOST_IP (no-Tailscale mode) step 2 never runs: such a domain is served by
# the Cloudflare edge's tunnel, and the script never points a public name at the box.
# The final probe also runs ON the box, over SSH, because the runner reaches the box
# only through the :22 rule its workflow opened -- never on :443.
#
# The Cloudflare token is used here, in CI, and is never placed on the droplet:
# the box runs a plugin-less Caddy that only serves the pushed files (see
# cloud-init.yaml.tftpl). The token needs just Zone:DNS:Edit + Zone:Zone:Read on
# the one zone.
#
# Required env:
#   DOMAIN         e.g. zimmer.tadasant.com
#   CF_ZONE_ID     Cloudflare zone id for the parent zone
#   CF_API_TOKEN   Cloudflare token (Zone:DNS:Edit + Zone:Zone:Read)
#   ACME_EMAIL     contact email for the ACME account. Needed only when a cert is issued:
#                  lego will not register without one
# and exactly one way to reach the droplet:
#   TS_HOST        tailnet hostname, resolved to its 100.x IP via `tailscale status`
#                  (production: zimmer; staging: zimmer-staging). SSH goes over
#                  CERT_SSH_KEY when set, else `tailscale ssh`.
#   CERT_HOST_IP   the droplet's address, used as given -- for a droplet without
#                  Tailscale. Requires CERT_SSH_KEY (plain key-only OpenSSH on :22).
#                  Wins over TS_HOST when both are set.
# Optional env:
#   CERT_SSH_KEY   private key for root on the droplet (see above)
#   CERT_KNOWN_HOSTS  known_hosts file pinning the droplet's host key. When set, SSH
#                  verifies it (StrictHostKeyChecking=yes); otherwise the first key
#                  that answers is accepted. Worth setting with CERT_HOST_IP, where the
#                  SSH crosses the public internet rather than an authenticated tailnet.
#   LEGO_VERSION   pinned lego release (default below)
#   ACME_CA        ACME directory URL (default: Let's Encrypt production)
#   RENEW_DAYS     re-issue when fewer than this many days remain (default 30)
#   FORCE_ISSUE    "true" to issue regardless of the current cert
set -euo pipefail

: "${DOMAIN:?}" "${CF_ZONE_ID:?}" "${CF_API_TOKEN:?}"
LEGO_VERSION="${LEGO_VERSION:-v4.19.2}"
ACME_CA="${ACME_CA:-https://acme-v02.api.letsencrypt.org/directory}"
RENEW_DAYS="${RENEW_DAYS:-30}"
FORCE_ISSUE="${FORCE_ISSUE:-false}"

log() { echo "[domain-cert] $*"; }

if [ -n "${CERT_HOST_IP:-}" ]; then
  # No-Tailscale mode: the caller already knows the address (e.g. the droplet's reserved
  # IP from `terraform output`) and has opened :22 to this runner. There is no
  # `tailscale ssh` to fall back to, so the key is mandatory.
  : "${CERT_SSH_KEY:?CERT_HOST_IP needs CERT_SSH_KEY: without Tailscale the box is reached over key-only OpenSSH}"
  HOST_IP="$CERT_HOST_IP"
  HOST_LABEL="$CERT_HOST_IP"
  VIA_TAILNET=false
  log "using CERT_HOST_IP ${HOST_IP} (no tailnet)"
else
  : "${TS_HOST:?set TS_HOST (tailnet hostname) or CERT_HOST_IP (droplet address, no Tailscale)}"
  # GitHub runners get no MagicDNS, so `tailscale ssh root@<name>` cannot resolve the
  # hostname ("lookup <name> ... server misbehaving") -- and after a droplet rebuild a
  # stale node can briefly shadow the name too. Resolve the box's tailnet IP from
  # `tailscale status --json` (the online peer with this hostname) and SSH to the IP,
  # the same technique the deploy workflow uses. Resolved once, before any ssh_box call.
  HOST_IP="$(tailscale status --json 2>/dev/null \
    | jq -r --arg h "$TS_HOST" '.Peer[]? | select(.HostName==$h and .Online==true) | .TailscaleIPs[0]' \
    | head -1)"
  case "$HOST_IP" in
    100.*) log "resolved ${TS_HOST} -> tailnet IP $HOST_IP" ;;
    *) echo "::error::could not resolve an online tailnet IP for ${TS_HOST} (got '${HOST_IP}')"; exit 1 ;;
  esac
  HOST_LABEL="$TS_HOST"
  VIA_TAILNET=true
fi

# Push over key-based SSH when a deploy key is provided (CERT_SSH_KEY) -- this works
# on any runner and does not depend on the tailnet SSH policy (a CI node does not
# reliably satisfy the `tailscale ssh` identity check). Fall back to
# `tailscale ssh` when no key is set, for environments that rely on it.
if [ -n "${CERT_KNOWN_HOSTS:-}" ]; then
  HOSTKEY_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${CERT_KNOWN_HOSTS}")
else
  HOSTKEY_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null)
fi
if [ -n "${CERT_SSH_KEY:-}" ]; then
  ssh_box() { ssh -i "$CERT_SSH_KEY" "${HOSTKEY_OPTS[@]}" -o LogLevel=ERROR "root@${HOST_IP}" "$@"; }
else
  ssh_box() { tailscale ssh "root@${HOST_IP}" "$@"; }
fi

# ---------------------------------------------------------------- 2. A record
# Keep the token out of the process argv (it would show in `ps`): write the auth
# header to a 0600 curl config once (printf is a builtin, so no argv exposure) and
# feed it with -K. cleanup() tears this down (and the lego tmp dir) on any exit.
CURL_CFG="$(mktemp)"; chmod 600 "$CURL_CFG"
printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" > "$CURL_CFG"
# shellcheck disable=SC2317  # reached through the EXIT trap on the next line, not by fallthrough.
cleanup() { rm -f "${CURL_CFG:-}"; rm -rf "${tmp:-}"; }
trap cleanup EXIT
cf() {
  # cf METHOD PATH [DATA]
  local method="$1" path="$2" data="${3:-}"
  curl -fsS -K "$CURL_CFG" -X "$method" "https://api.cloudflare.com/client/v4${path}" \
    -H "Content-Type: application/json" \
    ${data:+--data "$data"}
}

# The live record decides, not a flag. When the optional Cloudflare edge serves the
# domain, its tunnel owns the name as a proxied CNAME to <tunnel-id>.cfargotunnel.com.
# An A-record upsert there would fail (a name cannot carry both) and turn this job red
# every week -- so leave DNS alone. The cert is still needed: the host Caddy keeps
# serving the domain to tailnet peers and to the app's own pinned containers.
tunnel_target=""
if [ "$VIA_TAILNET" = "true" ]; then
  tunnel_target="$(cf GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${DOMAIN}" \
    | jq -r '[.result[]? | .content | select(endswith(".cfargotunnel.com"))][0] // empty')"
fi
if [ "$VIA_TAILNET" != "true" ]; then
  # A public address would publish a name for a box whose firewall admits no TCP, and
  # the tunnel (when there is one) already owns it. DNS is not this script's to touch.
  log "no tailnet (CERT_HOST_IP): leaving DNS for ${DOMAIN} alone"
elif [ -n "$tunnel_target" ]; then
  log "${DOMAIN} is a Cloudflare Tunnel CNAME (${tunnel_target}); leaving its DNS alone"
else
  record_id="$(cf GET "/zones/${CF_ZONE_ID}/dns_records?type=A&name=${DOMAIN}" \
    | jq -r '.result[0].id // empty')"
  body="$(jq -nc --arg n "$DOMAIN" --arg c "$HOST_IP" \
    '{type:"A", name:$n, content:$c, ttl:120, proxied:false}')"
  if [ -n "$record_id" ]; then
    cf PUT "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$body" >/dev/null
    log "updated A record ${DOMAIN} -> ${HOST_IP}"
  else
    cf POST "/zones/${CF_ZONE_ID}/dns_records" "$body" >/dev/null
    log "created A record ${DOMAIN} -> ${HOST_IP}"
  fi
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
    log "could not reach ${HOST_LABEL} to inspect its cert -> fail closed, skip issuance this run"
  fi
fi

if [ "$need_issue" = "true" ]; then
  # Checked here rather than up front: only issuance needs it, and a run that finds the cert
  # still valid must not fail on it.
  : "${ACME_EMAIL:?is not set: lego will not register an ACME account without a contact email (in CI: the ACME_EMAIL Actions secret)}"
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
    # restart (not "caddy reload"): the Caddyfile sets "admin off", so the admin
    # API reload endpoint is unavailable. A restart re-reads the cert files from the
    # bind-mounted /certs; the app keeps serving on :80 through the ~1s blip.
    #
    # Two shapes exist while the Kamal migration rolls out: a Kamal host runs Caddy
    # as the standalone "zimmer-caddy" container (no compose file), while a not-yet
    # -migrated host still runs it as a compose service. Try the Kamal one first and
    # fall back, so this shared script keeps renewing certs on BOTH.
    docker restart zimmer-caddy 2>/dev/null \
      || docker compose -f /opt/zimmer/docker-compose.yml restart caddy'
  log "pushed cert and restarted Caddy"
fi

# ---------------------------------------------------------------- 4. verify
# Pinned to the box with --resolve rather than through public DNS: the runner is a
# tailnet peer, so it reaches HOST_IP directly, and the check stays a check of THIS box's
# Caddy even when public DNS points the name at a Cloudflare Tunnel. Assert
# 200 AND a real (non-self-signed) issuer, so a stuck self-signed placeholder can't pass
# as success.
#
# Without a tailnet the runner cannot reach :443 at all -- its firewall rule is :22 only --
# so the same probe runs on the box itself, against its own Caddy on loopback (Caddy runs
# with --network host). cloud-init installs curl and ca-certificates there.
probe() {
  if [ "$VIA_TAILNET" = "true" ]; then
    curl -fsS --max-time 8 -o /dev/null -w '%{ssl_verify_result}\n' --resolve "${DOMAIN}:443:${HOST_IP}" "https://${DOMAIN}/up" 2>/dev/null
  else
    ssh_box "curl -fsS --max-time 8 -o /dev/null -w '%{ssl_verify_result}\n' --resolve '${DOMAIN}:443:127.0.0.1' 'https://${DOMAIN}/up' 2>/dev/null"
  fi
}
for i in $(seq 1 10); do
  if issuer_now="$(probe)" \
     && [ "$issuer_now" = "0" ]; then
    log "https://${DOMAIN}/up OK with a publicly-trusted cert"
    exit 0
  fi
  log "waiting for https://${DOMAIN} to serve a trusted cert ($i/10)..."
  sleep 6
done
echo "::error::https://${DOMAIN}/up did not serve a publicly-trusted cert in time"
exit 1

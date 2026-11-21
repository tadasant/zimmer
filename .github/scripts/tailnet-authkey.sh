#!/usr/bin/env bash
# Mint a short-lived, single-use, ephemeral, tagged tailnet auth key for ONE CI job and
# write it to a 0600 file, which the staging workflows hand to tailscale/github-action as
# `authkey: file:<path>`.
#
#   Run:  bash .github/scripts/tailnet-authkey.sh "$RUNNER_TEMP/tailnet-authkey"
#
# Why: the runner used to join with secrets.TS_CI_AUTHKEY, a pre-minted auth key.
# Tailscale caps those at 90 days and expires them silently. When it lapsed, every
# `tailscale up` logged `invalid key: API key does not exist`, the action still reported
# success, and the deploy timed out ten minutes later blaming the droplet
# (run 44922555470). An OAuth client does not expire, so this mints a fresh key per job:
#
#   POST /api/v2/oauth/token      client_credentials, scope=auth_keys
#   POST /api/v2/tailnet/-/keys   reusable=false, ephemeral=true, preauthorized=true,
#                                 tags=$TS_AUTHKEY_TAGS, expirySeconds=$TS_AUTHKEY_EXPIRY_SECONDS
#
# The OAuth client must hold the `auth_keys` scope and own every tag in TS_AUTHKEY_TAGS.
# The default tag is tag:zimmer-ci because the tailnet's SSH rules accept tag:zimmer-ci
# (and tag:ci) as root on tag:zimmer-staging, and every deploy step reaches the droplet
# over Tailscale SSH on :22. The droplet's own client (TS_OAUTH_CLIENT_ID) owns only
# tag:zimmer-staging, which no SSH rule accepts, so it cannot stand in here.
#
# Same approach as tadasant-internal's scripts/tailnet-authkey.sh, and for the same
# reasons it does not use the action's `oauth-secret` input: that path puts the long-lived
# client secret on a `sudo tailscale up` command line. Here nothing secret reaches argv:
# the client secret goes to curl on stdin, the bearer token goes to curl as a config file
# on stdin, and the minted key goes to a 0600 file that `tailscale up` reads with
# `--authkey=file:<path>` (supported since 1.82.0, the action v3 default).
#
# Fallback: if the OAuth pair is unset, or the exchange or the mint fails, the static
# TS_FALLBACK_AUTHKEY (secrets.TS_CI_AUTHKEY) is written instead, with a ::warning:: that
# names the reason. With no fallback either, the step fails with ::error::. A dead
# fallback key still gets past this script; .github/scripts/tailnet-verify-joined.sh,
# which runs right after the action, is what catches that.
#
# Env:
#   TS_OAUTH_CLIENT_ID, TS_OAUTH_CLIENT_SECRET   the OAuth client (may be empty)
#   TS_FALLBACK_AUTHKEY                          static key fallback (may be empty)
#   TS_AUTHKEY_TAGS                              comma-separated, default tag:zimmer-ci
#   TS_AUTHKEY_EXPIRY_SECONDS                    default 900 (the action's worst case is
#                                                ~12m: 5 x 2m tries + backoff)
#   TS_API_BASE                                  default https://api.tailscale.com
set -euo pipefail

out="${1:?usage: tailnet-authkey.sh <output-file>}"
api="${TS_API_BASE:-https://api.tailscale.com}"
tags="${TS_AUTHKEY_TAGS:-tag:zimmer-ci}"
expiry="${TS_AUTHKEY_EXPIRY_SECONDS:-900}"
case "$expiry" in
  ''|*[!0-9]*) echo "::error::TS_AUTHKEY_EXPIRY_SECONDS must be a whole number of seconds, got '$expiry'"; exit 2 ;;
esac

# Workflow-command data escaping (% CR LF), so a reason can never break or forge a
# ::warning:: / ::error:: line.
wfcmd_escape() { local v="${1//%/%25}"; v="${v//$'\r'/%0D}"; printf '%s' "${v//$'\n'/%0A}"; }

umask 077
rm -f "$out"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Prints the minted key on stdout. On failure prints the reason on stdout and returns
# non-zero.
mint() {
  if [ -z "${TS_OAUTH_CLIENT_ID:-}" ] || [ -z "${TS_OAUTH_CLIENT_SECRET:-}" ]; then
    echo "no OAuth client is configured (TS_CI_OAUTH_CLIENT_ID / TS_CI_OAUTH_CLIENT_SECRET unset)"
    return 1
  fi

  local code token body key
  code=$(printf '%s' "$TS_OAUTH_CLIENT_SECRET" | curl -sS --max-time 20 --retry 3 \
      -o "$scratch/token.json" -w '%{http_code}' \
      --data-urlencode "client_id=${TS_OAUTH_CLIENT_ID}" \
      --data-urlencode "client_secret@-" \
      --data-urlencode "scope=auth_keys" \
      "$api/api/v2/oauth/token" 2>"$scratch/curl.err") || {
    echo "OAuth token request failed: $(tr '\n' ' ' <"$scratch/curl.err")"
    return 1
  }
  token=$(jq -r '.access_token // empty' "$scratch/token.json" 2>/dev/null || true)
  if [ "$code" != 200 ] || [ -z "$token" ]; then
    echo "OAuth token exchange returned HTTP $code ($(jq -r '.message // .error // empty' "$scratch/token.json" 2>/dev/null || true)) -- does the client hold the auth_keys scope?"
    return 1
  fi
  echo "::add-mask::$token" >&2

  body=$(jq -cn --arg tags "$tags" --argjson exp "$expiry" \
      --arg desc "gha-${GITHUB_REPOSITORY:-local}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}" '{
    capabilities: {devices: {create: {
      reusable: false, ephemeral: true, preauthorized: true,
      tags: ($tags | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))
    }}},
    expirySeconds: $exp,
    description: ($desc | gsub("[^A-Za-z0-9-]"; "-") | .[0:50])
  }')
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS --max-time 20 --retry 3 \
      -K - -o "$scratch/key.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' --data-binary "$body" \
      "$api/api/v2/tailnet/-/keys" 2>"$scratch/curl.err") || {
    echo "auth key mint request failed: $(tr '\n' ' ' <"$scratch/curl.err")"
    return 1
  }
  key=$(jq -r '.key // empty' "$scratch/key.json" 2>/dev/null || true)
  if [ "$code" != 200 ] || [ -z "$key" ]; then
    echo "auth key mint returned HTTP $code ($(jq -r '.message // empty' "$scratch/key.json" 2>/dev/null || true)) -- does the OAuth client own tags [$tags]?"
    return 1
  fi
  printf '%s' "$key"
}

fix="Create a Tailscale OAuth client with the auth_keys (write) scope and tag(s) $tags, and store it as the TS_CI_OAUTH_CLIENT_ID / TS_CI_OAUTH_CLIENT_SECRET Actions secrets."

if result=$(mint); then
  echo "::add-mask::$result"
  printf '%s\n' "$result" >"$out"
  echo "tailnet auth key: minted via OAuth (tags=$tags, single-use, ephemeral, expires in ${expiry}s)"
  exit 0
fi

if [ -n "${TS_FALLBACK_AUTHKEY:-}" ]; then
  echo "::add-mask::$TS_FALLBACK_AUTHKEY"
  echo "::warning title=tailnet auth key: OAuth mint failed, using static TS_CI_AUTHKEY::$(wfcmd_escape "$result"). Falling back to secrets.TS_CI_AUTHKEY, which Tailscale expires within 90 days. $fix"
  printf '%s\n' "$TS_FALLBACK_AUTHKEY" >"$out"
  exit 0
fi

echo "::error title=tailnet auth key: no usable credential::$(wfcmd_escape "$result"), and TS_CI_AUTHKEY (the fallback) is unset. The runner cannot join the tailnet. $fix"
exit 1

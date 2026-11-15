#!/usr/bin/env bash
# Converge a droplet's SSH identity on EVERY deploy: the public keys authorized for root,
# and (optionally) a pinned ed25519 host key. Runs over Tailscale SSH (:22), like the other
# converge scripts, and is safe to re-run -- a second run on a converged box changes nothing
# and restarts nothing.
#
# Why a converge and not cloud-init alone: cloud-init runs ONCE, at droplet creation, and the
# droplet ignores user_data changes. So a key added to the declared list never reaches a box
# that already exists, and a box that IS rebuilt generates a fresh host key -- which breaks
# every client that pins one. strad's SSH server pins strictly (no trust-on-first-use, no
# @cert-authority), so either loss makes its staging slug refuse to connect until a human
# re-seeds it. Converging both on every deploy makes "the deploy finished" mean "strad can
# reach this box with the key it holds", whether this run created the droplet or not.
#
# Inputs (environment; both optional, and an empty one skips its half):
#   AUTHORIZED_PUBKEYS    Public keys to authorize for root, one per line. ADD-ONLY: a key
#                         already on the box but absent here is left alone (see
#                         docs/limitations "Admin keys are add-only"). A key already present
#                         under a different comment is not added twice.
#   SSH_HOST_ED25519_KEY  The pinned host PRIVATE key, OpenSSH format -- raw, or base64 of
#                         the file (for a store that strips newlines). Never echoed; it
#                         travels only on ssh's stdin. Its public half is derived here, so
#                         there is no second value to keep in sync.
#
# The host key goes in by SSH rather than through Terraform's ssh_host_ed25519_key variable
# on purpose: that variable rides user_data, which any process on the droplet -- including
# every agent-session container -- can read from the DigitalOcean metadata service.
#
# After installing, the script reads the key :2222 actually presents (ssh-keyscan) and fails
# the deploy if it is not the pinned one, because that listener is what strad dials.
#
# Usage: converge-ssh-identity.sh <tailnet-host-or-ip>
set -euo pipefail

HOST="${1:?usage: converge-ssh-identity.sh <tailnet-host-or-ip>}"
ATTEMPTS="${ATTEMPTS:-6}"
KEYSCAN_PORT="${KEYSCAN_PORT:-2222}"
AUTHORIZED_PUBKEYS="${AUTHORIZED_PUBKEYS:-}"
SSH_HOST_ED25519_KEY="${SSH_HOST_ED25519_KEY:-}"

case "$ATTEMPTS" in
  ''|*[!0-9]*) echo "::error::ATTEMPTS must be a positive integer (got '${ATTEMPTS}')"; exit 2 ;;
esac
if [ "$ATTEMPTS" -lt 1 ]; then
  echo "::error::ATTEMPTS must be a positive integer (got '${ATTEMPTS}')"
  exit 2
fi

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# ---- Validate inputs locally, before touching the box ---------------------------------
# A private key pasted into the public-key variable must never be appended to
# authorized_keys (it would not work, and it would put the private half on the box in a
# world-readable-by-root file). Refuse without echoing it.
keys_file="$work/authorized.pub"
: > "$keys_file"
if [ -n "$AUTHORIZED_PUBKEYS" ]; then
  if printf '%s' "$AUTHORIZED_PUBKEYS" | grep -q 'PRIVATE KEY'; then
    echo "::error::AUTHORIZED_PUBKEYS contains a PRIVATE key. Refusing to continue; nothing was changed."
    exit 2
  fi
  n=0
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$line" ] || continue
    n=$((n + 1))
    # A bare "<type> <blob> [comment]" line only. An options prefix (from="...", command=...)
    # would shift the blob out of field 2, which is what the box-side dedupe matches on.
    case "$line" in
      ssh-*|ecdsa-*|sk-*) ;;
      *) echo "::error::AUTHORIZED_PUBKEYS line ${n} does not start with a key type (options such as from= are not supported). Nothing was changed."; exit 2 ;;
    esac
    printf '%s\n' "$line" > "$work/one.pub"
    if ! fp=$(ssh-keygen -l -f "$work/one.pub" 2>/dev/null); then
      echo "::error::AUTHORIZED_PUBKEYS line ${n} is not an OpenSSH public key. Nothing was changed."
      exit 2
    fi
    echo "  will authorize: ${fp}"
    printf '%s\n' "$line" >> "$keys_file"
  done <<<"$AUTHORIZED_PUBKEYS"
fi

host_pub=""
if [ -n "$SSH_HOST_ED25519_KEY" ]; then
  hk="$work/host_key"
  ( umask 077
    raw=$(printf '%s\n' "$SSH_HOST_ED25519_KEY" | tr -d '\r' | sed -e 's/^[[:space:]]*//')
    case "$raw" in
      -----BEGIN*) printf '%s\n' "$raw" > "$hk" ;;
      *) printf '%s' "$raw" | tr -d '[:space:]' | base64 -d > "$hk" 2>/dev/null || : ;;
    esac )
  if ! derived=$(ssh-keygen -y -f "$hk" 2>/dev/null); then
    echo "::error::SSH_HOST_ED25519_KEY is set but is not a readable, unencrypted OpenSSH private key"
    echo "::error::(raw, or base64 of the file). Nothing was changed."
    exit 2
  fi
  # type + blob only: the comment is cosmetic and must not decide "already converged".
  host_pub=$(printf '%s\n' "$derived" | awk '{print $1" "$2}')
  case "$host_pub" in
    ssh-ed25519\ *) ;;
    *) echo "::error::SSH_HOST_ED25519_KEY is a ${host_pub%% *} key, not ssh-ed25519. Nothing was changed."; exit 2 ;;
  esac
  printf '%s\n' "$host_pub" > "$work/host.pub"
  echo "  will pin host key: $(ssh-keygen -l -f "$work/host.pub")"
fi

if [ ! -s "$keys_file" ] && [ -z "$host_pub" ]; then
  echo "Neither AUTHORIZED_PUBKEYS nor SSH_HOST_ED25519_KEY is set -- nothing to converge on ${HOST}."
  exit 0
fi

# ---- Remote payloads -------------------------------------------------------------------
# Data rides stdin; the script text rides the command line. Neither holds a secret on the
# command line, where it would show up in the remote box's process list.
#
# shellcheck disable=SC2016  # expanded remotely, deliberately.
authorize_remote='
  set -eu
  # On a droplet created this run, cloud-init may still be appending its own keys and binding
  # :2222. Let it finish first, bounded, and carry on either way: a box whose cloud-init
  # failed still deserves the keys.
  timeout 900 cloud-init status --wait >/dev/null 2>&1 || true
  install -d -m 0700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  # A file whose last line has no newline would have the next key glued onto it.
  if [ -s /root/.ssh/authorized_keys ] && [ -n "$(tail -c1 /root/.ssh/authorized_keys)" ]; then
    echo >> /root/.ssh/authorized_keys
  fi
  added=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    blob=$(printf "%s\n" "$key" | awk "{print \$2}")
    if awk -v b="$blob" "{for (i = 1; i <= NF; i++) if (\$i == b) f = 1} END {exit !f}" /root/.ssh/authorized_keys; then
      continue
    fi
    printf "%s\n" "$key" >> /root/.ssh/authorized_keys
    added=$((added + 1))
  done
  echo "authorized_keys: ${added} key(s) added"
'

# The wanted public key is passed as $1 (it is public); $2 = "restart" forces an sshd restart
# even when the files already hold the key (the recovery path for a daemon still serving an
# old key). The private key is read from stdin only when it has to be written; on a converged
# box it is drained and discarded.
#
# NO SINGLE QUOTES anywhere in this payload, comments included: it is sent wrapped in
# sh -c '...', and the guard below refuses to run if one creeps in.
# shellcheck disable=SC2016
hostkey_remote='
  set -eu
  want="$1"
  mode="${2:-}"
  timeout 900 cloud-init status --wait >/dev/null 2>&1 || true
  cur=$(ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key 2>/dev/null | awk "{print \$1\" \"\$2}" || true)
  pub=$(awk "{print \$1\" \"\$2}" /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || true)
  if [ "$cur" = "$want" ] && [ "$pub" = "$want" ]; then
    cat > /dev/null
    if [ "$mode" = "restart" ]; then
      sshd -t
      systemctl restart ssh.service 2>/dev/null || systemctl restart sshd
      echo "host key: already pinned on disk; restarted sshd so the daemon serves it"
    else
      echo "host key: already pinned, sshd not restarted"
    fi
    exit 0
  fi
  # Validate the config BEFORE swapping the key, so an unrelated config error cannot leave a
  # new key on disk that the running daemon never loads.
  sshd -t
  umask 077
  tmp=$(mktemp /etc/ssh/.ssh_host_ed25519_key.XXXXXX)
  trap "rm -f \"$tmp\"" EXIT
  cat > "$tmp"
  got=$(ssh-keygen -y -f "$tmp" | awk "{print \$1\" \"\$2}")
  if [ "$got" != "$want" ]; then
    echo "host key: received key does not match the expected public half" >&2
    exit 3
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" /etc/ssh/ssh_host_ed25519_key
  printf "%s root@%s\n" "$want" "$(hostname)" > /etc/ssh/ssh_host_ed25519_key.pub
  chmod 644 /etc/ssh/ssh_host_ed25519_key.pub
  # ssh.service is the one long-lived sshd -D that socket activation hands :22/:2222 to;
  # it loads host keys at start, so it is the unit that has to restart. Open sessions
  # survive (KillMode=process).
  systemctl restart ssh.service 2>/dev/null || systemctl restart sshd
  echo "host key: installed the pinned key and restarted sshd"
'

case "$hostkey_remote" in
  *"'"*) echo "::error::internal: the host-key payload contains a single quote and cannot be sent through sh -c."; exit 2 ;;
esac

# Retried on ssh's own failure (255) only: a freshly-created droplet can report Online on
# the tailnet before sshd answers. A non-255 status is the payload failing, which a retry
# would not fix.
run_remote() {
  local label="$1" stdin_file="$2"; shift 2
  local rc
  for attempt in $(seq 1 "$ATTEMPTS"); do
    rc=0
    # shellcheck disable=SC2029  # the payload is built client-side on purpose; its own `$` are quoted.
    ssh "${SSH_OPTS[@]}" root@"${HOST}" "$@" < "$stdin_file" || rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
    if [ "$rc" -ne 255 ]; then
      echo "::error::${label} on ${HOST} exited ${rc}."
      return "$rc"
    fi
    echo "   could not reach ${HOST} over Tailscale SSH (attempt ${attempt}/${ATTEMPTS})"
    if [ "$attempt" -lt "$ATTEMPTS" ]; then
      backoff=$(( attempt * 15 ))
      if [ "$backoff" -gt 60 ]; then backoff=60; fi
      sleep "$backoff"
    fi
  done
  echo "::error::Could not complete an SSH session with ${HOST} on any of ${ATTEMPTS} attempts (${label})."
  return 1
}

if [ -s "$keys_file" ]; then
  echo "Converging authorized_keys on ${HOST}…"
  run_remote "authorized_keys converge" "$keys_file" "$authorize_remote"
fi

if [ -n "$host_pub" ]; then
  echo "Converging the pinned host key on ${HOST}…"
  # The payload is `sh -c`'s script and the wanted key its $1, so stdin stays free for the
  # private key. Single-quoting is safe: the guard above keeps quotes out of the payload, and a
  # validated "ssh-ed25519 <base64>" contains none.
  run_remote "host-key converge" "$hk" "sh -c '${hostkey_remote}' converge '${host_pub}'"

  # Prove it from the outside: the key :KEYSCAN_PORT presents is what strad's pin checks.
  # The budget (~2 minutes) covers a just-restarted sshd and a cloud-init that timed out above.
  scan() {
    presented=""
    for attempt in $(seq 1 12); do
      presented=$(ssh-keyscan -T 10 -t ed25519 -p "$KEYSCAN_PORT" "$HOST" 2>/dev/null | awk '$2 == "ssh-ed25519" {print $2" "$3; exit}' || true)
      [ "$presented" = "$host_pub" ] && return 0
      if [ "$attempt" -lt 12 ]; then sleep 10; fi
    done
    return 1
  }
  if ! scan && [ -n "$presented" ]; then
    # The files hold the key but the daemon serves another: an earlier run swapped the file and
    # never got to the restart. Restart once, then look again.
    echo "   ${HOST}:${KEYSCAN_PORT} still serves another key; restarting sshd once to load the pinned one…"
    run_remote "sshd restart" "$hk" "sh -c '${hostkey_remote}' converge '${host_pub}' restart"
    scan || true
  fi
  if [ -z "$presented" ]; then
    echo "::error::${HOST}:${KEYSCAN_PORT} presented no ed25519 host key, so the pin cannot be confirmed."
    echo "::error::OpenSSH's tailnet listener is down or unreachable; strad's SSH slug will fail the same way."
    exit 1
  fi
  if [ "$presented" != "$host_pub" ]; then
    echo "::error::${HOST}:${KEYSCAN_PORT} presents $(printf '%s\n' "$presented" | ssh-keygen -l -f -), not the pinned key."
    exit 1
  fi
  echo "✅ ${HOST}:${KEYSCAN_PORT} presents the pinned host key $(ssh-keygen -l -f "$work/host.pub" | awk '{print $2}')"
fi

#!/usr/bin/env bash
# Choose the droplet size a staging `terraform apply` should ask for, and print it.
#
# DigitalOcean's stock is per size AND per region, and it moves: nyc3 sold `s-2vcpu-4gb` at
# 00:46 UTC on 2026-11-23 and refused it at 18:43 the same day, while still selling the AMD
# and Intel variants of the same 2 vCPU / 4 GB / 80 GB shape. Staging is torn down between
# uses, so most deploys create a droplet and are exposed to that. This asks the size
# catalog first and, when the preferred size is not sold in the region, takes the first
# acceptable fallback that is.
#
# THREE ANSWERS, depending on what the apply is about to do:
#
#   a droplet exists and is being kept   its CURRENT size, whatever the tfvars or the
#       fallbacks say. `size` is not ForceNew: a different value is an in-place resize,
#       which powers the box off and grows its disk for good. A redeploy over a droplet
#       that landed on a fallback must not "correct" it back.
#   a droplet is about to be created     the first size in (preferred, fallbacks...) that
#       the catalog sells in the region.
#   none of them is sold                 no answer: exit 1, naming every size and why. This
#       runs before the apply, so nothing has been created -- or, under RECREATE, destroyed.
#
# The size goes to stdout and everything else to stderr, so a caller can capture it. Pass
# it as `-var droplet_size=...` AFTER `-var-file`: a -var-file value beats TF_VAR_*, so
# exporting TF_VAR_droplet_size would silently change nothing.
#
# Run from the Terraform directory, after `terraform init`. Env:
#   DO_TOKEN         DigitalOcean API token
#   SIZE_FALLBACKS   space-separated size slugs, in order of preference
#   MIN_MEMORY_MB    smallest memory a FALLBACK may have. It may not be smaller than the
#                    preferred size either, when the catalog still lists that one.
#   RECREATE         "true" when the apply will -replace the droplet
#   TFVARS           tfvars file holding the preferred size and the region (staging.tfvars)
#   DO_API_URL       default https://api.digitalocean.com
set -euo pipefail

: "${DO_TOKEN:?DO_TOKEN must be set to a DigitalOcean API token}"
: "${SIZE_FALLBACKS:?SIZE_FALLBACKS must list at least one size slug}"
: "${MIN_MEMORY_MB:?MIN_MEMORY_MB must be set}"
RECREATE="${RECREATE:-false}"
TFVARS="${TFVARS:-staging.tfvars}"
DO_API_URL="${DO_API_URL:-https://api.digitalocean.com}"
DROPLET_ADDRESS="digitalocean_droplet.zimmer"

log() { echo "$*" >&2; }
die() {
  local line
  for line in "$@"; do log "::error::${line}"; done
  exit 1
}

tfvar() {
  local value
  value="$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" "$TFVARS")"
  if ! [[ "$value" =~ ^[a-z0-9_-]+$ ]]; then
    die "${TFVARS} must assign $1 exactly once, as a quoted slug (read '${value}')."
  fi
  printf '%s' "$value"
}

preferred="$(tfvar droplet_size)"
region="$(tfvar region)"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# `api_get <path>` -- response body into $body, HTTP status into $code (000 = no answer).
# The token goes through a file descriptor, so it is never on a command line.
code=""
api_get() {
  code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 20 --retry 3 --retry-delay 2 \
    -H @<(printf 'Authorization: Bearer %s' "$DO_TOKEN") \
    "${DO_API_URL}$1" || true)"
  code="${code:-000}"
}

# --- Is there a droplet, and is this apply going to keep it? --------------------------
#
# A tainted droplet is one Terraform will destroy and recreate, so it is not kept.
# The state is captured and never printed: it carries sensitive values.
if ! state="$(terraform show -json)"; then
  die "Could not read the staging Terraform state, so it is unknown whether a droplet exists."
fi
if ! droplet="$(jq -ce --arg a "$DROPLET_ADDRESS" \
  '[.values.root_module.resources[]? | select(.address == $a)
    | {id: (.values.id | tostring), tainted: (.tainted // false)}] | first // {}' <<<"$state")"; then
  die "Could not parse the staging Terraform state, so it is unknown whether a droplet exists."
fi
droplet_id="$(jq -r '.id // empty' <<<"$droplet")"
tainted="$(jq -r '.tainted // false' <<<"$droplet")"

if [ -n "$droplet_id" ] && [ "$RECREATE" != "true" ] && [ "$tainted" != "true" ]; then
  # The live size, not the one in state: a box resized out of band must not be resized
  # back either.
  api_get "/v2/droplets/${droplet_id}"
  case "$code" in
    200)
      current="$(jq -r '.droplet.size_slug // empty' < "$body")" || current=""
      if [ -z "$current" ]; then
        die "The staging droplet exists but DigitalOcean's answer carries no size, so this apply could resize it." \
            "Nothing was changed."
      fi
      log "✅ droplet_size: ${current} -- the size the existing staging droplet already has, kept as it is."
      printf '%s\n' "$current"
      exit 0
      ;;
    404)
      # Deleted out of band: Terraform's refresh drops it and the apply creates a new one.
      log "::warning::The staging droplet in Terraform state no longer exists at DigitalOcean, so this apply creates one."
      droplet_id=""
      ;;
    *)
      die "Could not read the existing staging droplet from DigitalOcean (HTTP ${code}), so its size is unknown" \
          "and this apply could resize it. Nothing was changed."
      ;;
  esac
fi

# --- A droplet is about to be created: what does the region sell? ---------------------
#
# The catalog is longer than one page (311 sizes against a 200-row limit on 2026-11-23),
# and a size on an unread page would look unavailable.
sizes="[]"
page=1
catalog_error=""
while :; do
  api_get "/v2/sizes?per_page=200&page=${page}"
  if [ "$code" != "200" ]; then
    catalog_error="HTTP ${code}"
    break
  fi
  # An empty page is as unreadable as a malformed one: jq reads `[] + null` as [], which
  # would report every size as retired.
  if ! sizes="$(jq -ce --argjson seen "$sizes" \
    'if (.sizes | type) == "array" and (.sizes | length) > 0 then $seen + .sizes else error("no sizes") end' \
    < "$body" 2>/dev/null)"; then
    catalog_error="an unreadable response"
    break
  fi
  if ! jq -e '.links.pages.next' < "$body" >/dev/null 2>&1; then
    break
  fi
  page=$((page + 1))
  if [ "$page" -gt 20 ]; then
    catalog_error="more than 20 pages"
    break
  fi
done

if [ -n "$catalog_error" ]; then
  if [ -n "$droplet_id" ]; then
    die "Could not read DigitalOcean's size catalog (${catalog_error}), so it is unknown whether a replacement" \
        "droplet can be created. Refusing to destroy the existing staging droplet first."
  fi
  # Nothing to lose: ask for the preferred size, and let a refusal fail the apply.
  log "::warning::Could not read DigitalOcean's size catalog (${catalog_error}), so no fallback was considered:"
  log "::warning::asking for the preferred size, ${preferred}. If ${region} is not selling it, the apply fails."
  printf '%s\n' "$preferred"
  exit 0
fi

# memory_of <slug> -- MB, or empty when the catalog does not list the size at all.
memory_of() {
  jq -r --arg s "$1" '[.[] | select(.slug == $s) | .memory] | first // empty' <<<"$sizes"
}

floor="$MIN_MEMORY_MB"
preferred_memory="$(memory_of "$preferred")"
if [ -n "$preferred_memory" ] && [ "$preferred_memory" -gt "$floor" ]; then
  floor="$preferred_memory"
fi

rejected=()
read -ra fallbacks <<<"$SIZE_FALLBACKS"
for size in "$preferred" "${fallbacks[@]}"; do
  memory="$(memory_of "$size")"
  if [ -z "$memory" ]; then
    rejected+=("${size}: not in DigitalOcean's catalog")
  elif [ "$size" != "$preferred" ] && [ "$memory" -lt "$floor" ]; then
    rejected+=("${size}: ${memory} MB is below the ${floor} MB staging needs")
  elif ! jq -e --arg s "$size" --arg r "$region" \
      'any(.[]; .slug == $s and .available and any(.regions[]; . == $r))' <<<"$sizes" >/dev/null; then
    rejected+=("${size}: not sold in ${region} right now")
  else
    if [ "$size" = "$preferred" ]; then
      log "✅ droplet_size: ${size} -- the preferred size, sold in ${region}."
    else
      log "::warning::DigitalOcean is not selling the preferred staging size in ${region}, so this droplet is ${size} (${memory} MB)."
      for reason in "${rejected[@]}"; do log "::warning::  ${reason}"; done
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "**Droplet size** — fell back to \`${size}\`: DigitalOcean is not selling \`${preferred}\` in ${region}." \
          >> "$GITHUB_STEP_SUMMARY"
      fi
    fi
    printf '%s\n' "$size"
    exit 0
  fi
done

die "DigitalOcean sells no acceptable staging droplet size in ${region} right now, so the droplet cannot be created:" \
    "${rejected[@]/#/  }" \
    "Nothing was created or destroyed. Retry once one is sold again, or add an equivalent size to SIZE_FALLBACKS in" \
    "deploy-staging.yml. What a region sells: GET /v2/sizes, or \`doctl compute size list\`."

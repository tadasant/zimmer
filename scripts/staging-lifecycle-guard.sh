#!/usr/bin/env bash
# Decide whether a SCHEDULED staging-lifecycle job should do anything today.
#
# Two workflows run on a cron against a droplet that may not exist:
#
#   teardown-staging.yml   destroys the droplet on the nights nobody used it, so a
#                          $24/month box is not billed round the clock between the
#                          handful of days staging is actually deployed to.
#   domain-cert-staging.yml  upserts `staging.zimmer.tadasant.com -> tailnet IP` and
#                          pushes a renewed cert ONTO the box.
#
# Neither has anything to do when staging is already down, and "nothing to do" must
# come out GREEN. `alert-ci-failure.yml` pages #alerts on every main-branch workflow
# failure, so a cron job that reddens on the nights staging is absent would page for
# no reason -- nightly, forever, which is how an alert channel gets ignored.
#
# Usage: staging-lifecycle-guard.sh <teardown|cert>
#
# Writes to $GITHUB_OUTPUT, and prints the same thing for whoever reads the log:
#   proceed=true|false   the whole answer -- gate the job on it
#   droplet=present|absent
#   reason=<one sentence>
# Exit 0 whenever it reached an answer, including "no, skip". A non-zero exit means it
# could NOT answer (the Terraform backend refused), which is a real failure and should
# page.
#
# Env:
#   RECENT_DEPLOY_HOURS  required in `teardown` mode. Suppress the teardown when a
#                        `Deploy staging` run succeeded this recently. Set it in the
#                        WORKFLOW, next to the cron -- the cadence and the window are
#                        one decision and belong in one place.
#   TF_DIR               Terraform directory (default infra/terraform)
#   TF_BACKEND_CONFIG    partial backend config (default backend.staging.hcl)
#   DROPLET_ADDRESS      state address to look for (default digitalocean_droplet.zimmer)
#   DEPLOY_WORKFLOW      workflow file whose successes count (default deploy-staging.yml)
#   GH_TOKEN/GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_API_URL, GITHUB_OUTPUT
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  Spaces keys that open the remote state
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  teardown|cert) ;;
  *)
    echo "::error::usage: staging-lifecycle-guard.sh <teardown|cert> (got '${MODE}')"
    exit 2
    ;;
esac

TF_DIR="${TF_DIR:-infra/terraform}"
TF_BACKEND_CONFIG="${TF_BACKEND_CONFIG:-backend.staging.hcl}"
DROPLET_ADDRESS="${DROPLET_ADDRESS:-digitalocean_droplet.zimmer}"
DEPLOY_WORKFLOW="${DEPLOY_WORKFLOW:-deploy-staging.yml}"

if [ -z "${GITHUB_OUTPUT:-}" ]; then
  # Without it nothing consumes the decision and every gated step reads `proceed == ''`,
  # which is a silent "skip everything" -- refuse rather than decide into the void.
  echo "::error::GITHUB_OUTPUT is not set, so nothing would consume this decision."
  exit 2
fi

# `decide <proceed> <droplet> <reason...>` -- the single exit through which every answer
# leaves, so no branch can forget one of the three outputs.
decide() {
  local proceed="$1" droplet="$2"
  shift 2
  local reason="$*"
  {
    echo "proceed=${proceed}"
    echo "droplet=${droplet}"
    echo "reason=${reason}"
  } >> "$GITHUB_OUTPUT"
  if [ "$proceed" = "true" ]; then
    echo "▶️  Proceeding: ${reason}"
  else
    echo "⏭️  Skipping: ${reason}"
  fi
  exit 0
}

# A fork or a fresh self-host that never configured staging has no Spaces keys, so
# `terraform init` against the remote backend would die -- nightly, on a cron nobody
# there turned on. Same posture as tailnet-reap-node.sh: skip loudly, never fail over a
# credential this repository's owner never set.
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "::warning::No Spaces credentials (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY), so the staging"
  echo "::warning::Terraform state cannot be read and this schedule has nothing to act on."
  decide false unknown "staging is not configured in this repository (no remote-state credentials)"
fi

# --- Is there a droplet? ------------------------------------------------------------
#
# Terraform state, not the DigitalOcean API: state is what `terraform destroy` acts on,
# so "state manages no droplet" is exactly, and not merely approximately, "destroy would
# do nothing". Reading it also proves the backend is reachable before the destroy job
# commits a runner to it.
if ! init_log=$(terraform -chdir="$TF_DIR" init -input=false -backend-config="$TF_BACKEND_CONFIG" 2>&1); then
  echo "$init_log"
  echo "::error::Could not initialize the staging Terraform backend, so it is unknown whether a"
  echo "::error::droplet exists. This is a backend/credentials problem, not an empty environment:"
  echo "::error::failing rather than guessing, because guessing 'absent' would silently stop the"
  echo "::error::teardown from ever running again."
  exit 1
fi

if ! state_log=$(terraform -chdir="$TF_DIR" state list 2>&1); then
  # An environment that has never been applied has no state object at all. That is the
  # ordinary "staging is down" case, not an error -- but Terraform reports it on stderr
  # with a non-zero status, so it has to be told apart from a broken backend here.
  if printf '%s' "$state_log" | grep -qi 'no state file was found'; then
    state_log=""
  else
    echo "$state_log"
    echo "::error::Could not read the staging Terraform state, so it is unknown whether a droplet exists."
    exit 1
  fi
fi

if printf '%s\n' "$state_log" | grep -qxF "$DROPLET_ADDRESS"; then
  droplet=present
else
  droplet=absent
fi

if [ "$droplet" = "absent" ]; then
  if [ "$MODE" = "cert" ]; then
    # Not a problem to fix: with no droplet there is no tailnet IP to point the A record
    # at and no box to push a cert to. The cert re-issues on its own -- deploy-staging
    # chains this workflow after a fresh droplet comes up.
    decide false absent "no droplet in Terraform state, so there is no box to point DNS at or push a cert to"
  fi
  decide false absent "no droplet in Terraform state, so there is nothing to destroy"
fi

if [ "$MODE" = "cert" ]; then
  decide true present "the staging droplet exists, so DNS and the cert have a target"
fi

# --- Was staging deployed to recently? ----------------------------------------------
hours="${RECENT_DEPLOY_HOURS:-}"
case "$hours" in
  ''|*[!0-9]*)
    echo "::error::RECENT_DEPLOY_HOURS must be a positive integer of hours (got '${hours}')."
    echo "::error::It is set in teardown-staging.yml, next to the cron."
    exit 2
    ;;
esac
if [ "$hours" -lt 1 ]; then
  echo "::error::RECENT_DEPLOY_HOURS must be a positive integer of hours (got '${hours}')."
  exit 2
fi

api_url="${GITHUB_API_URL:-https://api.github.com}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set to owner/name}"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

auth=()
if [ -n "$token" ]; then
  auth=(-H "Authorization: Bearer ${token}")
fi

body="$(mktemp)"
# shellcheck disable=SC2064  # expand the path now, not at trap time
trap "rm -f '${body}'" EXIT

# `status=success` filters on the CONCLUSION; per_page=1 takes the newest, since the runs
# API sorts newest-first. A deploy dispatched from any branch counts -- every one of them
# stands the same droplet up.
code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 20 \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  ${auth[@]+"${auth[@]}"} \
  "${api_url}/repos/${repo}/actions/workflows/${DEPLOY_WORKFLOW}/runs?status=success&per_page=1" \
  2>/dev/null || true)"
code="${code:-000}"

# Every unreadable-answer path below lands on the SAME verdict: do not destroy. The two
# mistakes are not symmetric -- keeping a droplet nobody wanted costs about $0.80 for the
# day, and destroying one somebody is working on costs them a cold rebuild. Silence from
# the API means "unknown", and the safe reading of unknown is "in use".
if [ "$code" != "200" ]; then
  echo "::warning::The GitHub API answered ${code} when asked for the last successful ${DEPLOY_WORKFLOW} run,"
  echo "::warning::so it is unknown whether staging was deployed to recently. Keeping the droplet."
  decide false present "could not read ${DEPLOY_WORKFLOW} history (HTTP ${code}), so staging is assumed to be in use"
fi

last="$(jq -r '.workflow_runs[0].updated_at // empty' < "$body" 2>/dev/null || true)"

if [ -z "$last" ]; then
  # No successful deploy has ever been recorded, yet a droplet exists. Nothing is
  # protecting it, so tear it down -- that is the case this whole feature is for.
  decide true present "no successful ${DEPLOY_WORKFLOW} run on record, so nothing is holding the droplet"
fi

if ! last_epoch="$(date -u -d "$last" +%s 2>/dev/null)"; then
  echo "::warning::Could not parse '${last}' as a timestamp. Keeping the droplet."
  decide false present "could not read the last deploy's timestamp, so staging is assumed to be in use"
fi

now_epoch="$(date -u +%s)"
age_hours=$(( (now_epoch - last_epoch) / 3600 ))

if [ "$age_hours" -lt "$hours" ]; then
  decide false present "Deploy staging succeeded ${age_hours}h ago, within the ${hours}h window, so staging is in use"
fi

decide true present "the last successful Deploy staging was ${age_hours}h ago, past the ${hours}h window"

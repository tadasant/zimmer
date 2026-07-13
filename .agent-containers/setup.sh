#!/usr/bin/env bash
# One-time (idempotent) setup for a containerized Zimmer instance.
#
# Mirrors bin/setup, minus the `exec bin/dev` at the end — the dev server is
# started separately by run.sh so we can background its processes cleanly.
# Run this INSIDE the app container (ac.sh does this for you):
#   docker compose -f .agent-containers/docker-compose.dev.yml exec app .agent-containers/setup.sh
set -euo pipefail

cd /app

echo "== Installing dependencies (bundle) =="
# Gems install to the image's /usr/local/bundle: the ruby base image sets
# BUNDLE_APP_CONFIG/BUNDLE_PATH there, overriding the repo's .bundle/config. That
# deliberately keeps container-built native gems out of the mounted vendor/bundle
# (see README.md "Design notes"). They persist across restarts, not rebuilds.
bundle check || bundle install

echo "== Preparing databases (db:prepare) =="
# Creates + migrates both zimmer_development and zimmer_development_cable.
bin/rails db:prepare

echo "== Clearing old logs and tempfiles =="
bin/rails log:clear tmp:clear

echo "== Setup complete =="

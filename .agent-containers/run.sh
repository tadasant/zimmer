#!/usr/bin/env bash
# Start the Zimmer dev server INSIDE the app container.
#
# We deliberately do NOT use foreman/bin/dev here: foreman doesn't play well with
# nohup (it forwards signals to the whole process group and tears itself down when
# the launching shell exits). Instead we start each Procfile.dev process directly
# under nohup, logging to /app/.logs/, so they survive the `docker compose exec`
# shell that launched them.
#
# Procfile.dev defines exactly two processes; GoodJob runs :async in-process, so
# there is no separate worker to start.
#   web: bin/rails server
#   css: bin/rails tailwindcss:watch (in a restart loop)
set -euo pipefail

cd /app

mkdir -p .logs tmp/pids

PORT="${PORT:-3000}"

# If a server is already listening on the port, don't start a second one — a
# duplicate `bin/rails server` would just crash with EADDRINUSE. This makes
# re-running run.sh a no-op for the web process instead of a confusing failure.
if curl -fsS "http://localhost:${PORT}/up" >/dev/null 2>&1; then
  echo "web already serving on :${PORT} — nothing to do."
  exit 0
fi

# Rails refuses to boot if a stale server pid is present (e.g. after an unclean
# container restart). Safe to clear now that we know nothing is up.
rm -f tmp/pids/server.pid

echo "Starting web (Rails server) on 0.0.0.0:${PORT} → .logs/app.log"
nohup bin/rails server -b 0.0.0.0 -p "${PORT}" > .logs/app.log 2>&1 &

echo "Starting css (Tailwind watcher) → .logs/css.log"
nohup bash -c 'while true; do bin/rails tailwindcss:watch || sleep 5; done' > .logs/css.log 2>&1 &

echo "Dev server processes launched. Tail logs with:"
echo "  docker compose -f .agent-containers/docker-compose.dev.yml exec app tail -f /app/.logs/app.log"

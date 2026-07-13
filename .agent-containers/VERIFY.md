# Verifying the containerized dev environment

A playbook for confirming `.agent-containers/` actually boots a working Zimmer.
Run these from the repo root on a host with Docker (with the compose plugin).

## 1. Infrastructure checks (shell)

```bash
# a. Build + start the stack, pinning the host port so the checks are copy-paste.
APP_PORT=3000 docker compose -f .agent-containers/docker-compose.dev.yml up -d --build

# b. db and redis report healthy (app has no compose healthcheck; we test it via /up).
docker compose -f .agent-containers/docker-compose.dev.yml ps

# c. One-time prepare: bundle install + create/migrate both databases.
docker compose -f .agent-containers/docker-compose.dev.yml exec app .agent-containers/setup.sh

# d. Both databases exist (zimmer_development + zimmer_development_cable).
docker compose -f .agent-containers/docker-compose.dev.yml exec db \
  psql -U app -d zimmer_development -c '\l' | grep zimmer_development

# e. Start the dev server (web + css, backgrounded).
docker compose -f .agent-containers/docker-compose.dev.yml exec app .agent-containers/run.sh

# f. The health endpoint returns 200 (retry for a few seconds while Puma boots).
for i in $(seq 1 30); do
  curl -fsS http://localhost:3000/up >/dev/null 2>&1 && { echo "UP"; break; }
  sleep 2
done
curl -sI http://localhost:3000/up | head -1     # expect: HTTP/1.1 200 OK

# g. Redis is reachable from inside the app container.
docker compose -f .agent-containers/docker-compose.dev.yml exec app \
  ruby -e "require 'redis'; puts Redis.new(url: ENV['REDIS_URL']).ping"   # → PONG
```

Expected results:

- (b) `db` and `redis` show `(healthy)`.
- (d) grep finds `zimmer_development` and `zimmer_development_cable`.
- (f) `/up` returns `HTTP/1.1 200 OK`.
- (g) prints `PONG`.

## 2. `ac.sh` checks (parallel isolation)

```bash
.agent-containers/ac.sh clone verify-a      # boots an isolated stack + tmux/agent
.agent-containers/ac.sh status              # lists sessions with port + health
.agent-containers/ac.sh status verify-a     # shows ok health + a URL
.agent-containers/ac.sh destroy verify-a    # tears down, -v, removes the clone
```

Expected: `status` shows the session `running` with health `ok`; a second
`clone verify-b` gets a **different** host port; `destroy` removes the containers,
the `postgres_data` volume, and the clone directory.

## 3. Browser checks

With a stack up on a known port (`APP_PORT=3000` above, or the port from
`ac.sh status`):

1. Open `http://localhost:<port>/` — the Zimmer sessions dashboard renders with
   Tailwind styles applied (proves the `css` watcher built the stylesheet).
2. Open `http://localhost:<port>/up` — a bare `200`.

## 4. Teardown

```bash
docker compose -f .agent-containers/docker-compose.dev.yml down -v
```

Confirm the named volume is gone:

```bash
docker volume ls | grep zimmer-dev-local_postgres_data || echo "volume removed"
```

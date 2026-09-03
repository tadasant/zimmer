# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t zimmer .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name zimmer zimmer

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Use pre-built base image with heavy dependencies (Node.js, Playwright, gh CLI)
# This dramatically speeds up production builds by caching slow-to-build dependencies.
#
# Nobody has to remember to rebuild the base when Dockerfile.base changes:
# .github/workflows/release-image.yml content-addresses it, and builds and pushes
# `zimmer-base:content-<key>` before the app image whenever the declaration is one it
# has never published. It then passes that exact tag as BASE_IMAGE, so the default
# below is never what a released image is built from — it is for a hand-run
# `docker build` and for await-ghcr.sh's probe. `build-base-image.yml` is the separate
# refresh path for fixes that arrive with no repo input changing (base-OS patches, the
# unpinned installers); it is not on the release path.
ARG BASE_IMAGE=ghcr.io/tadasant/zimmer-base:latest
FROM ${BASE_IMAGE} AS base

# Set production environment (inherited from base but explicitly set for clarity)
# Note: BUNDLE_DEPLOYMENT is NOT set here to allow bundle install in agent clones
# The production app uses gems from /usr/local/bundle, but clones can install
# their own gems to vendor/bundle without conflicts
ENV RAILS_ENV="production" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Throw-away build stage to reduce size of final image
# Gems are already installed in the base image, so we just copy app code and precompile
FROM base AS build

# Copy application code
COPY . .

# Install any new gems that aren't in the base image
# This handles the case where Gemfile was updated but base image hasn't been rebuilt yet
RUN bundle install --jobs 4

# Note: We skip 'bootsnap precompile app/ lib/' here because:
# 1. The gems are already precompiled in the base image
# 2. Bootsnap will lazily compile app code on first boot with minimal impact

# Precompile assets (Tailwind CSS)
# Use dummy secret key base to allow asset compilation without real credentials
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage for app image
# Base image already has: Node.js, npm, gh CLI, Claude Code CLI (native), Playwright, Fly.io CLI, rails user
FROM base

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# The documentation site must never ship inside this image. It is single-source: the one
# copy that exists is docs/ in this repo, built by Cloudflare Pages. A second copy riding
# along here would be one nobody deploys, nobody reads, and nobody keeps true.
#
# Keeping it out rests entirely on a single `/docs` line in .dockerignore standing in
# front of the blanket `COPY . .` in the build stage above -- reorganize that file, or
# move the docs to another path, and the second copy comes back with no signal. This
# asserts the outcome against the image's own filesystem instead of trusting that line,
# and it runs during the BUILD, so an image carrying the docs is never pushed.
RUN /rails/scripts/assert-docs-excluded.sh --root /rails

# Fix ownership of runtime directories for the rails user (user already exists in base)
RUN mkdir -p db log storage tmp && chown -R rails:rails db log storage tmp

# Create shared storage directories with correct ownership before volume mount.
# When Docker mounts an empty named volume over these directories, it copies the
# ownership from the container's directory to the volume.
RUN mkdir -p /tmp/agent-orchestrator-images /tmp/agent-orchestrator-files && \
    chown rails:rails /tmp/agent-orchestrator-images /tmp/agent-orchestrator-files && \
    chmod 755 /tmp/agent-orchestrator-images /tmp/agent-orchestrator-files

# Create the DURABLE volume mountpoints, owned by rails (uid 1000), BEFORE the
# volumes are mounted over them.
#
# Docker only seeds a fresh named volume with the image directory's ownership when
# that mountpoint already EXISTS in the image. The base image creates ~/.config and
# ~/.codex (the latter already rails-owned, which is what lets the codex_home volume
# come up writable) but NOT ~/.zimmer, ~/.config/gh, ~/.claude, or ~/.local -- so those
# volumes would come up root:root and uid 1000 could not write them. Every agent
# session would then fail to clone (and `gh auth` would fail) while /up still
# returned 200 -- a silent failure the health check cannot see.
#
# The pre-Kamal cloud-init worked around this with a `docker compose run … chown`
# step before `up -d`. Kamal has no equivalent hook in the deploy path, so the fix
# belongs in the image, where it also survives a volume being recreated.
RUN mkdir -p /home/rails/.zimmer /home/rails/.claude /home/rails/.config/gh /home/rails/.local && \
    chown rails:rails /home/rails/.zimmer /home/rails/.claude /home/rails/.config/gh /home/rails/.local

# Kamal refuses to deploy an image that does not carry a `service` label matching
# its configured service name -- it normally stamps this on during its own build,
# but Zimmer's images are built by CI (docker/build-push-action), so we set it here.
# Applies to every image we publish, which is what production's Kamal cutover needs
# too.
LABEL service="zimmer"

# Switch to non-root user for security
USER 1000:1000

# HOME is a property of this image's app user, not of the uid a container happens to
# be STARTED as -- so pin it here rather than letting Docker derive it.
#
# Docker resolves HOME from `--user` against /etc/passwd. Left implicit, uid 1000 gets
# /home/rails and everything is fine; but the worker role runs `user: "0:0"` when nested
# Docker is armed (it needs container-root to bring up dockerd), and uid 0 resolves to
# /root. That /root then IS the container's environment, and three things inherit it:
#
#   - PID 1. Every role sets `init: true`, so PID 1 is docker-init, which never runs
#     bin/docker-entrypoint and so never sees the entrypoint's fixup below.
#   - Every `docker exec` into the container -- Docker builds an exec's environment from
#     the container config, never from PID 1's. That includes `docker exec -u 1000:1000`,
#     the shape an operator debugging a session uses, where /root is mode 0700 and
#     root-owned: not traversable, not writable.
#
# The value is hardcoded here while bin/docker-entrypoint reads it from /etc/passwd. It
# has to match Dockerfile.base's `useradd rails --uid 1000 --create-home`, and for the
# `web` role -- which starts as uid 1000, so the entrypoint's root branch never runs --
# this ENV is the only thing setting it.
#
# What lands at /home/rails is not incidental: libpq probes $HOME/.postgresql/postgresql.crt
# on every TLS connection and treats EACCES (unlike ENOENT) as fatal, and ~/.claude,
# ~/.config/gh, ~/.local and ~/.zimmer are the Kamal volumes agent sessions live out of.
# Pointed at /root they are absent. That combination is the 2026-08-13 ten-hour freeze.
#
# bin/docker-entrypoint still derives HOME from /etc/passwd and proves it writable before
# dropping to uid 1000. This does not replace that -- the entrypoint covers the app process
# and refuses to boot when the home directory is unusable, which no ENV can check. This
# covers everything that never runs the entrypoint.
ENV HOME=/home/rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]

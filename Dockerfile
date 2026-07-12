# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t agent_orchestrator .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name agent_orchestrator agent_orchestrator

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Use pre-built base image with heavy dependencies (Node.js, Playwright, gh CLI)
# This dramatically speeds up production builds by caching slow-to-build dependencies.
# To (re)build the base image, run the "Build base image" workflow
# (.github/workflows/build-base-image.yml), which publishes zimmer-base from
# Dockerfile.base. It must be published once before the first app image build.
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
# ~/.codex but NOT ~/.zimmer, ~/.config/gh, ~/.claude, or ~/.local -- so those
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

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]

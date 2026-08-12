# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Docker socket access for the worker role is TWO things, and each is useless alone: the
# socket mount, and membership in the group that owns it. The socket is
# `srw-rw---- root:docker` and Zimmer's image runs as uid/gid 1000, so a mount without
# `group-add` yields `permission denied` on every call.
#
# That is not hypothetical. Zimmer inherited the mount and DockerCleanupJob from its
# ancestor at extraction but not the group line, and the pair stayed half-wired for
# Zimmer's whole history: the job shells out to `docker ps`, treats the permission denial
# as a non-zero status, and returns "nothing to reap" without logging. Nothing failed
# loudly, so nothing got noticed.
#
# These assertions are the thing that would have caught it. A future edit that drops
# either half fails here instead of silently disabling every Docker-dependent feature.
class WorkerDockerGroupTest < ActiveSupport::TestCase
  DESTINATIONS = {
    "production" => { deploy: "config/deploy.production.yml", host_env: "PRODUCTION_HOST" },
    "staging" => { deploy: "config/deploy.staging.yml", host_env: "STAGING_HOST" }
  }.freeze

  # The `docker` group's GID on Zimmer's droplets, verified on the host. Deliberately a
  # DEFAULT and not a constant in the deploy files: Debian/Ubuntu assign this from the
  # dynamic system range, so a self-hoster's will differ and has to be overridable.
  EXPECTED_DEFAULT_GID = "988"

  RENDER_ENV = {
    "PRODUCTION_HOST" => "198.51.100.10",
    "STAGING_HOST" => "198.51.100.11",
    "PRODUCTION_DB_HOST" => "managed-db.example.internal"
  }.freeze

  def deploy_config(destination, docker_gid: nil)
    path = Rails.root.join(DESTINATIONS.fetch(destination)[:deploy])
    overrides = RENDER_ENV.merge(docker_gid ? { "DOCKER_GID" => docker_gid } : {})
    keys = overrides.keys | [ "DOCKER_GID" ]

    previous = ENV.to_h.slice(*keys)
    keys.each { |key| ENV.delete(key) }
    ENV.update(overrides)
    YAML.safe_load(ERB.new(path.read).result, aliases: true)
  ensure
    keys.each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  def worker_options(destination, **)
    deploy_config(destination, **).dig("servers", "worker", "options")
  end

  DESTINATIONS.each_key do |destination|
    test "#{destination}'s worker mounts the Docker socket" do
      volumes = worker_options(destination)["volume"]

      assert_includes volumes, "/var/run/docker.sock:/var/run/docker.sock"
    end

    test "#{destination}'s worker joins the Docker socket's group, without which the mount is inert" do
      group_add = worker_options(destination)["group-add"]

      assert group_add, "config/deploy.#{destination}.yml's worker mounts the Docker socket but " \
        "adds no `group-add`, so every docker call from it is permission-denied"
      assert_equal EXPECTED_DEFAULT_GID, group_add.to_s
    end

    test "#{destination}'s DOCKER_GID is overridable for hosts whose docker group differs" do
      group_add = worker_options(destination, docker_gid: "999")["group-add"]

      assert_equal "999", group_add.to_s,
        "the GID is hardcoded; a self-hoster whose docker group is not #{EXPECTED_DEFAULT_GID} " \
        "would have no way to correct it"
    end

    # The web role serves HTTP and runs no agent sessions. Socket access there would widen
    # the blast radius to the internet-facing process for no benefit.
    test "#{destination} does not extend Docker access to the web role" do
      web_options = deploy_config(destination).dig("servers", "web", "options")

      assert_nil web_options["group-add"], "the web role does not run agent sessions and has no " \
        "reason to hold root-equivalent access to the host"
      refute_includes Array(web_options["volume"]), "/var/run/docker.sock:/var/run/docker.sock"
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Docker socket access for the worker role is TWO things, and each is useless alone: the
# socket mount, and membership in the group that owns it. The socket is
# `srw-rw---- root:docker` and Zimmer's image runs as uid/gid 1000, so a mount without
# `group-add` yields `permission denied` on every call.
#
# The pair is easy to break by halves and hard to notice broken. `DockerCleanupJob`'s
# discovery step does `return [] unless SubprocessStatus.success?(status)` and logs
# nothing, so a permission denial there is indistinguishable from "no stale stacks" --
# the whole job looks like it ran and found nothing to do. (Its prune steps do warn, so
# that half at least leaves a trace.)
#
# These assertions are what makes dropping either half fail here instead.
class WorkerDockerGroupTest < ActiveSupport::TestCase
  DESTINATIONS = %w[production staging].freeze

  # The `docker` group's GID on Zimmer's droplets, read off each host. Deliberately a
  # DEFAULT and not a constant in the deploy files: Debian/Ubuntu allocate this from the
  # dynamic system range, so a self-hoster's will differ and has to be overridable.
  EXPECTED_DEFAULT_GID = "988"

  SOCKET_MOUNT = "/var/run/docker.sock:/var/run/docker.sock"

  # Rendering with the host vars unset yields nils, which parse fine -- the sibling
  # deploy-config tests rely on the same thing. Only DOCKER_GID needs controlling here.
  def deploy_config(destination, docker_gid: nil)
    path = Rails.root.join("config/deploy.#{destination}.yml")

    had_gid = ENV.key?("DOCKER_GID")
    previous = ENV["DOCKER_GID"]
    docker_gid.nil? ? ENV.delete("DOCKER_GID") : ENV["DOCKER_GID"] = docker_gid
    YAML.safe_load(ERB.new(path.read).result, aliases: true)
  ensure
    had_gid ? ENV["DOCKER_GID"] = previous : ENV.delete("DOCKER_GID")
  end

  def worker_options(destination, **)
    deploy_config(destination, **).dig("servers", "worker", "options")
  end

  DESTINATIONS.each do |destination|
    test "#{destination}'s worker mounts the Docker socket" do
      assert_includes worker_options(destination)["volume"], SOCKET_MOUNT
    end

    test "#{destination}'s worker joins the Docker socket's group, without which the mount is inert" do
      group_add = worker_options(destination)["group-add"]

      assert group_add, "config/deploy.#{destination}.yml's worker mounts the Docker socket but " \
        "adds no `group-add`, so every docker call from it is permission-denied"
      assert_equal EXPECTED_DEFAULT_GID, group_add
    end

    test "#{destination}'s DOCKER_GID is overridable for hosts whose docker group differs" do
      assert_equal "999", worker_options(destination, docker_gid: "999")["group-add"],
        "the GID is hardcoded; a self-hoster whose docker group is not #{EXPECTED_DEFAULT_GID} " \
        "would have no way to correct it"
    end

    # A CI `env:` block hands an UNSET variable to the process as an EMPTY STRING, and a
    # default only applies to an absent key -- so `ENV.fetch("DOCKER_GID", "988")` would
    # yield "" here and render `--group-add ""`. Adding DOCKER_GID to a deploy workflow's
    # env allowlist would then break the very thing it was added to make configurable.
    test "#{destination} falls back to the default when DOCKER_GID arrives empty rather than absent" do
      assert_equal EXPECTED_DEFAULT_GID, worker_options(destination, docker_gid: "")["group-add"]
      assert_equal EXPECTED_DEFAULT_GID, worker_options(destination, docker_gid: "  ")["group-add"]
    end

    # The web role serves HTTP and runs no agent sessions. Socket access there would widen
    # the blast radius to the internet-facing process for no benefit.
    test "#{destination} does not extend Docker access to the web role" do
      web_options = deploy_config(destination).dig("servers", "web", "options")

      assert_nil web_options["group-add"], "the web role does not run agent sessions and has no " \
        "reason to hold root-equivalent access to the host"
      refute_includes Array(web_options["volume"]), SOCKET_MOUNT
    end

    # Everything above asserts the YAML. This asserts the DOCKER FLAG, which is the thing
    # that actually decides whether the container can reach the socket. Kamal turns
    # `options` into flags by emitting `--#{key}` verbatim and validates nothing, so
    # `group_add:` (underscore) would parse, serialize and read correctly in every
    # assertion above while producing `--group_add` -- a flag docker does not have.
    # It also sees the base/destination merge, which parsing one file cannot.
    test "#{destination} emits a --group-add flag docker will accept" do
      args = kamal_worker_option_args(destination)
      index = args.index("--group-add")

      assert index, "Kamal emits no --group-add for the worker; the flag name in " \
        "config/deploy.#{destination}.yml is probably not `group-add`. Emitted: #{args.inspect}"
      assert_equal %("#{EXPECTED_DEFAULT_GID}"), args[index + 1]
      assert_includes args, %("#{SOCKET_MOUNT}")
    end
  end

  private

  # Kamal resolves the destination file relative to the base one and needs a Pathname
  # (it calls #sub_ext), a version, and registry credentials before it will build a
  # configuration at all.
  def kamal_worker_option_args(destination)
    require "kamal"

    stub = {
      "KAMAL_REGISTRY_USERNAME" => "test", "KAMAL_REGISTRY_PASSWORD" => "test",
      "PRODUCTION_HOST" => "198.51.100.10", "STAGING_HOST" => "198.51.100.11",
      "PRODUCTION_DB_HOST" => "managed-db.example.internal"
    }
    previous = ENV.to_h.slice(*stub.keys)
    ENV.update(stub)

    Kamal::Configuration.create_from(
      config_file: Rails.root.join("config/deploy.yml"),
      destination: destination,
      version: "test"
    ).role("worker").option_args
  ensure
    stub.each_key { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end
end

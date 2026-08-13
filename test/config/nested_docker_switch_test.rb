# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Nested Docker is three settings that are only safe together: the sysbox runtime (which
# gives the container a user namespace), starting as container-root (so the entrypoint can
# bring up dockerd), and the env var the entrypoint reads. Any two without the third is a
# failure mode rather than a degraded mode -- most sharply runtime-without-user, which
# starts a container whose root is REAL host root and hands every agent session the host.
#
# So one variable arms all three, and these assertions are what keeps that true. They also
# pin the default: unset, the worker is exactly what it was before this existed.
class NestedDockerSwitchTest < ActiveSupport::TestCase
  DESTINATIONS = %w[production staging].freeze

  RENDER_ENV = {
    "PRODUCTION_HOST" => "198.51.100.10",
    "STAGING_HOST" => "198.51.100.11",
    "PRODUCTION_DB_HOST" => "managed-db.example.internal"
  }.freeze

  def deploy_config(destination, nested: nil)
    path = Rails.root.join("config/deploy.#{destination}.yml")
    overrides = RENDER_ENV.merge(nested ? { "ZIMMER_NESTED_DOCKER" => nested } : {})
    keys = overrides.keys | [ "ZIMMER_NESTED_DOCKER" ]

    previous = ENV.to_h.slice(*keys)
    keys.each { |k| ENV.delete(k) }
    ENV.update(overrides)
    YAML.safe_load(ERB.new(path.read).result, aliases: true)
  ensure
    keys.each { |k| previous.key?(k) ? ENV[k] = previous[k] : ENV.delete(k) }
  end

  DESTINATIONS.each do |destination|
    test "#{destination}'s worker is unchanged when the switch is unset" do
      config = deploy_config(destination)
      options = config.dig("servers", "worker", "options")

      assert_equal "runc", options["runtime"]
      assert_equal "1000:1000", options["user"]
      assert_equal "0", config.dig("env", "clear", "ZIMMER_NESTED_DOCKER")
    end

    test "#{destination}'s worker arms all three settings together when the switch is on" do
      config = deploy_config(destination, nested: "1")
      options = config.dig("servers", "worker", "options")

      assert_equal "sysbox-runc", options["runtime"],
        "without the sysbox runtime the container has no user namespace"
      assert_equal "0:0", options["user"],
        "without container-root the entrypoint cannot start dockerd"
      assert_equal "1", config.dig("env", "clear", "ZIMMER_NESTED_DOCKER"),
        "without the env var the entrypoint never starts dockerd"
    end

    # YAML reads a bare `0:0` as a sexagesimal integer and yields 0 -- uid 0 with the
    # image's default gid. Close enough to look right, and wrong in a way nothing reports.
    test "#{destination}'s worker user stays a string rather than a sexagesimal integer" do
      user = deploy_config(destination, nested: "1").dig("servers", "worker", "options", "user")

      assert_kind_of String, user, "user parsed as #{user.class} (#{user.inspect}); quote it"
    end

    # The host socket is what nested Docker exists to avoid needing. Mounting it back would
    # reintroduce exactly the root-equivalent exposure, and silently.
    test "#{destination}'s worker does not mount the host Docker socket" do
      %w[0 1].each do |state|
        volumes = Array(deploy_config(destination, nested: state).dig("servers", "worker", "options", "volume"))

        refute volumes.any? { |v| v.include?("/var/run/docker.sock") },
          "the worker mounts the host Docker socket (switch=#{state}); nested Docker exists so it does not have to"
      end
    end

    # web serves HTTP and runs no agent sessions. It should never gain either half.
    test "#{destination} never extends nested Docker to the web role" do
      web = deploy_config(destination, nested: "1").dig("servers", "web", "options")

      refute_equal "sysbox-runc", web["runtime"]
      refute_equal "0:0", web["user"]
      refute Array(web["volume"]).any? { |v| v.include?("/var/run/docker.sock") }
    end
  end

  # The entrypoint is the piece that actually decides whether dockerd starts, and its guard
  # is the only thing standing between "misconfigured host" and "every session has host
  # root". Assert the guard exists rather than trusting a comment.
  test "the entrypoint refuses to start dockerd without a user namespace" do
    script = Rails.root.join("bin/docker-entrypoint").read

    assert_match(/uid_map/, script, "the entrypoint no longer checks for a user namespace")
    assert_match(/ZIMMER_NESTED_DOCKER/, script)
    assert_match(/setpriv --reuid=1000 --regid=1000/, script,
      "the entrypoint no longer drops back to the app user; the app would keep running as root")
  end

  # dockerd's socket is root-owned unless it is told otherwise, and everything after the
  # privilege drop runs as 1000. Without the group the drop produces a working daemon that
  # the app cannot talk to.
  test "the nested daemon hands its socket to the group the app runs as" do
    assert_match(/dockerd --group 1000/, Rails.root.join("bin/docker-entrypoint").read)
  end
end

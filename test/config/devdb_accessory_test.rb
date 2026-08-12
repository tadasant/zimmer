# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# The `devdb` accessory is the whole reason an agent session can boot the app at all.
# A session runs as uid 1000 inside the worker container with no root, no sudo, and no
# access to the Docker socket (mounted root:988, and the runtime user is not in that
# group), so it cannot start a Postgres for itself. If this accessory is not declared,
# there is no database anywhere on the container network a session can reach and
# `bin/agent-dev` fails its preflight -- which is exactly the state that produced
# "there is no Postgres, Docker or root in this clone, so I could not boot the app".
#
# That failure is invisible until someone tries to boot the app by hand, months later.
# These assertions make dropping the accessory fail here instead.
class DevdbAccessoryTest < ActiveSupport::TestCase
  DESTINATIONS = {
    "production" => { deploy: "config/deploy.production.yml", host_env: "PRODUCTION_HOST" },
    "staging" => { deploy: "config/deploy.staging.yml", host_env: "STAGING_HOST" }
  }.freeze

  # bin/agent-dev's defaults. The script and the accessory have to agree on all three
  # or the connection is refused with a credentials error rather than a routing one.
  EXPECTED_USER = "zimmerdev"
  EXPECTED_PASSWORD = "zimmerdev"

  def deploy_config(destination)
    path = Rails.root.join(DESTINATIONS.fetch(destination)[:deploy])
    host_env = DESTINATIONS.fetch(destination)[:host_env]

    previous = ENV[host_env]
    ENV[host_env] = "198.51.100.10"
    YAML.safe_load(ERB.new(path.read).result, aliases: true)
  ensure
    previous.nil? ? ENV.delete(host_env) : ENV[host_env] = previous
  end

  DESTINATIONS.each_key do |destination|
    test "#{destination} declares the devdb accessory agent sessions boot against" do
      devdb = deploy_config(destination).dig("accessories", "devdb")

      assert devdb, "config/deploy.#{destination}.yml declares no `devdb` accessory; " \
        "agent sessions on that host have no Postgres to boot bin/agent-dev against"
      assert_equal "postgres:16", devdb["image"]
    end

    test "#{destination}'s devdb credentials match bin/agent-dev's defaults" do
      clear = deploy_config(destination).dig("accessories", "devdb", "env", "clear")

      assert_equal EXPECTED_USER, clear["POSTGRES_USER"]
      assert_equal EXPECTED_PASSWORD, clear["POSTGRES_PASSWORD"]
    end

    # Volume-less on purpose. It holds only scratch `zimmer_dev_<clone>` databases that
    # come and go with clones; a durable volume would grow without bound and would
    # survive a restart that should have cleaned it out.
    test "#{destination}'s devdb is disposable rather than backed by a durable volume" do
      devdb = deploy_config(destination).dig("accessories", "devdb")

      assert_nil devdb["volumes"],
        "devdb is scratch space for agent sessions; a durable volume makes it accumulate " \
        "one pair of databases per clone forever"
    end
  end

  # Staging runs a SECOND Postgres accessory (`db`) that holds staging's own data on a
  # durable volume. Pointing sessions at that one would let a feature branch's migrations
  # run against it. They must stay distinct.
  test "staging's devdb is not the same accessory as its durable db" do
    accessories = deploy_config("staging").fetch("accessories")

    assert accessories.key?("db"), "staging lost its durable `db` accessory"
    assert accessories.key?("devdb")
    assert_equal [ "zimmer_pgdata:/var/lib/postgresql/data" ], accessories.dig("db", "volumes")
    assert_nil accessories.dig("devdb", "volumes")
  end

  # Production's real database is the off-droplet Managed cluster. The scratch accessory
  # must never become what the app itself connects to.
  test "production's app still points at the managed database, not at devdb" do
    env_clear = deploy_config("production").dig("env", "clear")

    refute_equal "zimmer-devdb", env_clear["DATABASE_HOST"],
      "the production app is pointed at the throwaway dev accessory"
  end
end

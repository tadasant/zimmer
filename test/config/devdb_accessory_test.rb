# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# The `devdb` accessory is the whole reason an agent session can boot the app at all.
# A session runs as uid 1000 inside the worker container with no root, no sudo, and no
# Postgres binaries in the image, so it cannot start a Postgres for itself -- and one
# shared server beats one per clone regardless. If this accessory is not declared,
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

  # The deploy files read their host and managed-database addresses from ENV at deploy
  # time. Render with real-looking values rather than leaving them empty: an unset
  # `<%= ENV[...] %>` renders to nothing and parses as nil, which turns an assertion
  # about a value into an assertion about nil and passes no matter what the file says.
  RENDER_ENV = {
    "PRODUCTION_HOST" => "198.51.100.10",
    "STAGING_HOST" => "198.51.100.11",
    "PRODUCTION_DB_HOST" => "managed-db.example.internal"
  }.freeze

  def deploy_config(destination)
    path = Rails.root.join(DESTINATIONS.fetch(destination)[:deploy])

    previous = ENV.to_h.slice(*RENDER_ENV.keys)
    ENV.update(RENDER_ENV)
    YAML.safe_load(ERB.new(path.read).result, aliases: true)
  ensure
    RENDER_ENV.each_key { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
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

    # "Only reachable on the private Docker bridge" is the entire reason this accessory
    # may carry a guessable password in the clear. A `port:` key would publish a
    # superuser Postgres onto the droplet -- and Docker writes its own iptables rules,
    # so the host firewall would not save it.
    test "#{destination}'s devdb publishes no port to the host" do
      devdb = deploy_config(destination).dig("accessories", "devdb")

      assert_nil devdb["port"],
        "devdb's credentials are in the clear because nothing outside the Docker bridge " \
        "can reach it; publishing a port breaks that bargain"
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

  # --- The deploy is the recovery path (#419) -----------------------------------------
  #
  # `kamal accessory boot` is idempotent by EXISTENCE, not by health: it runs `docker ps -a`
  # and skips any host that already has a container, stopped ones included. So a boot-only
  # deploy never revives a stopped `devdb`, and a session cannot revive it either -- the host
  # Docker socket is deliberately NOT mounted into the worker (nested_docker_switch_test.rb
  # asserts its absence for both destinations, switch either way), so the only daemon a
  # session reaches is the nested one, which cannot see host accessories (#409).
  # Both deploys therefore REBOOT devdb
  # rather than booting it -- staging here, production in the companion repo's
  # zimmer-deploy-prod.yml, guarded there by scripts/test-devdb-reboot-scope.sh.
  #
  # `reboot` is pull + stop + `docker container prune` + boot. On `db` or `redis` that is not
  # data loss -- `prune` removes containers, and a named volume outlives the container it was
  # attached to -- but it takes a live service down mid-deploy and moves it along its moving
  # image tag, unreviewed, on every deploy. These assertions are the reason a reader can trust
  # the workflow line: they fail the build if the rebooted name is ever an accessory that
  # declares a volume.
  STAGING_DEPLOY_WORKFLOW = Rails.root.join(".github/workflows/deploy-staging.yml")

  # `kamal accessory <verb> NAME... -d staging`, as written in the workflow's run scripts.
  def staging_accessory_names(verb)
    STAGING_DEPLOY_WORKFLOW.read
      .scan(/^\s*kamal accessory #{verb}\s+(.+?)\s+-d\s+staging\b/)
      .flatten.flat_map(&:split)
  end

  test "the staging deploy reboots devdb, so a deploy revives one that stopped" do
    assert_equal [ "devdb" ], staging_accessory_names("reboot"),
      "deploy-staging.yml must reboot devdb (and nothing else): `accessory boot` skips a " \
      "stopped container, so without this line nothing on the box revives devdb and a " \
      "session is left with no Postgres and no way to fix it (#419)"
  end

  test "the staging deploy still boots every declared accessory" do
    assert_includes staging_accessory_names("boot"), "all",
      "the reboot line covers devdb only; `accessory boot all` is what creates a NEWLY " \
      "declared accessory on the host for the first time"
  end

  test "nothing data-bearing is ever rebooted by the staging deploy" do
    accessories = deploy_config("staging").fetch("accessories")

    staging_accessory_names("reboot").each do |name|
      refute_equal "all", name,
        "`accessory reboot all` would stop and prune staging's db and redis containers"

      assert accessories.key?(name), "deploy-staging.yml reboots an accessory staging does not declare: #{name}"
      assert_nil accessories.dig(name, "volumes"),
        "deploy-staging.yml reboots `#{name}`, which declares a volume. `reboot` prunes the " \
        "container; only a volume-less, disposable accessory may be rebooted on every deploy"
    end
  end

  # Production's real database is the off-droplet Managed cluster. The scratch accessory
  # must never become what the app itself connects to.
  test "production's app still points at the managed database, not at devdb" do
    env_clear = deploy_config("production").dig("env", "clear")

    assert_equal RENDER_ENV.fetch("PRODUCTION_DB_HOST"), env_clear["DATABASE_HOST"],
      "production's DATABASE_HOST no longer comes from PRODUCTION_DB_HOST (the managed cluster)"
    refute_equal "zimmer-devdb", env_clear["DATABASE_HOST"],
      "the production app is pointed at the throwaway dev accessory"
  end
end

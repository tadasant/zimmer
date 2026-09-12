# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Delivering the operator realm's credential is a chain -- a GitHub Actions secret, the
# deploy workflow's `env:` allowlist and `-e` passthrough, the Kamal mapping, the
# env.secret list -- and in production it got exactly as far as the controller. #269 put
# HTTP Basic on Supervisor::ApplicationController on 2026-08-01 and it fails closed, so
# `/supervisor` answered 401 to everyone including the operator for the six weeks to
# 2026-09-12. #1094 extended the realm to the mutating POST /health/* actions on
# 2026-09-06 and #1145 to /settings/api_keys on 2026-09-11, so each of those arrived
# already shut. The only thing missing throughout was the two lines this test pins.
#
# Nothing paged, and nothing could have. The app behaved exactly as designed, and the
# deploy cannot report the gap either: Kamal::Secrets#[] fetches from a Dotenv.parse of
# .kamal/secrets.production and raises only on a missing LINE, so an unset deploy-side
# variable resolves to "" and ships a blank password with a green deploy. The leftover
# step was recorded in #269's ledger entry, in prose, and prose is what failed.
#
# These tests assert every link that is a FILE in this repo. The Actions secret is a
# repository setting and production's deploy workflow lives in tadasant-internal, so
# neither can be asserted from here.
class OperatorRealmEnvDeliveryTest < ActiveSupport::TestCase
  PROD_SECRETS = Rails.root.join(".kamal/secrets.production")
  PROD_DEPLOY = Rails.root.join("config/deploy.production.yml")

  PASSWORD = OperatorHttpBasicAuth::PASSWORD_ENV
  # Both halves of the realm carry it, so it is what the sweep below matches on -- the
  # point being to catch a realm variable added later, not only the two that exist.
  REALM_PREFIX = "SUPERVISOR_"

  test "Kamal maps the operator realm password from the PROD_ deploy secret" do
    assert_match(/^#{PASSWORD}=\$PROD_#{PASSWORD}$/, PROD_SECRETS.read,
      "#{PROD_SECRETS} must map #{PASSWORD}, or the container never gets the credential " \
      "and all three operator surfaces stay shut.")
  end

  test "the operator realm password is exposed to the container as a Kamal secret" do
    assert_includes prod_env_secrets, PASSWORD,
      "#{PROD_DEPLOY} must list #{PASSWORD} under env.secret. Mapping it in " \
      "#{PROD_SECRETS} alone does nothing -- Kamal only injects what env.secret names."
  end

  # Only the password half is mapped. Unset and blank are the same thing to the realm
  # (`ENV[...].presence || DEFAULT_USERNAME`), so mapping the username against a deploy
  # variable nobody set would change nothing -- which makes leaving it out reversible
  # rather than a contract, and is why nothing here asserts its absence. The behaviour
  # that justifies it is pinned in supervisor/application_controller_test.rb.
  #
  # env.clear is argumentized into `--env` flags on the `docker run` command line, so a
  # credential there lands in `ps` and in the printed deploy command. env.secret goes
  # through an env-file instead.
  test "the operator realm password is not in the clear" do
    assert_not_includes prod_env_clear.keys, PASSWORD,
      "#{PASSWORD} is the credential in front of the panel that edits OAuth tokens. " \
      "It belongs in env.secret, not on the docker run command line."
  end

  # The coupling `OperatorHttpBasicAuth` states in prose, asserted at the delivery end:
  # sessions run inside the web tier's own container, so everything in env.secret reaches
  # them unless `CliSpawnEnv` clears it. Provisioning the secret is what arms that risk --
  # before it, inheriting the variable got a session nothing, because there was nothing to
  # inherit. Written over whatever the deploy injects rather than over a fixed pair, so a
  # realm variable added later is covered without editing this test.
  test "every operator realm variable the production deploy injects is cleared on spawn" do
    injected = (prod_env_secrets + prod_env_clear.keys).grep(/\A#{REALM_PREFIX}/)
    cleared = Class.new { include CliSpawnEnv }.new.send(:clear_inherited_env_vars, {})

    assert_includes injected, PASSWORD, "Sanity: the deploy should inject #{PASSWORD}."
    injected.each do |var|
      assert cleared.key?(var), "#{var} reaches the container, so CliSpawnEnv must clear it " \
        "from every spawned session -- an agent session that inherits it can drive the " \
        "/health actions the realm exists to keep it out of."
      assert_nil cleared[var]
    end
  end

  private

  # The deploy file is ERB (hosts come from ENV at deploy time). Rendering with the vars
  # unset yields nils, which is fine -- nothing read here is interpolated.
  def prod_deploy = @prod_deploy ||= YAML.safe_load(ERB.new(PROD_DEPLOY.read).result, aliases: true)
  def prod_env_secrets = prod_deploy.dig("env", "secret") || []
  def prod_env_clear = prod_deploy.dig("env", "clear") || {}
end

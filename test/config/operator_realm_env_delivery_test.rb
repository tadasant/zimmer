# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Delivering the operator realm's credential is a chain -- a GitHub Actions secret, the
# deploy workflow's `env:` allowlist, the Kamal mapping, the env.secret list -- and
# production got exactly as far as the controller. `OperatorHttpBasicAuth` shipped in
# #269 (2026-08-01) and fails closed, so for the six weeks to 2026-09-12 `/supervisor`,
# `/settings/api_keys` and the mutating `POST /health/*` actions answered 401 to
# everyone including the operator, while the only thing missing was the two lines this
# test now pins.
#
# Failing closed is why nothing paged: the app was behaving exactly as designed, and the
# leftover step was recorded in #269's ledger entry rather than in anything executable.
#
# These tests assert every link that is a FILE in this repo. The Actions secret itself is
# a repository setting, and production's deploy workflow lives in tadasant-internal, so
# neither can be asserted from here -- which is the whole reason the PR that adds these
# lines has to land AFTER the secret exists.
class OperatorRealmEnvDeliveryTest < ActiveSupport::TestCase
  PROD_SECRETS = Rails.root.join(".kamal/secrets.production")
  PROD_DEPLOY = Rails.root.join("config/deploy.production.yml")

  PASSWORD = OperatorHttpBasicAuth::PASSWORD_ENV
  USERNAME = OperatorHttpBasicAuth::USERNAME_ENV
  # Both halves of the realm share it, so it is what the sweep below matches on.
  REALM_PREFIX = "SUPERVISOR_"

  test "both halves of the realm carry the prefix the sweep below matches on" do
    assert PASSWORD.start_with?(REALM_PREFIX)
    assert USERNAME.start_with?(REALM_PREFIX)
  end

  test "Kamal maps the operator realm password from the PROD_ deploy secret" do
    assert_match(/^#{PASSWORD}=\$PROD_#{PASSWORD}$/, PROD_SECRETS.read,
      "#{PROD_SECRETS} must map #{PASSWORD}, or the container never gets the credential " \
      "and the realm stays shut -- which is what production shipped as.")
  end

  test "the operator realm password is exposed to the container as a Kamal secret" do
    assert_includes prod_env_secrets, PASSWORD,
      "#{PROD_DEPLOY} must list #{PASSWORD} under env.secret. Mapping it in " \
      "#{PROD_SECRETS} alone does nothing -- Kamal only injects what env.secret names."
  end

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

  # The username half is deliberately NOT mapped: it is not a credential, it defaults to
  # "supervisor" when absent, and every name in .kamal/secrets.production is one Kamal
  # fails the deploy on when the deploy environment cannot resolve it. Mapping it would
  # cost a second human-created Actions secret to buy nothing.
  test "the username half is absent, and absent means the documented default" do
    assert_not_includes prod_env_secrets, USERNAME
    assert_not_includes prod_env_clear.keys, USERNAME
    assert_no_match(/^#{USERNAME}=/, PROD_SECRETS.read)

    assert_equal "supervisor", OperatorHttpBasicAuth::DEFAULT_USERNAME,
      "Production authenticates as this name. Changing it silently changes what the " \
      "operator has to type, because nothing in the deploy pins it."
  end

  private

  # The deploy file is ERB (hosts come from ENV at deploy time). Rendering with the vars
  # unset yields nils, which is fine -- nothing read here is interpolated.
  def prod_deploy = YAML.safe_load(ERB.new(PROD_DEPLOY.read).result, aliases: true)
  def prod_env_secrets = prod_deploy.dig("env", "secret") || []
  def prod_env_clear = prod_deploy.dig("env", "clear") || {}
end

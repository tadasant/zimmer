# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Delivering the Parameter Store resolver credential is a three-link chain -- a GitHub
# Actions secret, the Kamal mapping, the env.secret list -- and it fails SILENTLY when a
# link breaks. `ParameterStore::Resolver.from_env` treats a missing credential as a
# normal degraded state (by design: absence must never take Zimmer down), so a broken
# link shows up only as a store that quietly never turns on and every `${VAR}` still
# coming from encrypted credentials. These tests assert the chain in both environments,
# each against its OWN project, and assert that the degraded state stays clean.
class ParameterStoreEnvDeliveryTest < ActiveSupport::TestCase
  PROD_SECRETS = Rails.root.join(".kamal/secrets.production")
  PROD_DEPLOY = Rails.root.join("config/deploy.production.yml")
  STAGING_SECRETS = Rails.root.join(".kamal/secrets.staging")
  STAGING_DEPLOY = Rails.root.join("config/deploy.staging.yml")
  # Staging's deploy workflow lives in this repo; production's lives in tadasant-internal.
  DEPLOY_WORKFLOW = Rails.root.join(".github/workflows/deploy-staging.yml")

  KEY_JSON = ParameterStore::Resolver::ENV_KEYS[:key_json]
  PROJECT_ID = ParameterStore::Resolver::ENV_KEYS[:project_id]
  LOCATION = ParameterStore::Resolver::ENV_KEYS[:location]

  # --- production: the credential ------------------------------------------

  test "Kamal maps the resolver key from the PROD_ deploy secret" do
    assert_match(/^#{KEY_JSON}=\$PROD_#{KEY_JSON}$/, PROD_SECRETS.read,
      "#{PROD_SECRETS} must map #{KEY_JSON}, or the container never gets a resolver " \
      "credential and the store link is simply absent -- silently.")
  end

  test "the resolver key is exposed to the container as a Kamal secret" do
    assert_includes prod_env_secrets, KEY_JSON,
      "#{PROD_DEPLOY} must list #{KEY_JSON} under env.secret. Mapping it in " \
      ".kamal/secrets.production alone does nothing -- Kamal only injects what env.secret names."
  end

  test "every secret the production deploy injects has a mapping in .kamal/secrets.production" do
    mapped = PROD_SECRETS.read.scan(/^([A-Z0-9_]+)=/).flatten

    (prod_env_secrets - mapped).tap do |missing|
      assert_empty missing,
        "#{PROD_DEPLOY} lists #{missing.join(', ')} under env.secret with no mapping in " \
        "#{PROD_SECRETS}; Kamal fails the deploy when it cannot resolve a named secret."
    end
  end

  # The mapping files are committed and public. Every right-hand side must be a
  # reference to the deploy shell's environment, never a literal.
  test "no secret value is committed -- the .kamal/secrets.* files hold mappings only" do
    [ PROD_SECRETS, STAGING_SECRETS ].each do |file|
      assignments = file.read.lines.grep(/^[A-Z0-9_]+=/)

      assert_operator assignments.size, :>=, 10, "Sanity: #{file} should not be empty."
      assignments.each do |line|
        name, value = line.chomp.split("=", 2)

        assert_match(/\A\$[A-Z0-9_]+\z/, value,
          "#{name} in #{file} must be a bare $VAR reference, not a literal value.")
      end
      assert_no_match(/BEGIN [A-Z ]*PRIVATE KEY|"private_key"|"client_email"/, file.read,
        "A service-account key must never be pasted into #{file}.")
    end
  end

  # --- production: the address ---------------------------------------------

  # Deliberately in the clear: the store's address is not a credential, and having it
  # visible is what makes a misconfiguration diagnosable rather than a mystery.
  test "the store's project and location are set, in the clear" do
    assert_equal "zimmer-secrets-prod", prod_env_clear[PROJECT_ID]
    assert_equal "global", prod_env_clear[LOCATION]
  end

  test "the credential is NOT in the clear" do
    assert_not_includes prod_env_clear.keys, KEY_JSON,
      "#{KEY_JSON} in env.clear would put the resolver's private key in `docker inspect` " \
      "and in the deploy log. It belongs in env.secret."
  end

  # --- what the production env actually composes ----------------------------

  # The point of all the wiring above: this exact env must put the store at the FRONT of
  # the resolution chain.
  test "the production env composes the store ahead of credentials and ENV" do
    env = prod_env_clear.slice(PROJECT_ID, LOCATION).merge(
      KEY_JSON => Base64.strict_encode64(JSON.generate({
        "client_email" => "zimmer-secrets-resolver@zimmer-secrets-prod.iam.gserviceaccount.com",
        "private_key" => "-----BEGIN PRIVATE KEY-----\\nnot-a-real-key\\n-----END PRIVATE KEY-----"
      }))
    )

    assert_equal %w[parameter_store rails_credentials env],
      SecretProviders.build(env: env).providers.map(&:name)
    assert SecretProviders.parameter_store_configuration(env: env).configured?
  end

  # --- staging: the same three links, its own project -----------------------

  # Staging is where the store path gets rehearsed before production, so it reads a
  # store of its own. Every link is asserted the same way production's is, because the
  # failure mode is the same: a break is silent.

  test "Kamal maps the resolver key from the STAGING_ deploy secret" do
    assert_match(/^#{KEY_JSON}=\$STAGING_#{KEY_JSON}$/, STAGING_SECRETS.read,
      "#{STAGING_SECRETS} must map #{KEY_JSON}, or the container never gets a resolver " \
      "credential and the store link is simply absent -- silently.")
  end

  test "the staging resolver key is exposed to the container as a Kamal secret" do
    assert_includes staging_env_secrets, KEY_JSON,
      "#{STAGING_DEPLOY} must list #{KEY_JSON} under env.secret. Mapping it in " \
      ".kamal/secrets.staging alone does nothing -- Kamal only injects what env.secret names."
  end

  # The third link, and the one the production docs single out as "the one that gets
  # skipped, and skipping it is invisible". Staging's deploy workflow lives in THIS
  # repo, so unlike production's it can be asserted rather than only written down: a
  # var missing from the step's `env:` block arrives empty, and Kamal's FOO=$FOO
  # mapping then resolves to blank with no error at all.
  test "the staging deploy workflow passes the deploy-side secret through its env allowlist" do
    step = deploy_staging_workflow[/^(\s+)- name: Kamal deploy \(staging\).*?(?=^\1- name: )/m]

    assert step, "the 'Kamal deploy (staging)' step must exist in #{DEPLOY_WORKFLOW}"
    assert_match(/^\s+STAGING_#{KEY_JSON}: \$\{\{ secrets\.STAGING_#{KEY_JSON} \}\}$/, step,
      "#{DEPLOY_WORKFLOW}'s Kamal deploy step must name STAGING_#{KEY_JSON} in its env: " \
      "block. Without it the var arrives empty, .kamal/secrets.staging resolves to blank, " \
      "and the deploy looks healthy while the store never turns on.")
  end

  test "every secret the staging deploy injects has a mapping in .kamal/secrets.staging" do
    mapped = STAGING_SECRETS.read.scan(/^([A-Z0-9_]+)=/).flatten

    (staging_env_secrets - mapped).tap do |missing|
      assert_empty missing,
        "#{STAGING_DEPLOY} lists #{missing.join(', ')} under env.secret with no mapping in " \
        "#{STAGING_SECRETS}; Kamal fails the deploy when it cannot resolve a named secret."
    end
  end

  test "the staging store's project and location are set, in the clear" do
    assert_equal "zimmer-secrets-staging", staging_env_clear[PROJECT_ID]
    assert_equal "global", staging_env_clear[LOCATION]
  end

  test "the staging credential is NOT in the clear" do
    assert_not_includes staging_env_clear.keys, KEY_JSON,
      "#{KEY_JSON} in env.clear would put the resolver's private key in `docker inspect` " \
      "and in the deploy log. It belongs in env.secret."
  end

  # The one substitution that must never happen. Agent sessions have root on the staging
  # box, so pointing it at production's project would hand them a credential that reads
  # production secret VALUES.
  test "staging is not pointed at production's store" do
    assert_not_equal prod_env_clear[PROJECT_ID], staging_env_clear[PROJECT_ID],
      "staging must read its own Parameter Store project, never production's."
    assert_no_match(/\$PROD_/, STAGING_SECRETS.read,
      "#{STAGING_SECRETS} must not read any PROD_ deploy secret.")
  end

  test "the staging env composes the store ahead of credentials and ENV" do
    env = staging_env_clear.slice(PROJECT_ID, LOCATION).merge(
      KEY_JSON => Base64.strict_encode64(JSON.generate({
        "client_email" => "zimmer-secrets-resolver@zimmer-secrets-staging.iam.gserviceaccount.com",
        "private_key" => "-----BEGIN PRIVATE KEY-----\\nnot-a-real-key\\n-----END PRIVATE KEY-----"
      }))
    )

    assert_equal %w[parameter_store rails_credentials env],
      SecretProviders.build(env: env).providers.map(&:name)
    assert SecretProviders.parameter_store_configuration(env: env).configured?
  end

  # The reason the mapping needs no `:?` assertion, asserted rather than asserted-to.
  # Tadas is deliberately not seeding the GitHub secret until a consumer exists, so THIS
  # is the state staging deploys in until he does: address set, credential blank.
  test "a staging deploy with the address set but no credential yet degrades cleanly" do
    env = staging_env_clear.slice(PROJECT_ID, LOCATION).merge(KEY_JSON => "")
    configuration = SecretProviders.parameter_store_configuration(env: env)

    assert_not configuration.configured?
    assert_equal "#{KEY_JSON} is not set", configuration.reason
    assert_equal %w[rails_credentials env], SecretProviders.build(env: env).providers.map(&:name)
  end

  # Absence has to be a clean degraded state, not a gap -- that is the whole reason
  # staging can be left unset. Asserted here, next to the claim it justifies.
  test "with nothing wired the chain is exactly credentials then ENV, and nothing raises" do
    chain = SecretProviders.build(env: {})

    assert_equal %w[rails_credentials env], chain.providers.map(&:name)
    assert_not SecretProviders.parameter_store_configuration(env: {}).configured?
    assert_nil chain.get("ANYTHING_AT_ALL")
  end

  private

  # The deploy files are ERB (hosts come from ENV at deploy time). Rendering with the
  # vars unset yields nils, which is fine -- nothing read here is interpolated.
  def render(path)
    YAML.safe_load(ERB.new(path.read).result, aliases: true)
  end

  def deploy_staging_workflow = DEPLOY_WORKFLOW.read

  def prod_env_secrets = render(PROD_DEPLOY).dig("env", "secret") || []
  def prod_env_clear = render(PROD_DEPLOY).dig("env", "clear") || {}
  def staging_env_secrets = render(STAGING_DEPLOY).dig("env", "secret") || []
  def staging_env_clear = render(STAGING_DEPLOY).dig("env", "clear") || {}
end

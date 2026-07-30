# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Delivering the Parameter Store resolver credential to production is a three-link
# chain -- a GitHub Actions secret, the Kamal mapping, the env.secret list -- and it
# fails SILENTLY when a link breaks. `ParameterStore::Resolver.from_env` treats a
# missing credential as a normal degraded state (by design: absence must never take
# Zimmer down), so a broken link shows up only as a store that quietly never turns on
# and every `${VAR}` still coming from encrypted credentials. These tests assert the
# chain, and assert that staging's *absence* of it is the deliberate shape.
class ParameterStoreEnvDeliveryTest < ActiveSupport::TestCase
  PROD_SECRETS = Rails.root.join(".kamal/secrets.production")
  PROD_DEPLOY = Rails.root.join("config/deploy.production.yml")
  STAGING_SECRETS = Rails.root.join(".kamal/secrets.staging")
  STAGING_DEPLOY = Rails.root.join("config/deploy.staging.yml")

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

  # The mapping file is committed and public. Every right-hand side must be a reference
  # to the deploy shell's environment, never a literal.
  test "no secret value is committed -- .kamal/secrets.production holds mappings only" do
    assignments = PROD_SECRETS.read.lines.grep(/^[A-Z0-9_]+=/)

    assert_operator assignments.size, :>=, 10, "Sanity: the mapping file should not be empty."
    assignments.each do |line|
      name, value = line.chomp.split("=", 2)

      assert_match(/\A\$[A-Z0-9_]+\z/, value,
        "#{name} in #{PROD_SECRETS} must be a bare $VAR reference, not a literal value.")
    end
    assert_no_match(/BEGIN [A-Z ]*PRIVATE KEY|"private_key"|"client_email"/, PROD_SECRETS.read,
      "A service-account key must never be pasted into #{PROD_SECRETS}.")
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

  # --- staging: absence, on purpose ----------------------------------------

  # Staging has no Parameter Store project and is not getting production's. The box is
  # throwaway and agent sessions have root on it; pointing it at zimmer-secrets-prod
  # would hand that a credential that reads production secret VALUES.
  test "staging wires up no Parameter Store at all" do
    staging = STAGING_SECRETS.read.lines.grep(/^[A-Z0-9_]+=/).join
    clear_and_secret = staging_env_secrets + staging_env_clear.keys

    [ KEY_JSON, PROJECT_ID, LOCATION ].each do |name|
      assert_no_match(/^#{name}=/, staging,
        "#{name} must not be mapped in #{STAGING_SECRETS}.")
      assert_not_includes clear_and_secret, name,
        "#{name} must not appear in #{STAGING_DEPLOY}."
    end
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

  def prod_env_secrets = render(PROD_DEPLOY).dig("env", "secret") || []
  def prod_env_clear = render(PROD_DEPLOY).dig("env", "clear") || {}
  def staging_env_secrets = render(STAGING_DEPLOY).dig("env", "secret") || []
  def staging_env_clear = render(STAGING_DEPLOY).dig("env", "clear") || {}
end

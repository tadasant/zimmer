# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "pp"
require "support/fake_parameter_store"

# Every object that holds a secret prints its class and safe fields, never a
# value. Each test uses obviously fake sentinel values and checks that none of
# them shows up in `inspect`, `to_s` or `pp`.
#
# Never point these at a real provider or the real ENV: on a production box
# the failure message would print the live values this test exists to protect.
class RedactedInspectTest < ActiveSupport::TestCase
  SENTINEL = "SENTINEL-NOT-A-REAL-SECRET-7f3a"

  setup { SecretProviders.reset! }
  teardown { SecretProviders.reset! }

  # Checks all three ways an object describes itself. The failure message never
  # contains the output: a leak we are catching should not then be printed.
  def assert_redacted(object, *sentinels)
    sentinels = [ SENTINEL ] if sentinels.empty?
    outputs = { "inspect" => object.inspect, "to_s" => object.to_s, "pp" => PP.pp(object, +"") }

    outputs.each do |via, output|
      sentinels.each do |sentinel|
        refute output.include?(sentinel), "#{object.class} leaked a value through #{via}"
      end
      assert_includes output, "(values redacted)", "#{object.class}##{via} is not the redacted form"
    end
  end

  def fake_env
    { "FAKE_API_KEY" => SENTINEL, "FAKE_OTHER" => "#{SENTINEL}-2" }
  end

  def credentials(values)
    SecretsLoader.stubs(:exists?).returns(false)
    SecretsLoader.stubs(:get).returns(nil)
    values.each do |name, value|
      SecretsLoader.stubs(:exists?).with(name).returns(true)
      SecretsLoader.stubs(:get).with(name).returns(value)
    end
  end

  def stub_chain(chain)
    SecretProviders.stubs(:chain).returns(chain)
  end

  # --- SecretProviders --------------------------------------------------------

  test "Env does not print the environment it holds" do
    provider = SecretProviders::Env.new(fake_env)
    assert_equal SENTINEL, provider.get("FAKE_API_KEY")

    assert_redacted provider, SENTINEL, "FAKE_OTHER"
  end

  test "RailsCredentials does not print a value" do
    credentials("FAKE_API_KEY" => SENTINEL)
    provider = SecretProviders::RailsCredentials.new
    assert_equal SENTINEL, provider.get("FAKE_API_KEY")

    assert_redacted provider
  end

  test "ParameterStoreProvider, its client, cache and snapshot do not print a value" do
    fake = FakeParameterStore.new
    fake.seed_secret("FAKE_API_KEY", SENTINEL)
    provider = fake.provider
    assert_equal SENTINEL, provider.get("FAKE_API_KEY")

    assert_redacted provider
    assert_redacted provider.client
    assert_redacted provider.instance_variable_get(:@cache)
    snapshot = provider.client.resolve_all(provider.namespaces)
    assert_equal SENTINEL, snapshot[provider.namespace]["FAKE_API_KEY"]
    assert_redacted snapshot
    assert_includes snapshot.inspect, "FAKE_API_KEY", "a snapshot still names what it holds"
  end

  test "Chain does not print a value from any link" do
    fake = FakeParameterStore.new
    fake.seed_secret("FAKE_STORE_KEY", "#{SENTINEL}-store")
    credentials("FAKE_CRED_KEY" => "#{SENTINEL}-cred")
    chain = SecretProviders::Chain.new([ fake.provider, SecretProviders::RailsCredentials.new, SecretProviders::Env.new(fake_env) ])
    assert_equal "#{SENTINEL}-store", chain.get("FAKE_STORE_KEY")

    assert_redacted chain
  end

  # --- ParameterStore credentials --------------------------------------------

  test "ServiceAccount does not print its private key or minted token" do
    account = ParameterStore::ServiceAccount.new(client_email: "fake@example.invalid", private_key: SENTINEL)
    account.instance_variable_set(:@token, "#{SENTINEL}-token")

    assert_redacted account, SENTINEL, "#{SENTINEL}-token"
    assert_includes account.inspect, "fake@example.invalid"
  end

  test "GcpClient and WriteClient do not print the account key" do
    account = ParameterStore::ServiceAccount.new(client_email: "fake@example.invalid", private_key: SENTINEL)

    assert_redacted ParameterStore::GcpClient.new(project_id: "fake-project", account: account)
    assert_redacted ParameterStore::WriteClient.new(project_id: "fake-project", account: account)
  end

  # --- SecretsInterpolator / SecretsLoader -----------------------------------

  test "a Resolution from the env link does not print the environment" do
    XOauthTokenVendor.stubs(:configured?).returns(false)
    stub_chain(SecretProviders::Chain.new([ SecretProviders::Env.new(fake_env) ]))

    resolution = SecretsInterpolator.new.resolution("FAKE_API_KEY")
    assert resolution.found?
    assert_equal "ENV", resolution.source_badge

    assert_redacted resolution, SENTINEL, "FAKE_OTHER"
  end

  test "a Resolution still redacts a source that does not redact itself" do
    leaky = Struct.new(:secret, :badge).new(SENTINEL, "Leaky")

    assert_redacted SecretsInterpolator::Resolution.new(state: :found, source: leaky)
  end

  test "SecretsLoader::Secret does not print its value" do
    secret = SecretsLoader::Secret.new(name: "FAKE_API_KEY", value: SENTINEL, description: "fake")
    assert_equal SENTINEL, secret.value
    assert_equal SENTINEL, secret.to_h[:value]

    assert_redacted secret
    assert_includes secret.inspect, "FAKE_API_KEY"
  end

  # --- OAuth client and credential objects -----------------------------------

  test "ResolvedMcpCredential does not print its tokens or headers" do
    credential = ResolvedMcpCredential.new(
      server_name: "fake", server_url: "https://fake.example.invalid/mcp", client_id: "fake-client",
      access_token: "#{SENTINEL}-access", refresh_token: "#{SENTINEL}-refresh", expires_at: nil,
      scope: nil, headers: { "Authorization" => "Bearer #{SENTINEL}-header" }, credential_key: "fake|key"
    )
    assert_equal "#{SENTINEL}-access", credential.access_token

    assert_redacted credential
  end

  test "PreregisteredOauthConfig::OAuthClient does not print its client secret" do
    client = PreregisteredOauthConfig::OAuthClient.new(
      key: "fake", client_id: "fake-client", client_secret: SENTINEL,
      authorization_endpoint: "https://fake.example.invalid/authorize", token_endpoint: "https://fake.example.invalid/token"
    )
    assert_equal SENTINEL, client.client_secret

    assert_redacted client
  end

  test "McpOauthService::OAuthMetadata does not print its client secret" do
    metadata = McpOauthService::OAuthMetadata.new(client_id: "fake-client", client_secret: SENTINEL)
    assert_equal SENTINEL, metadata.client_secret

    assert_redacted metadata
  end

  test "ClaudeAccount does not print the runtime's OAuth tokens" do
    account = ClaudeAccount.new(oauth_config: { "credentials_json" => { "claudeAiOauth" => { "accessToken" => SENTINEL } } })

    refute account.full_inspect.include?(SENTINEL), "ClaudeAccount leaked a token through full_inspect"
    refute PP.pp(account, +"").include?(SENTINEL), "ClaudeAccount leaked a token through pp"
  end

  test "plain secret-holding objects do not leak through to_json" do
    account = ParameterStore::ServiceAccount.new(client_email: "fake@example.invalid", private_key: SENTINEL)

    [ SecretProviders::Env.new(fake_env), account, ParameterStore::GcpClient.new(project_id: "fake-project", account: account) ].each do |object|
      refute object.to_json.include?(SENTINEL), "#{object.class} leaked a value through to_json"
    end
  end

  test "RuntimeLoginAttempt does not print the pasted authorization code" do
    attempt = RuntimeLoginAttempt.new(pasted_code: SENTINEL, verification_code: "#{SENTINEL}-device")

    refute attempt.full_inspect.include?(SENTINEL), "RuntimeLoginAttempt leaked a code through full_inspect"
    refute PP.pp(attempt, +"").include?(SENTINEL), "RuntimeLoginAttempt leaked a code through pp"
  end

  # Every ActiveRecord column whose name says it holds a credential is masked in
  # inspect. A new column is caught by the global filter_parameters list or by a
  # model-level filter_attributes entry; this fails when it is caught by neither.
  test "every credential-shaped column is filtered from ActiveRecord inspect" do
    credential_shaped = /(token|secret|verifier|password|private_key|pasted_code|verification_code)\z/
    # Columns that hold tokens as nested JSON keys. The filter matches top-level
    # column names only, so these must be named outright.
    nested = { "ClaudeAccount" => %w[oauth_config] }

    Rails.application.eager_load!
    leaks = ApplicationRecord.descendants.reject(&:abstract_class?).flat_map do |model|
      next [] unless model.table_exists?

      filter = ActiveSupport::ParameterFilter.new(model.filter_attributes)
      model.column_names
        .select { |column| column.match?(credential_shaped) || nested.fetch(model.name, []).include?(column) }
        .select { |column| filter.filter(column => "x")[column] == "x" }
        .map { |column| "#{model.name}.#{column}" }
    end

    assert_empty leaks, "these columns print in inspect; add them to the model's filter_attributes"
  end

  # --- guard ------------------------------------------------------------------

  # A new SecretProviders link has to redact itself. The chain holds every link,
  # and a provider's default inspect is the leak this file exists for.
  test "every SecretProviders class includes RedactedInspect" do
    providers = SecretProviders.constants.map { |name| SecretProviders.const_get(name) }.grep(Class)
    assert_operator providers.size, :>=, 4, "expected Chain, Env, RailsCredentials and ParameterStoreProvider"

    missing = providers.reject { |klass| klass.include?(RedactedInspect) }
    assert_empty missing.map(&:name), "SecretProviders classes without a safe inspect: include RedactedInspect"
  end
end

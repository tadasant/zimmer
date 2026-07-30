# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "support/fake_parameter_store"

class SecretsLocationTest < ActiveSupport::TestCase
  test "names the encrypted credentials file for the current environment" do
    assert_equal "config/credentials/test.yml.enc", SecretsLocation.credentials_path
    assert_equal "config/credentials/production.yml.enc", SecretsLocation.credentials_path("production")
  end

  test "gives the exact editing command" do
    assert_equal "bin/rails credentials:edit -e test", SecretsLocation.edit_command
    assert_equal "bin/rails credentials:edit -e production", SecretsLocation.edit_command("production")
  end

  test "the snippet is valid YAML under mcp_secrets, shaped the way SecretsLoader reads it" do
    parsed = YAML.safe_load(SecretsLocation.yaml_snippet("STRAD_API_KEY"))
    entry = parsed.fetch("mcp_secrets").sole

    assert_equal "STRAD_API_KEY", entry["name"]
    assert_equal "<the-secret-value>", entry["value"]
    assert entry.key?("description")
  end

  test "instructions bundle the variable, path, command and snippet" do
    instructions = SecretsLocation.instructions("STRAD_API_KEY")

    assert_equal "STRAD_API_KEY", instructions[:variable]
    assert_equal SecretsLocation.credentials_path, instructions[:path]
    assert_equal SecretsLocation.edit_command, instructions[:command]
    assert_match "STRAD_API_KEY", instructions[:headline]
    assert_match "mcp_secrets:", instructions[:snippet]
    assert_match "deploy", instructions[:followup]
  end

  test "SecretsLoader reads back a secret written in the documented shape" do
    entry = YAML.safe_load(SecretsLocation.yaml_snippet("STRAD_API_KEY")).fetch("mcp_secrets")
    Rails.application.credentials.stubs(:mcp_secrets).returns(entry)

    assert SecretsLoader.exists?("STRAD_API_KEY"),
      "the snippet this page tells users to paste must be a shape SecretsLoader actually loads"
  end

  # --- the Google Parameter Store branch -------------------------------------

  def chain_with_store
    fake = FakeParameterStore.new
    SecretProviders::Chain.new([ fake.provider, SecretProviders::RailsCredentials.new ])
  end

  test "with a store configured the help text names the GCP path, project and location" do
    instructions = SecretsLocation.instructions("STRAD_API_KEY", chain: chain_with_store)

    assert_equal SecretsLocation.parameter_store_name, instructions[:store_name]
    assert_equal ParameterStore::Namespace.parameter_path("STRAD_API_KEY"), instructions[:path]
    assert_equal FakeParameterStore::PROJECT, instructions[:project_id]
    assert_equal FakeParameterStore::LOCATION, instructions[:location]
    assert_match instructions[:path], instructions[:headline]
    assert_match FakeParameterStore::PROJECT, instructions[:headline]
  end

  test "the store snippet creates the secret, the parameter and the envelope that joins them" do
    snippet = SecretsLocation.instructions("STRAD_API_KEY", chain: chain_with_store)[:snippet]
    id = ParameterStore::Namespace.parameter_id(ParameterStore::Namespace.parameter_path("STRAD_API_KEY"))

    assert_match "gcloud secrets create #{id}", snippet
    assert_match "gcloud parametermanager parameters create #{id}", snippet
    assert_match "gcloud parametermanager parameters versions create v1", snippet
    assert_match "managed-by=zimmer", snippet
    assert_match SecretsLocation::PLACEHOLDER, snippet
  end

  test "the store snippet grants the PARAMETER access to the secret it points at" do
    # Without this grant `:render` returns 400 SECRET_REFERENCE_ERROR for every
    # resolution, because it dereferences the __REF__ as the parameter's own
    # principal rather than as Zimmer's credential. The store banner stays green
    # throughout (it probes the RESOLVER), so an omission here is invisible until
    # a variable silently fails to resolve.
    snippet = SecretsLocation.instructions("STRAD_API_KEY", chain: chain_with_store)[:snippet]
    id = ParameterStore::Namespace.parameter_id(ParameterStore::Namespace.parameter_path("STRAD_API_KEY"))

    assert_match "policyMember.iamPolicyUidPrincipal", snippet
    assert_match "gcloud secrets add-iam-policy-binding #{id}", snippet
    assert_match "--role=roles/secretmanager.secretAccessor", snippet

    # The grant has to land before the value is ever read back.
    assert_operator snippet.index("add-iam-policy-binding"), :<,
      snippet.index("parameters versions create"),
      "grant the parameter access before creating the version that needs it"
  end

  test "the envelope the snippet writes is exactly what the client reads back" do
    # If these drift, a human follows the instructions to the letter and Zimmer
    # still reports the secret as missing.
    fake = FakeParameterStore.new
    envelope = JSON.parse(SecretsLocation.envelope_json("STRAD_API_KEY", FakeParameterStore::PROJECT))

    id = ParameterStore::Namespace.parameter_id(envelope.fetch("path"))
    fake.secrets[id] = [ "sk-live" ]
    fake.send(:put_parameter, id, { secret: "true" }, envelope)

    assert_equal({ "STRAD_API_KEY" => "sk-live" },
      fake.client.resolve(ParameterStore::Namespace.static_namespace))
  end

  test "the store's followup names the credentials file as the un-migrated fallback" do
    instructions = SecretsLocation.instructions("STRAD_API_KEY", chain: chain_with_store)

    assert_match SecretsLocation.credentials_path, instructions[:followup]
    assert_match "store is consulted first", instructions[:followup]
  end

  test "with no store configured the help text is the encrypted credentials path" do
    chain = SecretProviders::Chain.new([ SecretProviders::RailsCredentials.new ])
    instructions = SecretsLocation.instructions("STRAD_API_KEY", chain: chain)

    assert_equal SecretsLocation.credentials_store_name, instructions[:store_name]
    assert_equal SecretsLocation.credentials_path, instructions[:path]
    assert_equal SecretsLocation.edit_command, instructions[:command]
  end
end

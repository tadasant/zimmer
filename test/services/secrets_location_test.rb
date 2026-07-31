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

  # --- the Secrets Console ---------------------------------------------------

  test "a store the console does NOT administer is called out, not papered over" do
    # This is the live case and the whole reason the console pointer is
    # conditional. Zimmer's store is deliberately its own GCP project, so a value
    # typed into strad's console is accepted, saved, and never read by Zimmer.
    # If this ever silently flips to `true`, the page starts telling people to do
    # something that fails without telling them.
    instructions = SecretsLocation.instructions("STRAD_API_KEY", chain: chain_with_store)

    refute_equal SecretsLocation.console_project_id, FakeParameterStore::PROJECT,
      "this test is only meaningful while the fake store is a different project than the console's"
    refute instructions[:console_administers]
    assert_equal SecretsLocation.console_url, instructions[:console_url]

    steps = instructions[:steps].join(" ")
    assert_match SecretsLocation.console_project_id, steps
    assert_match FakeParameterStore::PROJECT, steps
    assert_match "will never reach this variable", steps
  end

  test "a store the console DOES administer gets console steps and no shell at all" do
    fake = FakeParameterStore.new
    chain = SecretProviders::Chain.new([ fake.provider, SecretProviders::RailsCredentials.new ])
    SecretsLocation.stubs(:console_project_id).returns(FakeParameterStore::PROJECT)

    instructions = SecretsLocation.instructions("STRAD_API_KEY", chain: chain)

    assert instructions[:console_administers]
    assert_nil instructions[:command], "the console flow is the UI, not a command line"
    assert_nil instructions[:snippet]
    assert_match ParameterStore::Namespace.parameter_path("STRAD_API_KEY"), instructions[:steps].join(" ")
  end

  test "the console URL and the project it administers are overridable together" do
    # So that pointing at a Zimmer-scoped console is configuration rather than a
    # deploy of new copy — and so the two can never drift apart.
    ENV["ZIMMER_SECRETS_CONSOLE_URL"] = "https://example.test/ui/secrets"
    ENV["ZIMMER_SECRETS_CONSOLE_PROJECT_ID"] = FakeParameterStore::PROJECT

    assert_equal "https://example.test/ui/secrets", SecretsLocation.console_url
    assert_equal "example.test", SecretsLocation.console_host
    assert SecretsLocation.console_administers?(FakeParameterStore::PROJECT)
  ensure
    ENV.delete("ZIMMER_SECRETS_CONSOLE_URL")
    ENV.delete("ZIMMER_SECRETS_CONSOLE_PROJECT_ID")
  end

  test "the console never claims to administer the encrypted-credentials fallback" do
    chain = SecretProviders::Chain.new([ SecretProviders::RailsCredentials.new ])
    instructions = SecretsLocation.instructions("STRAD_API_KEY", chain: chain)

    refute instructions[:console_administers]
    refute SecretsLocation.console_administers?(nil)
    assert_match "will not reach this variable", instructions[:steps].join(" ")
  end

  test "the un-administered branch still hands over the envelope, which cannot be typed by hand" do
    # The path field guards against Namespace.parameter_id's lossy fold, so it
    # has to be exactly right. Dropping the gcloud wall must not drop this.
    instructions = SecretsLocation.instructions("STRAD_API_KEY", chain: chain_with_store)

    assert_equal ParameterStore::Namespace.parameter_path("STRAD_API_KEY"),
      JSON.parse(instructions[:snippet]).fetch("path")
    assert_match "secretAccessor", instructions[:steps].join(" ")
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

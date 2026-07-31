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

  # Point the console at a given project/location for the duration of a block.
  # Always sets all three vars, because a partial set is deliberately ignored.
  def with_console(url: "https://console.example.test/ui/secrets", project_id:, location:)
    ENV[SecretsLocation::ENV_CONSOLE_URL] = url
    ENV[SecretsLocation::ENV_CONSOLE_PROJECT_ID] = project_id
    ENV[SecretsLocation::ENV_CONSOLE_LOCATION] = location
    yield
  ensure
    [ SecretsLocation::ENV_CONSOLE_URL, SecretsLocation::ENV_CONSOLE_PROJECT_ID,
      SecretsLocation::ENV_CONSOLE_LOCATION ].each { |key| ENV.delete(key) }
  end

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
    with_console(project_id: FakeParameterStore::PROJECT, location: FakeParameterStore::LOCATION) do
      instructions = SecretsLocation.instructions("STRAD_API_KEY", chain: chain)

      assert instructions[:console_administers]
      assert_nil instructions[:command], "the console flow is the UI, not a command line"
      assert_nil instructions[:snippet]
      assert_match ParameterStore::Namespace.parameter_path("STRAD_API_KEY"), instructions[:steps].join(" ")
    end
  end

  test "the console's address, project and location are overridable as one unit" do
    # So that pointing at a Zimmer-scoped console is configuration rather than a
    # deploy of new copy.
    with_console(url: "https://example.test/ui/secrets",
      project_id: FakeParameterStore::PROJECT, location: FakeParameterStore::LOCATION) do
      assert_equal "https://example.test/ui/secrets", SecretsLocation.console_url
      assert SecretsLocation.console_administers?(FakeParameterStore.new.provider)
    end
  end

  test "a HALF override is ignored rather than merged" do
    # Setting the project without the URL is the plausible half-migration, and
    # merging it would render "set it in the Secrets Console — it administers
    # zimmer-secrets-prod" above a link to a console that administers something
    # else. That is the precise failure the triple exists to prevent, so an
    # incomplete override must fail safe to "no console claimed".
    [ SecretsLocation::ENV_CONSOLE_PROJECT_ID, SecretsLocation::ENV_CONSOLE_URL,
      SecretsLocation::ENV_CONSOLE_LOCATION ].each do |only|
      ENV[only] = only == SecretsLocation::ENV_CONSOLE_URL ? "https://example.test/ui/secrets" : FakeParameterStore::PROJECT

      assert_equal SecretsLocation::CONSOLE_URL, SecretsLocation.console_url,
        "#{only} alone must not move the console"
      refute SecretsLocation.console_administers?(FakeParameterStore.new.provider),
        "#{only} alone must not make the console claim a project it cannot administer"
    ensure
      ENV.delete(only)
    end
  end

  test "the right project in the wrong location is not administered either" do
    # A parameter is addressed by project AND location. Comparing only the
    # project sends someone to create a parameter Zimmer never reads — the same
    # silent failure as the wrong project, one field down.
    with_console(project_id: FakeParameterStore::PROJECT, location: "europe-west4") do
      refute SecretsLocation.console_administers?(FakeParameterStore.new.provider)
    end
  end

  test "the console never claims to administer the encrypted-credentials fallback" do
    chain = SecretProviders::Chain.new([ SecretProviders::RailsCredentials.new ])
    instructions = SecretsLocation.instructions("STRAD_API_KEY", chain: chain)

    refute instructions[:console_administers]
    refute SecretsLocation.console_administers?(nil)
    assert_match "will not reach this variable", instructions[:steps].join(" ")
  end

  test "the gateway is identified by its own host, not by whatever the console URL says" do
    # The console URL is overridable so it can be replaced by a Zimmer-scoped
    # one. Deriving the gateway from it would make the second-credential note
    # vanish from every row that still has a second credential the moment
    # someone did that.
    with_console(url: "https://console.example.test/ui/secrets",
      project_id: FakeParameterStore::PROJECT, location: FakeParameterStore::LOCATION) do
      assert_equal SecretsLocation::GATEWAY_HOST, SecretsLocation.gateway_host
      assert_equal "/strad/prod/mcp/slack/static/", SecretsLocation.gateway_namespace("slack")
    end
  end

  test "a console override that is not valid UTF-8 leaves the default standing" do
    # ENV values are bytes tagged UTF-8; `presence` raises on ones that are not.
    # Unguarded, a mangled override takes down the render of every connector row.
    ENV[SecretsLocation::ENV_CONSOLE_URL] = (+"https://ex\xC3.test").force_encoding("UTF-8")

    assert_equal SecretsLocation::CONSOLE_URL, SecretsLocation.console_url
  ensure
    ENV.delete(SecretsLocation::ENV_CONSOLE_URL)
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

# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "support/fake_parameter_store"

class ConnectorsControllerTest < ActionDispatch::IntegrationTest
  CATALOG = {
    "secrets-service-account" => {
      "title" => "Secrets Service Account",
      "description" => "Strad-hosted secrets MCP server.",
      "type" => "streamable-http",
      "url" => "https://strad.example.com/mcp?servers=secrets",
      "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" }
    },
    "notion" => {
      "title" => "Notion",
      "description" => "Hosted Notion MCP server.",
      "type" => "streamable-http",
      "url" => "https://mcp.notion.example.com/mcp"
    }
  }.freeze

  setup do
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp).returns(CATALOG)
    # The global fixtures carry credentials for servers this stubbed catalog does
    # not contain, which would show up as "unclaimed" in every assertion below.
    McpOauthCredential.delete_all
  end

  test "index lists every catalog server" do
    get connectors_path

    assert_response :success
    assert_select "h1", "Connectors"
    assert_select "h3", text: "Secrets Service Account", count: 1
    assert_select "h3", text: "Notion", count: 1
  end

  test "index defers every probe to its own frame, and hands the frames to the loader" do
    get connectors_path

    assert_response :success
    CATALOG.each_key do |name|
      # `lazy` is the no-JavaScript floor, not the behaviour: the frame keeps
      # working on scroll if the controller never connects. With it connected,
      # connector_list_controller promotes these to eager in a bounded window, so
      # nothing waits on the viewport. Both halves have to be here — drop the
      # target and every badge below the fold goes back to needing a scroll.
      assert_select "turbo-frame##{frame_id(name)}[loading=lazy][src=?][data-connector-list-target=frame]",
        connector_path(name)
    end
    assert_select "[data-controller=connector-list]"
    assert_select "[data-connector-list-target=list]"
    # The unresolved rows are readable before any probe runs.
    assert_select "[data-connector-state=checking]", count: CATALOG.size
  end

  test "a resolved row carries the severity rank the browser sorts on" do
    # The rank is the contract between ConnectorsHelper and the sort controller.
    # Without it in the markup the sort silently degrades to "leave everything
    # where it is", which looks exactly like a page that was never sorted.
    get connector_path("secrets-service-account")

    assert_response :success
    assert_select "[data-connector-rank=?]",
      ConnectorsHelper::SEVERITY_RANKS.fetch(:missing_configuration).to_s

    get connector_path("notion")

    assert_response :success
    assert_select "[data-connector-rank=?]",
      ConnectorsHelper::SEVERITY_RANKS.fetch(:needs_authorization).to_s
  end

  test "every state the probe can report has a rank, so nothing sorts by accident" do
    # A state with no rank falls back to "ready", which quietly buries a problem
    # row among the healthy ones. The probe is free to add a state; this is what
    # makes forgetting the rank a failing test rather than a silent regression.
    assert_equal ConnectorStatusProbe::STATES.sort,
      ConnectorsHelper::SEVERITY_RANKS.keys.sort
  end

  test "index renders even when a probe would fail" do
    ConnectorStatusProbe.any_instance.stubs(:call).raises(RuntimeError, "boom")

    get connectors_path

    assert_response :success
    assert_select "h1", "Connectors"
  end

  test "show renders the missing-configuration state with actionable help text" do
    get connector_path("secrets-service-account")

    assert_response :success
    assert_select "[data-connector-state=missing_configuration]"
    # The fragment's root <turbo-frame> is unwrapped by assert_select's HTML
    # parser, so assert on the markup: Turbo needs the id to match the frame
    # that requested it, or the response is discarded.
    assert_match %(id="#{frame_id('secrets-service-account')}"), response.body
    assert_match "STRAD_API_KEY", response.body
    assert_match SecretsLocation.edit_command, response.body
    assert_match "mcp_secrets:", response.body
    assert_match SecretsLocation.credentials_path, response.body
  end

  test "the missing-configuration help points at the Secrets Console and says whose it is" do
    get connector_path("secrets-service-account")

    assert_response :success
    assert_select "[data-secret-console=elsewhere]" do
      assert_select "a[data-secret-console-link][href=?]", SecretsLocation.console_url
    end
    # No Parameter Store is configured here, so the console administers nothing
    # Zimmer reads. Saying that is the point of the block: the console is the
    # obvious place to go looking, and a value set there is accepted and ignored.
    assert_select "[data-secret-console=administers]", count: 0
    assert_match SecretsLocation.console_project_id, response.body
  end

  test "the help distinguishes Zimmer's own ${VAR} from the credential the gateway presents" do
    # A gateway-hosted server has two credentials in two places. The console owns
    # the second and never the first, and fixing the wrong one leaves the row
    # exactly as it was — so the row has to name which is which.
    ENV["ZIMMER_SECRETS_CONSOLE_URL"] = "https://strad.example.com/ui/secrets"

    get connector_path("secrets-service-account")

    assert_response :success
    assert_select "[data-gateway-console=secrets]" do |elements|
      copy = elements.first.text
      assert_match "/strad/prod/mcp/secrets/static/", copy
      assert_match "STRAD_API_KEY", copy
      # The console administers that path, but the gateway still resolves its
      # credentials at deploy time — so a value saved there is registered and not
      # delivered. Saying "the console owns this one" without saying that is the
      # documented way to send someone off to make a change that silently does
      # nothing.
      assert_match "registry rather than a delivery path", copy
    end
  ensure
    ENV.delete("ZIMMER_SECRETS_CONSOLE_URL")
  end

  test "a server Zimmer reaches directly gets no gateway-credential note" do
    get connector_path("notion")

    assert_response :success
    assert_select "[data-gateway-console]", count: 0
  end

  test "show renders the ready state for a server with a stored credential" do
    create_credential("notion")

    get connector_path("notion")

    assert_response :success
    assert_select "[data-connector-state=ready]"
    assert_match "OAuth is complete", response.body
  end

  test "show does not leak the access token" do
    credential = create_credential("notion")

    get connector_path("notion")

    assert_response :success
    assert_no_match(/#{Regexp.escape(credential.access_token)}/, response.body)
  end

  test "show 404s for a server that is not in the catalog" do
    get connector_path("nope")

    assert_response :not_found
  end

  test "index lists credentials no catalog server claims" do
    orphan = McpOauthCredential.create!(
      server_name: "retired-server",
      server_url: "https://retired.example.com/mcp",
      credential_key: "retired-server|deadbeef",
      client_id: "client-id",
      access_token: "access-token"
    )

    get connectors_path

    assert_response :success
    assert_select "h2", text: "Unclaimed credentials"
    assert_select "##{ActionView::RecordIdentifier.dom_id(orphan)}"
  end

  test "index does not list a credential a catalog server claims" do
    create_credential("notion")

    get connectors_path

    assert_response :success
    assert_no_match(/Unclaimed credentials/, response.body)
  end


  # --- the secret-store banner -----------------------------------------------

  test "index loads the secret store banner without waiting for a scroll" do
    get connectors_path

    assert_response :success
    # One request, at the top of the page, that nobody should have to scroll to
    # trigger — so it is plain eager rather than a member of the throttled queue.
    assert_select "turbo-frame#secret_store_status[src=?]", secret_store_connectors_path
    assert_select "turbo-frame#secret_store_status[loading=lazy]", count: 0
  end

  test "secret_store reports the encrypted credentials when no resolver is configured" do
    get secret_store_connectors_path

    assert_response :success
    assert_select "[data-secret-store=rails_credentials]"
    assert_match SecretsLocation.credentials_path, response.body
    assert_match "not configured", response.body
  end

  test "secret_store names the project and flags a least-privilege credential" do
    fake = FakeParameterStore.new
    fake.held_permissions = [ ParameterStore::Capabilities::READ_SECRET_VALUE,
                              ParameterStore::Capabilities::RENDER_PARAMETER ]
    stub_chain_with(fake)

    get secret_store_connectors_path

    assert_response :success
    assert_select "[data-secret-store=parameter_store]"
    assert_select "[data-store-capabilities=least_privilege]"
    assert_match FakeParameterStore::PROJECT, response.body
  end

  test "secret_store calls out a credential that can also write" do
    fake = FakeParameterStore.new
    fake.held_permissions = [ ParameterStore::Capabilities::READ_SECRET_VALUE,
                              ParameterStore::Capabilities::WRITE_SECRET_VALUE ]
    stub_chain_with(fake)

    get secret_store_connectors_path

    assert_response :success
    assert_select "[data-store-capabilities=over_privileged]"
    assert_match ParameterStore::Capabilities::WRITE_SECRET_VALUE, response.body
  end

  # The narrowing this banner suggests is advice an operator will follow literally,
  # so it has to name all three roles the runbook grants. Naming only viewer +
  # secretAccessor drops `parameterVersions.render` and turns a working credential
  # into one where nothing resolves from the store.
  test "secret_store's over-privileged banner suggests all three read roles, not a narrowing that breaks render" do
    fake = FakeParameterStore.new
    fake.held_permissions = [ ParameterStore::Capabilities::READ_SECRET_VALUE,
                              ParameterStore::Capabilities::RENDER_PARAMETER,
                              ParameterStore::Capabilities::WRITE_SECRET_VALUE ]
    stub_chain_with(fake)

    get secret_store_connectors_path

    assert_response :success
    assert_select "[data-store-capabilities=over_privileged]" do |elements|
      copy = elements.first.text
      assert_match "roles/parametermanager.parameterViewer", copy
      assert_match "roles/parametermanager.parameterAccessor", copy
      assert_match "roles/secretmanager.secretAccessor", copy
    end
  end

  test "secret_store says it could not find out rather than guessing" do
    fake = FakeParameterStore.new
    fake.fail_with!(403)
    stub_chain_with(fake)

    get secret_store_connectors_path

    assert_response :success
    assert_select "[data-store-capabilities=unprobed]"
    assert_match "Could not confirm", response.body
  end

  # --- the Authorize button ---------------------------------------------------

  # The point of the button: authorizing a connector must not cost the user a
  # throwaway session, so the row posts to initiate with no session_id at all.
  test "an unauthorized OAuth row offers Authorize and posts a session-less initiate" do
    get connector_path("notion")

    assert_response :success
    assert_select "[data-connector-state=needs_authorization]"
    assert_select "form[action=?][method=post]", mcp_oauth_initiate_path do
      assert_select "input[name=server_name][value=notion]"
      assert_select "input[name=session_id]", count: 0
      assert_select "input[data-connector-authorize=notion][value=Authorize]"
    end
  end

  test "an authorized OAuth row offers Disconnect and no Authorize button" do
    create_credential("notion")

    get connector_path("notion")

    assert_response :success
    assert_select "[data-connector-state=ready]"
    assert_select "[data-connector-authorize]", count: 0
    assert_select "form[action=?]", mcp_oauth_credential_path(McpOauthCredential.last)
  end

  # An expired credential with no refresh token is the one other row a consent
  # screen fixes, and re-authorizing overwrites the dead credential in place.
  test "a needs-re-auth row offers Re-authorize" do
    create_credential("notion").update!(expires_at: 1.hour.ago, refresh_token: nil, token_endpoint: nil)

    get connector_path("notion")

    assert_response :success
    assert_select "[data-connector-state=needs_reauth]"
    assert_select "input[data-connector-authorize=notion][value=Re-authorize]"
  end

  # A `${VAR}` credential is not OAuth. No consent screen will ever set
  # STRAD_API_KEY, so offering to start one would be a lie.
  test "a missing-configuration row offers no Authorize button" do
    get connector_path("secrets-service-account")

    assert_response :success
    assert_select "[data-connector-state=missing_configuration]"
    assert_select "[data-connector-authorize]", count: 0
  end

  # --- secret-source badges ---------------------------------------------------

  test "a connector row badges the provider that resolved each secret" do
    fake = FakeParameterStore.new
    fake.seed_secret("STRAD_API_KEY", "sk-live")
    stub_chain_with(fake)

    get connector_path("secrets-service-account")

    assert_response :success
    assert_select "[data-secret-source=STRAD_API_KEY][data-secret-source-badge=GSM]"
    assert_match "Google Secret Manager", response.body
  end

  test "an unset secret badges Unresolved rather than rendering nothing" do
    get connector_path("secrets-service-account")

    assert_response :success
    assert_select "[data-secret-source=STRAD_API_KEY][data-secret-source-badge=Unresolved]"
  end

  private

  def stub_chain_with(fake)
    SecretProviders.stubs(:chain).returns(
      SecretProviders::Chain.new([ fake.provider, SecretProviders::RailsCredentials.new ])
    )
  end


  # The frame id the view actually emits — asserted through the helper so the
  # test pins the index/partial agreement, not a hand-copied string.
  def frame_id(server_name)
    ApplicationController.helpers.connector_frame_id(server_name)
  end

  def create_credential(name)
    McpOauthCredential.create!(
      server_name: name,
      server_url: CATALOG.fetch(name)["url"],
      credential_key: McpOauthCredential.compute_credential_key(name, ServersConfig.credential_config(name)),
      client_id: "client-id",
      access_token: "secret-access-token",
      expires_at: 2.hours.from_now
    )
  end
end

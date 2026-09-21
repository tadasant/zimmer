# frozen_string_literal: true

require "test_helper"

# Settings → Zimmer plugins.
class ExternalAppsControllerTest < ActionDispatch::IntegrationTest
  include ExternalAppTestHelpers
  include LogCaptureHelpers

  setup do
    @trigger = triggers(:enabled_slack_trigger)
  end

  test "the settings page links here, and the page lists plugins" do
    ExternalApp.create!(name: "Housing search")

    get settings_path
    assert_select "a[href=?]", external_apps_path

    get external_apps_path
    assert_response :success
    assert_select "h1", "Zimmer plugins"
    assert_select "a", "Housing search"
  end

  test "registering a plugin redirects to its page, and a duplicate name re-renders with the error" do
    post external_apps_path, params: { external_app: { name: "Housing search", description: "Vetting" } }
    app = ExternalApp.find_by!(name: "Housing search")
    assert_redirected_to external_app_path(app)

    post external_apps_path, params: { external_app: { name: "HOUSING SEARCH" } }
    assert_response :unprocessable_entity
    assert_select "div.bg-red-50", /already been taken/
  end

  test "saving sets the allowlist and enabled, and logs the change at WARN" do
    app = ExternalApp.create!(name: "Housing search")

    entries = capture_log_entries do
      patch external_app_path(app), params: { external_app: { name: "Housing search", enabled: "0", trigger_ids: [ "", @trigger.id.to_s ] } }
    end
    assert_redirected_to external_app_path(app)
    app.reload
    assert_equal [ @trigger.id ], app.trigger_ids
    assert_not app.enabled?
    assert(entries.any? { |level, message| level == "WARN" && message.include?("updated \"Housing search\"") })

    patch external_app_path(app), params: { external_app: { name: "Housing search", enabled: "1", trigger_ids: [ "" ] } }
    assert_empty app.reload.trigger_ids
    assert app.enabled?
  end

  test "an unknown trigger id is refused and changes nothing" do
    app, = create_plugin_with_key(triggers: [ @trigger ])

    patch external_app_path(app), params: { external_app: { name: "Renamed", enabled: "1", trigger_ids: [ "999999999" ] } }
    assert_response :unprocessable_entity
    assert_equal [ @trigger.id ], app.reload.trigger_ids
    assert_equal "Housing search", app.name
  end

  test "minting shows the key once, uncached, and stores only its digest" do
    app = ExternalApp.create!(name: "Housing search")

    post mint_key_external_app_path(app)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    token = css_select("#minted-key input").first["value"]
    assert token.start_with?(ApiKey::MINTED_PREFIX)
    key = app.api_keys.sole
    assert_equal ApiKey.digest(token), key.token_digest
    assert key.external_app?

    get external_app_path(app)
    assert_not_includes response.body, token
  end

  test "revoking a key revokes it, and only this plugin's keys can be revoked here" do
    app, token = create_plugin_with_key(triggers: [ @trigger ])
    other_app, = create_plugin_with_key(name: "Other")

    post revoke_key_external_app_path(app, api_key_id: other_app.api_keys.first.id)
    assert_response :not_found
    assert_not other_app.api_keys.first.reload.revoked?

    post revoke_key_external_app_path(app, api_key_id: app.api_keys.first.id)
    assert_redirected_to external_app_path(app)
    assert_not ApiKey.authenticate(token, grant: ApiKey::EXTERNAL_APP_GRANT).authenticated?
  end

  test "deleting a plugin deletes its keys" do
    app, token = create_plugin_with_key(triggers: [ @trigger ])

    delete external_app_path(app)
    assert_redirected_to external_apps_path
    assert_nil ExternalApp.find_by(id: app.id)
    assert_nil ApiKey.find_by(token_digest: ApiKey.digest(token))
  end

  test "the show page lists sessions the plugin started" do
    app, = create_plugin_with_key(triggers: [ @trigger ])
    session = Session.first
    session.update_columns(metadata: session.metadata.merge(app.session_metadata.stringify_keys).merge("trigger_name" => @trigger.name))

    get external_app_path(app)
    assert_response :success
    assert_select "a[href=?]", session_path(session)
  end

  test "the API keys page badges a plugin key and its form offers no plugin grant" do
    app, = create_plugin_with_key

    get api_keys_path
    assert_response :success
    assert_select "a[href=?]", external_app_path(app), text: "Zimmer plugin: Housing search"
    assert_select "input[name='api_key[grant]'][value=?]", ApiKey::EXTERNAL_APP_GRANT, count: 0

    post api_keys_path, params: { api_key: { name: "sneaky", grant: ApiKey::EXTERNAL_APP_GRANT } }
    assert_response :unprocessable_entity
    assert_nil ApiKey.find_by(name: "sneaky")
  end
end

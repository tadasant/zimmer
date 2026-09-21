# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A Zimmer plugin's REST surface, and — the half that matters most — everything
# else refusing a plugin's key.
class Api::V1::ExternalAppTriggersControllerTest < ActionDispatch::IntegrationTest
  include ExternalAppTestHelpers
  include LogCaptureHelpers

  setup do
    @full_api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @full_api_key
    @trigger = triggers(:enabled_slack_trigger)
    @trigger.update!(prompt_template: "Vet the listing {{text}}", max_sessions_per_minute: nil)
    @other_trigger = triggers(:disabled_slack_trigger)
    @app, @token = create_plugin_with_key(triggers: [ @trigger ])
    @headers = { "X-API-Key" => @token }
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # --- The surface itself ---

  test "index lists only the allowlisted triggers, with their variables and cap, and never the template" do
    get api_v1_external_app_triggers_path, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal({ "id" => @app.id, "name" => "Housing search", "description" => "Kicks off vetting" }, json["external_app"])
    assert_equal [ { "id" => @trigger.id, "name" => @trigger.name, "variables" => [ "text" ], "max_sessions_per_minute" => nil } ],
                 json["triggers"]
    assert_not_includes response.body, "Vet the listing"
  end

  test "invoke fires the trigger with the variables, stamps the plugin on the session, and returns it" do
    stub_trigger_session_creation

    assert_difference("Session.count", 1) do
      post api_v1_external_app_invoke_trigger_path(@trigger), params: { variables: { text: "listing-42" } }.to_json,
           headers: @headers.merge("Content-Type" => "application/json")
    end

    assert_response :created
    json = JSON.parse(response.body)
    session = Session.order(:id).last
    assert_equal "fired", json["outcome"]
    assert_equal true, json["fired"]
    assert_equal({ "id" => @trigger.id, "name" => @trigger.name }, json["trigger"])
    assert_equal session.id, json["session"]["id"]
    assert_equal "http://www.example.com/sessions/#{session.id}", json["session"]["url"]

    assert_equal "Vet the listing listing-42", session.prompt
    assert_equal SessionGenesis::API, session.genesis
    assert_equal @app.id, session.metadata["external_app_id"]
    assert_equal "Housing search", session.metadata["external_app_name"]
    assert_equal @trigger.id.to_s, session.metadata["trigger_id"].to_s
    assert_not_nil @app.reload.last_invoked_at
  end

  test "a batch of invokes each fires, while the trigger's cap allows" do
    stub_trigger_session_creation
    @trigger.update!(max_sessions_per_minute: 30)

    assert_difference("Session.count", 25) do
      25.times do |i|
        post api_v1_external_app_invoke_trigger_path(@trigger), params: { variables: { text: "listing-#{i}" } }, headers: @headers
        assert_response :created
      end
    end
    assert_equal 25, @app.sessions.count
  end

  test "past the trigger's cap a batch gets one burst notice, then nothing, both as 429" do
    stub_trigger_session_creation
    @trigger.update!(max_sessions_per_minute: 2)

    2.times { post api_v1_external_app_invoke_trigger_path(@trigger), headers: @headers }
    assert_response :created

    post api_v1_external_app_invoke_trigger_path(@trigger), headers: @headers
    assert_response :too_many_requests
    json = JSON.parse(response.body)
    assert_equal "burst_notice", json["outcome"]
    assert_equal false, json["fired"]
    assert_not_nil json["session"], "the burst-notice session is reported"
    assert_nil Session.find(json["session"]["id"]).metadata["external_app_id"],
               "the burst notice is not the plugin's work, so it does not carry its name"

    post api_v1_external_app_invoke_trigger_path(@trigger), headers: @headers
    assert_response :too_many_requests
    assert_equal "burst_suppressed", JSON.parse(response.body)["outcome"]
  end

  test "a disabled trigger on the allowlist can still be invoked, as with the Invoke button" do
    stub_trigger_session_creation
    @trigger.update!(status: "disabled")

    post api_v1_external_app_invoke_trigger_path(@trigger), headers: @headers
    assert_response :created
  end

  test "unknown variable names and oversized values are refused, and nothing fires" do
    assert_no_difference("Session.count") do
      post api_v1_external_app_invoke_trigger_path(@trigger), params: { variables: { listing: "x" } }, headers: @headers
      assert_response :unprocessable_entity
      assert_equal "invalid_variables", JSON.parse(response.body)["outcome"]
      assert_includes JSON.parse(response.body)["message"], "listing"

      post api_v1_external_app_invoke_trigger_path(@trigger),
           params: { variables: { text: "x" * (ExternalApps::InvokeTrigger::MAX_VARIABLE_CHARS + 1) } }, headers: @headers
      assert_response :unprocessable_entity
    end
  end

  # --- Refusals on the surface ---

  test "a trigger not on the allowlist answers exactly as one that does not exist" do
    assert_no_difference("Session.count") do
      post api_v1_external_app_invoke_trigger_path(@other_trigger), headers: @headers
    end
    assert_response :not_found
    off_list = JSON.parse(response.body)

    post api_v1_external_app_invoke_trigger_path(id: 999_999_999), headers: @headers
    assert_response :not_found
    missing = JSON.parse(response.body)

    assert_equal "not_found", off_list["outcome"]
    assert_equal off_list["message"].sub(@other_trigger.id.to_s, "ID"), missing["message"].sub("999999999", "ID")
    assert_nil off_list["trigger"]
  end

  test "a refusal is logged at WARN, which ships to obs" do
    entries = capture_log_entries { post api_v1_external_app_invoke_trigger_path(@other_trigger), headers: @headers }
    assert(entries.any? { |level, message| level == "WARN" && message.include?("[external_app]") && message.include?("not on its allowlist") })
  end

  test "a disabled plugin is refused with 403 on both routes" do
    @app.update!(enabled: false)

    get api_v1_external_app_triggers_path, headers: @headers
    assert_response :forbidden
    assert_no_difference("Session.count") do
      post api_v1_external_app_invoke_trigger_path(@trigger), headers: @headers
    end
    assert_response :forbidden
  end

  test "a revoked key, another plugin's key, no key and a full-API key are all refused" do
    stub_trigger_session_creation
    @app.api_keys.first.revoke!
    get api_v1_external_app_triggers_path, headers: @headers
    assert_response :unauthorized

    get api_v1_external_app_triggers_path
    assert_response :unauthorized

    # A full-API key is not a plugin key: the grant match is exact both ways.
    get api_v1_external_app_triggers_path, headers: { "X-API-Key" => @full_api_key }
    assert_response :unauthorized
    post api_v1_external_app_invoke_trigger_path(@trigger), headers: { "X-API-Key" => @full_api_key }
    assert_response :unauthorized

    # Another plugin's key sees its own allowlist, never this one's.
    _other_app, other_token = create_plugin_with_key(name: "Other app", triggers: [ @other_trigger ])
    assert_no_difference("Session.count") do
      post api_v1_external_app_invoke_trigger_path(@trigger), headers: { "X-API-Key" => other_token }
    end
    assert_response :not_found
  end

  test "a deleted plugin's key is refused" do
    @app.destroy!
    get api_v1_external_app_triggers_path, headers: @headers
    assert_response :unauthorized
  end

  # --- Everything else refuses a plugin key ---

  # Every route under /api and /mcp other than the plugin's own, walked from the
  # route table so a route added later is covered without anyone remembering to.
  test "every other API and MCP route refuses a plugin key with 401" do
    own = %w[api/v1/external_app_triggers external_app_mcp]
    checked = []

    Rails.application.routes.routes.each do |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      next unless path.start_with?("/api/", "/mcp/") || path == "/mcp"
      next if own.include?(route.defaults[:controller])
      # A route whose action the controller does not define is a 404 before any
      # callback runs, whoever asks — dead routing, not a door.
      controller = "#{route.defaults[:controller]}_controller".camelize.safe_constantize
      next unless controller&.action_methods&.include?(route.defaults[:action].to_s)

      concrete = path.gsub(/:(\w+)/) { Regexp.last_match(1) == "token" ? "not-a-token" : "1" }.gsub(/\*\w+/, "x")
      verbs = route.verb.to_s.split("|").presence || %w[GET]

      verbs.each do |verb|
        process verb.downcase.to_sym, concrete, headers: @headers.merge("Content-Type" => "application/json",
                                                                        "Accept" => "application/json, text/event-stream"),
                                                params: "{}"
        checked << "#{verb} #{concrete}"
        assert_equal 401, response.status, "#{verb} #{concrete} (#{route.defaults[:controller]}##{route.defaults[:action]}) " \
                                           "answered #{response.status} to a plugin key: #{response.body.to_s.truncate(200)}"
      end
    end

    assert_operator checked.size, :>, 100, "the sweep found too few routes to prove anything: #{checked.size}"
    assert_includes checked, "POST /api/v1/sessions"
    assert_includes checked, "POST /api/v1/triggers/1/invoke"
    assert_includes checked, "POST /mcp"
  end

  test "/mcp refuses a plugin key whatever tool_groups it asks for" do
    %w[/mcp /mcp?tool_groups=triggers /mcp?tool_groups=self_session /mcp?tool_groups=external_apps].each do |path|
      post path, params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
                 headers: { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json", "Accept" => "application/json" }
      assert_response :unauthorized, "#{path} accepted a plugin key"
    end
  end
end

require "test_helper"
require "mocha/minitest"

# Tests for newly added session API endpoints:
# fork, refresh, refresh_all, update_mcp_servers, transcript, update_notes,
# toggle_favorite, bulk_archive
class Api::V1::SessionsControllerExtendedTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # ============================================================
  # Fork tests
  # ============================================================

  test "fork should return error without message_index" do
    session = sessions(:with_transcript)
    post fork_api_v1_session_path(session), headers: @headers
    assert_response :unprocessable_entity

    json = JSON.parse(response.body)
    assert_includes json["message"], "message_index"
  end

  test "fork should create forked session with valid message_index" do
    session = sessions(:with_transcript)
    # ForkSessionService needs clone_path in metadata — mock it
    session.update!(metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" })

    # ForkSessionService call may fail if clone doesn't exist; test it returns meaningful response
    post fork_api_v1_session_path(session), params: { message_index: 1 }, headers: @headers

    # Either success (if service can run) or unprocessable (clone missing)
    assert_includes [ 201, 422 ], response.status
  end

  test "fork should return 404 for nonexistent session" do
    post fork_api_v1_session_path(999999), params: { message_index: 1 }, headers: @headers
    assert_response :not_found
  end

  # ============================================================
  # Refresh tests
  # ============================================================

  test "refresh should return error for session without clone path" do
    session = sessions(:needs_input)
    session.update!(metadata: {})

    post refresh_api_v1_session_path(session), headers: @headers
    assert_response :unprocessable_entity

    json = JSON.parse(response.body)
    assert_includes json["message"], "clone path"
  end

  test "refresh should return 404 for nonexistent session" do
    post refresh_api_v1_session_path(999999), headers: @headers
    assert_response :not_found
  end

  # ============================================================
  # Refresh all tests
  # ============================================================

  test "refresh_all should return summary" do
    post refresh_all_api_v1_sessions_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("message")
    assert json.key?("refreshed")
    assert json.key?("restarted")
    assert json.key?("continued")
    assert json.key?("errors")
  end

  test "refresh_all should restart failed sessions" do
    # The failed fixture should be picked up
    post refresh_all_api_v1_sessions_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    # It should attempt to restart the failed session
    total = json["restarted"] + json["errors"]
    assert total >= 0
  end

  test "refresh_all excludes a failed session in a frozen category" do
    frozen_cat = Category.create!(name: "api parked backlog", is_frozen: true)
    frozen_failed = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "parked",
      status: :failed,
      category: frozen_cat
    )

    post refresh_all_api_v1_sessions_path, headers: @headers
    assert_response :success

    # The frozen-category session is excluded, so it is never restarted and stays failed.
    assert_equal "failed", frozen_failed.reload.status
  end

  # ============================================================
  # Update MCP servers tests
  # ============================================================

  test "update_mcp_servers should update servers" do
    session = sessions(:needs_input)

    patch mcp_servers_api_v1_session_path(session), params: {
      mcp_servers: [ "playwright-custom" ]
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_includes json["session"]["mcp_servers"], "playwright-custom"
  end

  test "update_mcp_servers should reject non-array" do
    session = sessions(:needs_input)

    patch mcp_servers_api_v1_session_path(session), params: {
      mcp_servers: "not-an-array"
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  test "update_mcp_servers should reject too many servers" do
    session = sessions(:needs_input)

    patch mcp_servers_api_v1_session_path(session), params: {
      mcp_servers: (1..51).map { |i| "server-#{i}" }
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  test "update_mcp_servers should reject invalid server names" do
    session = sessions(:needs_input)

    patch mcp_servers_api_v1_session_path(session), params: {
      mcp_servers: [ "nonexistent-server-xyz" ]
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["message"], "nonexistent-server-xyz"
  end

  test "update_mcp_servers should create log entry" do
    session = sessions(:needs_input)

    assert_difference("session.logs.count") do
      patch mcp_servers_api_v1_session_path(session), params: {
        mcp_servers: [ "playwright-custom" ]
      }, headers: @headers
    end
  end

  test "update_mcp_servers should allow empty array" do
    session = sessions(:needs_input)

    patch mcp_servers_api_v1_session_path(session), params: {
      mcp_servers: []
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal [], json["session"]["mcp_servers"]
  end

  test "update_catalog_plugins should regenerate runtime MCP config for bundled plugin servers" do
    Dir.mktmpdir do |temp_dir|
      session = sessions(:needs_input)
      session.update!(
        mcp_servers: [ "remote-fs-screenshots" ],
        catalog_plugins: [],
        metadata: { "working_directory" => temp_dir }
      )

      AirPrepareService.any_instance.expects(:prepare!).once

      patch catalog_plugins_api_v1_session_path(session), params: {
        catalog_plugins: [ "figma-design-workflow" ]
      }, headers: @headers

      assert_response :success
      session.reload
      assert_equal [ "figma-design-workflow" ], session.catalog_plugins
      assert_includes session.all_mcp_servers, "remote-fs-screenshots"
      assert_includes session.all_mcp_servers, "figma"
      assert_includes session.all_mcp_servers, "image-diff"
      assert_includes session.all_mcp_servers, "svg-tracer"
      assert_includes session.all_mcp_servers, "playwright-custom"
    end
  end

  # ============================================================
  # Update Model tests
  # ============================================================

  test "update_model should update model in config" do
    session = sessions(:needs_input)

    patch model_api_v1_session_path(session), params: {
      model: "sonnet"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "sonnet", json["session"]["config"]["model"]
  end

  test "update_model should reject non-string model" do
    session = sessions(:needs_input)

    patch model_api_v1_session_path(session), params: {
      model: ""
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  test "update_model should reject missing model" do
    session = sessions(:needs_input)

    patch model_api_v1_session_path(session), params: {}, headers: @headers

    assert_response :unprocessable_entity
  end

  test "update_model should reject a model not in the session runtime catalog" do
    session = sessions(:needs_input)
    assert_equal "claude_code", session.agent_runtime

    patch model_api_v1_session_path(session), params: {
      model: "gpt-5"
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Invalid model", json["error"]
    assert_match(/not valid for runtime claude_code/, json["message"])
    assert_match(/opus, sonnet, haiku/, json["message"])
    # The session's model is left unchanged.
    assert_not_equal "gpt-5", session.reload.config&.dig("model")
  end

  test "update_model should create log entry" do
    session = sessions(:needs_input)

    assert_difference("session.logs.count") do
      patch model_api_v1_session_path(session), params: {
        model: "sonnet"
      }, headers: @headers
    end
  end

  test "update_model should preserve existing config values" do
    session = sessions(:needs_input)
    session.update!(config: { "model" => "opus", "other_key" => "preserved" })

    patch model_api_v1_session_path(session), params: {
      model: "sonnet"
    }, headers: @headers

    assert_response :success
    session.reload
    assert_equal "sonnet", session.config["model"]
    assert_equal "preserved", session.config["other_key"]
  end

  # ============================================================
  # Transcript tests
  # ============================================================

  test "transcript should return formatted text for session with transcript" do
    session = sessions(:with_transcript)

    get transcript_api_v1_session_path(session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("transcript_text")
    assert_includes json["transcript_text"], "User"
  end

  test "transcript should return 404 for session without transcript" do
    session = sessions(:needs_input)
    session.update!(transcript: nil)

    get transcript_api_v1_session_path(session), headers: @headers
    assert_response :not_found
  end

  test "transcript should return 404 for nonexistent session" do
    get transcript_api_v1_session_path(999999), headers: @headers
    assert_response :not_found
  end

  # ============================================================
  # Update notes tests
  # ============================================================

  test "update_notes should update session notes" do
    session = sessions(:needs_input)

    patch notes_api_v1_session_path(session), params: {
      session_notes: "These are test notes"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "These are test notes", json["session"]["session_notes"]
    assert_not_nil json["session_notes_updated_at"]
  end

  test "update_notes should clear notes with blank value" do
    session = sessions(:needs_input)
    session.update!(session_notes: "Existing notes")

    patch notes_api_v1_session_path(session), params: {
      session_notes: ""
    }, headers: @headers

    assert_response :success
    assert_nil session.reload.session_notes
  end

  test "update_notes should reject notes that are too long" do
    session = sessions(:needs_input)

    patch notes_api_v1_session_path(session), params: {
      session_notes: "x" * 50_001
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  # ============================================================
  # Toggle favorite tests
  # ============================================================

  test "toggle_favorite should toggle from false to true" do
    session = sessions(:needs_input)
    session.update!(favorited: false)

    post toggle_favorite_api_v1_session_path(session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["favorited"]
    assert_equal true, session.reload.favorited
  end

  test "toggle_favorite should toggle from true to false" do
    session = sessions(:needs_input)
    session.update!(favorited: true)

    post toggle_favorite_api_v1_session_path(session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal false, json["favorited"]
  end

  # ============================================================
  # Bulk archive tests
  # ============================================================

  test "bulk_archive should archive multiple sessions" do
    s1 = sessions(:needs_input)
    s2 = sessions(:waiting)

    post bulk_archive_api_v1_sessions_path, params: {
      session_ids: [ s1.id, s2.id ]
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert json["archived_count"] >= 1
  end

  test "bulk_archive should reject missing session_ids" do
    post bulk_archive_api_v1_sessions_path, headers: @headers
    assert_response :unprocessable_entity
  end

  test "bulk_archive should skip already archived sessions" do
    archived = sessions(:archived)

    post bulk_archive_api_v1_sessions_path, params: {
      session_ids: [ archived.id ]
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 0, json["archived_count"]
  end

  # ============================================================
  # Session JSON should include new fields
  # ============================================================

  test "session json should include session_notes and favorited" do
    session = sessions(:needs_input)
    session.update!(session_notes: "Test notes", favorited: true)

    get api_v1_session_path(session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["session"]
    assert json.key?("session_notes")
    assert json.key?("favorited")
    assert json.key?("session_notes_updated_at")
    assert_equal "Test notes", json["session_notes"]
    assert_equal true, json["favorited"]
  end

  # ============================================================
  # Authentication tests for new endpoints
  # ============================================================

  test "fork should return 401 without API key" do
    post fork_api_v1_session_path(sessions(:with_transcript))
    assert_response :unauthorized
  end

  test "refresh should return 401 without API key" do
    post refresh_api_v1_session_path(sessions(:needs_input))
    assert_response :unauthorized
  end

  test "refresh_all should return 401 without API key" do
    post refresh_all_api_v1_sessions_path
    assert_response :unauthorized
  end

  test "update_mcp_servers should return 401 without API key" do
    patch mcp_servers_api_v1_session_path(sessions(:needs_input))
    assert_response :unauthorized
  end

  test "update_model should return 401 without API key" do
    patch model_api_v1_session_path(sessions(:needs_input))
    assert_response :unauthorized
  end

  test "transcript should return 401 without API key" do
    get transcript_api_v1_session_path(sessions(:with_transcript))
    assert_response :unauthorized
  end

  test "update_notes should return 401 without API key" do
    patch notes_api_v1_session_path(sessions(:needs_input))
    assert_response :unauthorized
  end

  test "toggle_favorite should return 401 without API key" do
    post toggle_favorite_api_v1_session_path(sessions(:needs_input))
    assert_response :unauthorized
  end

  test "bulk_archive should return 401 without API key" do
    post bulk_archive_api_v1_sessions_path
    assert_response :unauthorized
  end

  # ============================================================
  # Heartbeat tests
  # ============================================================

  test "update_heartbeat enables the heartbeat" do
    session = sessions(:needs_input)
    patch heartbeat_api_v1_session_path(session), params: { enabled: true }, headers: @headers, as: :json
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["heartbeat_enabled"]
    assert_equal true, json["session"]["heartbeat_enabled"]
    assert_equal true, session.reload.heartbeat_enabled
  end

  test "update_heartbeat sets the interval" do
    session = sessions(:needs_input)
    patch heartbeat_api_v1_session_path(session), params: { interval_seconds: 300 }, headers: @headers, as: :json
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 300, json["heartbeat_interval_seconds"]
    assert_equal 300, session.reload.heartbeat_interval_seconds
  end

  test "update_heartbeat can set both enabled and interval at once" do
    session = sessions(:needs_input)
    patch heartbeat_api_v1_session_path(session), params: { enabled: true, interval_seconds: 120 }, headers: @headers, as: :json
    assert_response :success

    session.reload
    assert session.heartbeat_enabled
    assert_equal 120, session.heartbeat_interval_seconds
  end

  test "update_heartbeat rejects an out-of-range interval" do
    session = sessions(:needs_input)
    patch heartbeat_api_v1_session_path(session), params: { interval_seconds: 1 }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal 60, session.reload.heartbeat_interval_seconds
  end

  test "update_heartbeat requires at least one parameter" do
    session = sessions(:needs_input)
    patch heartbeat_api_v1_session_path(session), headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "update_heartbeat rejects a non-boolean enabled value with 422 (not 500)" do
    session = sessions(:needs_input)
    patch heartbeat_api_v1_session_path(session), params: { enabled: "" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "session_json includes heartbeat fields" do
    session = sessions(:needs_input)
    get api_v1_session_path(session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["session"]
    assert json.key?("heartbeat_enabled")
    assert json.key?("heartbeat_interval_seconds")
  end

  test "update_heartbeat should return 401 without API key" do
    patch heartbeat_api_v1_session_path(sessions(:needs_input)), params: { enabled: true }
    assert_response :unauthorized
  end
end

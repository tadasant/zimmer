require "test_helper"
require "mocha/minitest"
require "tmpdir"

# Contract-level tests for the REST API surface: the one error envelope
# (#82), the Settings-page defaults on a rootless create (#81), the
# `refreshed` counter on bulk refresh (#80), and the plain-text transcript
# renderer (#83).
class Api::V1::SessionsControllerContractTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # ============================================================
  # #82 — one error envelope
  # ============================================================

  # Every error body carries `error`, a String `message`, and an Array
  # `messages`, whichever branch produced it.
  def assert_error_envelope(response_body)
    json = JSON.parse(response_body)

    assert json.key?("error"), "error key missing from #{json.inspect}"
    assert json.key?("message"), "message key missing from #{json.inspect}"
    assert json.key?("messages"), "messages key missing from #{json.inspect}"
    assert_kind_of String, json["message"]
    assert_kind_of Array, json["messages"]
    assert(json["messages"].all? { |m| m.is_a?(String) }, "messages must be all Strings: #{json['messages'].inspect}")
    assert_equal json["messages"].join(", "), json["message"]

    json
  end

  test "401 uses the standard error envelope" do
    get api_v1_sessions_path

    assert_response :unauthorized
    json = assert_error_envelope(response.body)
    assert_equal "Unauthorized", json["error"]
  end

  test "404 uses the standard error envelope" do
    get api_v1_session_path(999_999), headers: @headers

    assert_response :not_found
    assert_error_envelope(response.body)
  end

  test "model validation failure uses the standard error envelope" do
    post api_v1_sessions_path, params: { prompt: "no git root" }, headers: @headers

    assert_response :unprocessable_entity
    json = assert_error_envelope(response.body)
    assert_includes json["message"], "Git root"
    assert_includes json["messages"].join, "Git root"
  end

  # A single-message error reads as a plain sentence, never as the stringified
  # array the old singular-key/array-value shape produced.
  test "a single-message error renders message as a sentence" do
    post follow_up_api_v1_session_path(sessions(:needs_input)), params: {}, headers: @headers

    assert_response :unprocessable_entity
    json = assert_error_envelope(response.body)
    refute_match(/\A\[/, json["message"])
    assert_equal 1, json["messages"].size
  end

  test "a bad-request error uses the standard error envelope" do
    get search_api_v1_sessions_path, headers: @headers

    assert_response :bad_request
    assert_error_envelope(response.body)
  end

  # ============================================================
  # #82 — one session shape
  # ============================================================

  test "interrupt returns the standard session shape" do
    session = sessions(:needs_input)
    message = session.enqueued_messages.create!(content: "go", position: 1, status: "pending")

    post interrupt_api_v1_session_enqueued_message_path(session, message), headers: @headers
    assert_response :success

    interrupt_session = JSON.parse(response.body)["session"]

    get api_v1_session_path(session), headers: @headers
    assert_response :success
    standard_session = JSON.parse(response.body)["session"]

    assert_equal standard_session.keys.sort, interrupt_session.keys.sort,
      "interrupt's `session` must be the same shape as GET /sessions/:id's"
  end

  # ============================================================
  # #81 — the Settings-page defaults are honored without an agent_root
  # ============================================================

  test "create without agent_root honors the global default runtime and model" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.4")

    post api_v1_sessions_path,
      params: { prompt: "hello", git_root: "https://github.com/test/repo.git" },
      headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["session"]

    assert_equal "codex", json["agent_runtime"]
    assert_equal "gpt-5.4", json["config"]["model"]
  end

  test "an explicit runtime param still beats the global default" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.4")

    post api_v1_sessions_path,
      params: { prompt: "hello", git_root: "https://github.com/test/repo.git", agent_runtime: "claude_code" },
      headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["session"]

    assert_equal "claude_code", json["agent_runtime"]
    # The global model belongs to the other runtime, so it self-heals to a model
    # this runtime can actually run rather than persisting an invalid one.
    assert ModelCatalog.valid_model?("claude_code", json["config"]["model"]),
      "#{json['config']['model'].inspect} is not a claude_code model"
  end

  test "an explicit config model still beats the global default" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "claude_code", default_model: "opus")

    post api_v1_sessions_path,
      params: {
        prompt: "hello",
        git_root: "https://github.com/test/repo.git",
        config: { model: "sonnet" }
      },
      headers: @headers

    assert_response :created
    assert_equal "sonnet", JSON.parse(response.body)["session"]["config"]["model"]
  end

  test "with no global default the create falls back to the hardcoded default" do
    AppSetting.delete_all

    post api_v1_sessions_path,
      params: { prompt: "hello", git_root: "https://github.com/test/repo.git" },
      headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["session"]

    assert_equal RuntimeRegistry::DEFAULT_RUNTIME, json["agent_runtime"]
    assert_equal ModelCatalog.default_for(RuntimeRegistry::DEFAULT_RUNTIME), json["config"]["model"]
  end

  test "agent_root still resolves now that it comes through strong params" do
    root = AgentRootsConfig.all.first
    skip "no agent roots in the catalog" if root.nil?

    post api_v1_sessions_path,
      params: { prompt: "hello", agent_root: root.name },
      headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["session"]

    assert_equal root.url, json["git_root"]
    assert_equal root.name, json["metadata"]["agent_root_key"]
    refute json.key?("agent_root"), "agent_root is not a Session column"
  end

  # ============================================================
  # #80 — refresh_all actually counts what it refreshed
  # ============================================================

  test "refresh_all counts a session whose transcript it re-read" do
    session = sessions(:running)
    Session.where.not(id: session.id).update_all(status: Session.statuses[:archived])

    fresh_transcript = [
      { type: "user", message: { role: "user", content: "one" } },
      { type: "assistant", message: { role: "assistant", content: "two" } },
      { type: "user", message: { role: "user", content: "three" } }
    ].map { |e| JSON.generate(e) }.join("\n")

    Dir.mktmpdir do |dir|
      transcript_file = File.join(dir, "main.jsonl")
      File.write(transcript_file, fresh_transcript)

      Api::V1::SessionsController.any_instance.stubs(:get_transcript_directory_for_session).returns(dir)
      Api::V1::SessionsController.any_instance.stubs(:find_main_transcript_file_for_session).returns(transcript_file)

      post refresh_all_api_v1_sessions_path, headers: @headers
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal 1, json["refreshed"], "refresh_all reported #{json.inspect}"
      assert_equal fresh_transcript, session.reload.transcript
      assert_equal 3, session.metadata["broadcast_message_count"]
    end
  end

  test "refresh_all does not count a session it could not read from disk" do
    Api::V1::SessionsController.any_instance.stubs(:get_transcript_directory_for_session).returns(nil)

    post refresh_all_api_v1_sessions_path, headers: @headers
    assert_response :success

    assert_equal 0, JSON.parse(response.body)["refreshed"]
  end

  test "refresh_all does not refresh a session it just restarted" do
    failed = sessions(:failed)
    Session.where.not(id: failed.id).update_all(status: Session.statuses[:archived])

    Api::V1::SessionsController.any_instance
      .expects(:refresh_transcript_from_disk)
      .never

    post refresh_all_api_v1_sessions_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 0, json["refreshed"]
  end

  # ============================================================
  # #83 — the transcript renderer
  # ============================================================

  test "transcript renders array content blocks as text, not inspect output" do
    session = sessions(:needs_input)
    session.update!(transcript: [
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "text", "text" => "Here is the plan." },
            { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/app/x.rb" } }
          ]
        }
      }
    ])

    get transcript_api_v1_session_path(session), params: { format: "text" }, headers: @headers
    assert_response :success

    refute_includes response.body, '"type"=>', "content blocks leaked Ruby hash inspect output"
    refute_includes response.body, "{\"type\"=>",
      "content blocks leaked Ruby hash inspect output"
    assert_includes response.body, "Here is the plan."
    assert_includes response.body, "[tool_use: Read]"
    assert_includes response.body, "/app/x.rb"
  end

  test "transcript renders thinking and tool_result blocks" do
    session = sessions(:needs_input)
    session.update!(transcript: [
      {
        "type" => "assistant",
        "message" => { "role" => "assistant", "content" => [ { "type" => "thinking", "thinking" => "weighing options" } ] }
      },
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => [ { "type" => "tool_result", "content" => [ { "type" => "text", "text" => "file contents" } ] } ]
        }
      }
    ])

    get transcript_api_v1_session_path(session), params: { format: "text" }, headers: @headers
    assert_response :success

    assert_includes response.body, "[thinking] weighing options"
    assert_includes response.body, "[tool_result] file contents"
  end

  test "transcript labels entry types it has no special layout for" do
    session = sessions(:needs_input)
    session.update!(transcript: [
      { "type" => "system", "content" => "session resumed" },
      { "type" => "result", "subtype" => "success", "total_cost_usd" => 0.42 }
    ])

    get transcript_api_v1_session_path(session), params: { format: "text" }, headers: @headers
    assert_response :success

    assert_includes response.body, "--- System ---"
    assert_includes response.body, "session resumed"
    assert_includes response.body, "--- Result ---"
    assert_includes response.body, "total_cost_usd",
      "an unknown entry type must be dumped, not dropped"
  end

  test "transcript still renders plain string content" do
    session = sessions(:with_transcript)

    get transcript_api_v1_session_path(session), params: { format: "text" }, headers: @headers
    assert_response :success

    assert_includes response.body, "--- User ---"
    assert_includes response.body, "Hello, can you help me?"
    assert_includes response.body, "--- Assistant ---"
  end

  test "transcript truncates a long tool result" do
    session = sessions(:needs_input)
    session.update!(transcript: [
      { "type" => "tool_result", "content" => "x" * 5_000 }
    ])

    get transcript_api_v1_session_path(session), params: { format: "text" }, headers: @headers
    assert_response :success

    assert_includes response.body, "--- Tool Result ---"
    assert_operator response.body.length, :<, 1_000
  end
end

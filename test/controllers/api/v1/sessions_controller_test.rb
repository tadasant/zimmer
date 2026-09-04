require "test_helper"
require "mocha/minitest"
require "automated_prompts"
require "ostruct"

class Api::V1::SessionsControllerTest < ActionDispatch::IntegrationTest
  include AttachmentFixtures

  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
    # Durable attachment storage outlives the test that wrote it.
    cleanup_stored_attachments!
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_sessions_path
    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "Unauthorized", json["error"]
  end

  test "should return 401 with invalid API key" do
    get api_v1_sessions_path, headers: { "X-API-Key" => "invalid_key" }
    assert_response :unauthorized
  end

  test "should accept valid API key" do
    get api_v1_sessions_path, headers: @headers
    assert_response :success
  end

  test "should accept any valid key from comma-separated list" do
    ENV["API_KEYS"] = "key1, key2, key3"
    get api_v1_sessions_path, headers: { "X-API-Key" => "key2" }
    assert_response :success
  end

  # Index tests
  test "should return list of sessions" do
    get api_v1_sessions_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("sessions")
    assert json.key?("pagination")
    assert json["sessions"].is_a?(Array)
  end

  test "should exclude archived sessions by default" do
    get api_v1_sessions_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    statuses = json["sessions"].map { |s| s["status"] }
    assert_not_includes statuses, "archived"
  end

  test "should include archived sessions when show_archived is true" do
    get api_v1_sessions_path, params: { show_archived: "true" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    statuses = json["sessions"].map { |s| s["status"] }
    assert_includes statuses, "archived"
  end

  test "should filter by status" do
    get api_v1_sessions_path, params: { status: "running" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["sessions"].each do |session|
      assert_equal "running", session["status"]
    end
  end

  test "should filter by agent_runtime" do
    get api_v1_sessions_path, params: { agent_runtime: "claude_code" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["sessions"].each do |session|
      assert_equal "claude_code", session["agent_runtime"]
    end
  end

  test "should paginate results" do
    get api_v1_sessions_path, params: { page: 1, per_page: 2 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["pagination"]["page"] == 1
    assert json["pagination"]["per_page"] == 2
    assert json["sessions"].length <= 2
  end

  test "should cap per_page at 100" do
    get api_v1_sessions_path, params: { per_page: 500 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 100, json["pagination"]["per_page"]
  end

  # Show tests
  test "should return session by id" do
    session = sessions(:running)
    get api_v1_session_path(session.id), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal session.id, json["session"]["id"]
  end

  test "should return session by slug" do
    session = sessions(:running)
    session.update!(slug: "test-slug-123")

    get api_v1_session_path("test-slug-123"), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal session.id, json["session"]["id"]
  end

  test "should return 404 for nonexistent session" do
    get api_v1_session_path(999999), headers: @headers
    assert_response :not_found
  end

  test "should include transcript when requested" do
    session = sessions(:with_transcript)
    get api_v1_session_path(session.id), params: { include_transcript: "true" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["session"].key?("transcript")
  end

  test "should exclude transcript by default" do
    session = sessions(:with_transcript)
    get api_v1_session_path(session.id), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_not json["session"].key?("transcript")
  end

  # Create tests
  test "should create session with valid params" do
    assert_difference("Session.count", 1) do
      post api_v1_sessions_path, params: {
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main"
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert json["session"]["id"].present?
    assert_equal "claude_code", json["session"]["agent_runtime"]
  end

  # parent_session_id is a permitted create param, and the sessions table refuses a
  # pointer to a session that does not exist — so an unknown id has to come back as a
  # validation error, not an ActiveRecord::InvalidForeignKey 500.
  test "should reject create with a parent_session_id that references no session" do
    assert_no_difference("Session.count") do
      post api_v1_sessions_path, params: {
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        parent_session_id: 999_999_999
      }, headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join(" "), "must reference an existing session"
  end

  # `execution_provider` is a permitted create param, so the REST surface has to reject a
  # provider that cannot run — not just decline to advertise it, the way the MCP tool's enum
  # does. Otherwise an API caller can still store a value no code path can honor.
  test "should reject create with the stub remote_sandbox execution provider" do
    assert_no_difference("Session.count") do
      post api_v1_sessions_path, params: {
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        execution_provider: "remote_sandbox"
      }, headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join(" "), "remote_sandbox is not a valid execution provider"
  end

  test "should create session with prompt and queue job" do
    assert_enqueued_with(job: AgentSessionJob) do
      post api_v1_sessions_path, params: {
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        prompt: "Test prompt"
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert json["session"]["job_id"].present?
  end

  test "should create session without prompt (clone only)" do
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      post api_v1_sessions_path, params: {
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main"
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert_nil json["session"]["job_id"]
  end

  test "should reject session without git_root" do
    assert_no_difference("Session.count") do
      post api_v1_sessions_path, params: {
        agent_runtime: "claude_code",
        branch: "main",
        prompt: "Test prompt"
      }, headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "Git root can't be blank"
  end

  test "should reject invalid agent_runtime" do
    post api_v1_sessions_path, params: {
      agent_runtime: "invalid_agent",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "not a valid agent runtime"
  end

  test "should default model to opus when not specified in config" do
    post api_v1_sessions_path, params: {
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "opus", json["session"]["config"]["model"],
      "Model should default to 'opus' when config is not provided"
  end

  test "should respect explicit model in config" do
    post api_v1_sessions_path, params: {
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      config: { model: "sonnet" }
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "sonnet", json["session"]["config"]["model"],
      "Model should use the explicitly provided value"
  end

  test "should create session with custom_metadata" do
    post api_v1_sessions_path, params: {
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      custom_metadata: { "key" => "value" }
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal({ "key" => "value" }, json["session"]["custom_metadata"])
  end

  test "should default auto_compact_window to 1_000_000 when omitted" do
    post api_v1_sessions_path, params: {
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal 1_000_000, json["session"]["auto_compact_window"]
  end

  test "should accept explicit auto_compact_window override" do
    post api_v1_sessions_path, params: {
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      auto_compact_window: 50_000
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal 50_000, json["session"]["auto_compact_window"]
  end

  test "should reject non-positive auto_compact_window" do
    post api_v1_sessions_path, params: {
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      auto_compact_window: 0
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "Auto compact window must be greater than 0"
  end

  test "should reject non-integer auto_compact_window" do
    post api_v1_sessions_path, params: {
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      auto_compact_window: "abc"
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "Auto compact window"
  end

  test "should reject auto_compact_window above ceiling" do
    post api_v1_sessions_path, params: {
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      auto_compact_window: 1_000_001
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "Auto compact window must be less than or equal to 1000000"
  end

  # Agent root resolution tests
  test "should resolve agent_root to git_root and catalog defaults" do
    mock_agent_root = OpenStruct.new(
      name: "test-root",
      url: "https://github.com/test/correct-repo.git",
      default_branch: "develop",
      subdirectory: "src/app",
      default_mcp_servers: [],
      default_skills: [],
      default_model: "sonnet"
    )

    AgentRootsConfig.stub(:find!, ->(name) {
      raise AgentRootsConfig::AgentRootNotFoundError, "not found" unless name == "test-root"
      mock_agent_root
    }) do
      assert_difference("Session.count", 1) do
        post api_v1_sessions_path, params: {
          agent_root: "test-root",
          agent_runtime: "claude_code",
          prompt: "Test prompt"
        }, headers: @headers
      end
    end

    assert_response :created
    json = JSON.parse(response.body)
    session = json["session"]
    assert_equal "https://github.com/test/correct-repo.git", session["git_root"]
    assert_equal "develop", session["branch"]
    assert_equal "src/app", session["subdirectory"]
    assert_equal "sonnet", session["config"]["model"]
    assert_equal "test-root", session["metadata"]["agent_root_key"]
  end

  # An omitted list takes the root's defaults; an explicit [] takes none. The two
  # must not collapse — collapsing them is what handed spawns that asked for no
  # servers whatever their root declared, SSH access included. JSON encoding is
  # required here: a form-encoded empty array does not survive the round trip,
  # so it could not express the case under test.
  test "an explicit empty mcp_servers array creates a session with no servers" do
    mock_agent_root = OpenStruct.new(
      name: "test-root",
      url: "https://github.com/test/correct-repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [ "context7" ],
      default_skills: [],
      default_model: "sonnet"
    )
    ServersConfig.stubs(:exists?).returns(true)

    AgentRootsConfig.stub(:find!, ->(_name) { mock_agent_root }) do
      post api_v1_sessions_path,
        params: { agent_root: "test-root", prompt: "Least privilege", mcp_servers: [] }.to_json,
        headers: @headers.merge("CONTENT_TYPE" => "application/json")
    end

    assert_response :created
    session = Session.order(:id).last
    assert_equal [], session.mcp_servers
    # Recorded so McpServerBackfill doesn't restore the defaults at job start.
    assert session.mcp_servers_explicitly_empty?
  end

  test "an omitted mcp_servers key still takes the root's default servers" do
    mock_agent_root = OpenStruct.new(
      name: "test-root",
      url: "https://github.com/test/correct-repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [ "context7" ],
      default_skills: [],
      default_model: "sonnet"
    )
    ServersConfig.stubs(:exists?).returns(true)

    AgentRootsConfig.stub(:find!, ->(_name) { mock_agent_root }) do
      post api_v1_sessions_path,
        params: { agent_root: "test-root", prompt: "Defaults please" }.to_json,
        headers: @headers.merge("CONTENT_TYPE" => "application/json")
    end

    assert_response :created
    session = Session.order(:id).last
    assert_equal [ "context7" ], session.mcp_servers
    refute session.mcp_servers_explicitly_empty?
  end

  test "clearing mcp_servers over the API records the choice as deliberate" do
    ServersConfig.stubs(:exists?).returns(true)
    session = sessions(:needs_input)
    session.update!(mcp_servers: [ "context7" ])

    patch mcp_servers_api_v1_session_path(session),
      params: { mcp_servers: [] }.to_json,
      headers: @headers.merge("CONTENT_TYPE" => "application/json")

    assert_response :success
    assert_equal [], session.reload.mcp_servers
    assert session.mcp_servers_explicitly_empty?
  end

  test "should return error for invalid agent_root" do
    AgentRootsConfig.stub(:find!, ->(name) {
      raise AgentRootsConfig::AgentRootNotFoundError, "Agent root '#{name}' not found in catalog"
    }) do
      post api_v1_sessions_path, params: {
        agent_root: "nonexistent-root",
        agent_runtime: "claude_code",
        prompt: "Test prompt"
      }, headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Invalid agent_root", json["error"]
    assert_includes json["message"], "nonexistent-root"
  end

  test "explicit params take precedence over agent_root defaults" do
    mock_agent_root = OpenStruct.new(
      name: "test-root",
      url: "https://github.com/test/default-repo.git",
      default_branch: "develop",
      subdirectory: "default/sub",
      default_mcp_servers: [],
      default_skills: [],
      default_model: "sonnet"
    )

    AgentRootsConfig.stub(:find!, ->(_name) { mock_agent_root }) do
      post api_v1_sessions_path, params: {
        agent_root: "test-root",
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/explicit-repo.git",
        branch: "custom-branch",
        subdirectory: "custom/sub",
        prompt: "Test prompt"
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    session = json["session"]
    assert_equal "https://github.com/test/explicit-repo.git", session["git_root"]
    assert_equal "custom-branch", session["branch"]
    assert_equal "custom/sub", session["subdirectory"]
  end

  test "explicit config.model wins over the agent_root's default_model" do
    # Regression for pulsemcp/pulsemcp#3963: an explicit config.model in the create request must
    # be persisted verbatim rather than being clobbered by the agent root's
    # default_model. This blocks selecting a non-default model (e.g. Codex
    # gpt-5.4) when spawning via the API.
    mock_agent_root = OpenStruct.new(
      name: "test-root",
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_skills: [],
      default_model: "opus",
      default_runtime: "codex"
    )

    AgentRootsConfig.stub(:find!, ->(_name) { mock_agent_root }) do
      assert_difference("Session.count", 1) do
        post api_v1_sessions_path, params: {
          agent_root: "test-root",
          agent_runtime: "codex",
          config: { model: "gpt-5.4" },
          prompt: "Test prompt"
        }, headers: @headers
      end
    end

    assert_response :created
    json = JSON.parse(response.body)
    session = json["session"]
    assert_equal "gpt-5.4", session["config"]["model"],
      "explicit config.model must not be overwritten by agent_root.default_model"
    assert_equal "codex", session["agent_runtime"]
  end

  test "omitting config.model falls back to the agent_root's default_model" do
    mock_agent_root = OpenStruct.new(
      name: "test-root",
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_skills: [],
      default_model: "opus",
      default_runtime: "claude_code"
    )

    AgentRootsConfig.stub(:find!, ->(_name) { mock_agent_root }) do
      assert_difference("Session.count", 1) do
        post api_v1_sessions_path, params: {
          agent_root: "test-root",
          agent_runtime: "claude_code",
          prompt: "Test prompt"
        }, headers: @headers
      end
    end

    assert_response :created
    json = JSON.parse(response.body)
    session = json["session"]
    assert_equal "opus", session["config"]["model"],
      "omitting config.model should adopt the agent_root's default_model"
  end

  test "session adopts the agent_root's default_runtime when no agent_runtime param given" do
    mock_agent_root = OpenStruct.new(
      name: "test-root",
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_skills: [],
      default_model: "sonnet",
      default_runtime: "claude_code"
    )

    AgentRootsConfig.stub(:find!, ->(_name) { mock_agent_root }) do
      assert_difference("Session.count", 1) do
        post api_v1_sessions_path, params: {
          agent_root: "test-root",
          prompt: "Test prompt"
        }, headers: @headers
      end
    end

    assert_response :created
    session = Session.order(:created_at).last
    assert_equal "claude_code", session.agent_runtime
  end

  test "explicit agent_runtime param wins over the agent_root's default_runtime" do
    # The stubbed root declares a runtime that is NOT registered. If the
    # derivation path were to clobber the explicit param, resolving the root's
    # default through RuntimeRegistry would raise and the request would fail.
    # A 201 with the explicit runtime proves the per-spawn override wins.
    mock_agent_root = OpenStruct.new(
      name: "test-root",
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_skills: [],
      default_model: "sonnet",
      default_runtime: "not_a_registered_runtime"
    )

    AgentRootsConfig.stub(:find!, ->(_name) { mock_agent_root }) do
      assert_difference("Session.count", 1) do
        post api_v1_sessions_path, params: {
          agent_root: "test-root",
          agent_runtime: "claude_code",
          prompt: "Test prompt"
        }, headers: @headers
      end
    end

    assert_response :created
    session = Session.order(:created_at).last
    assert_equal "claude_code", session.agent_runtime
  end

  # Update tests
  test "should update session title" do
    session = sessions(:running)
    patch api_v1_session_path(session.id), params: {
      title: "New Title"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "New Title", json["session"]["title"]
  end

  test "should update session slug" do
    session = sessions(:running)
    patch api_v1_session_path(session.id), params: {
      slug: "new-slug-123"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "new-slug-123", json["session"]["slug"]
  end

  test "should update custom_metadata" do
    session = sessions(:running)
    patch api_v1_session_path(session.id), params: {
      custom_metadata: { "new_key" => "new_value" }
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "new_value", json["session"]["custom_metadata"]["new_key"]
  end

  test "should reject invalid slug format" do
    session = sessions(:running)
    patch api_v1_session_path(session.id), params: {
      slug: "Invalid Slug With Spaces"
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  # Destroy tests
  test "should delete session" do
    session = sessions(:running)
    assert_difference("Session.count", -1) do
      delete api_v1_session_path(session.id), headers: @headers
    end

    assert_response :no_content
  end

  test "should return 404 when deleting nonexistent session" do
    delete api_v1_session_path(999999), headers: @headers
    assert_response :not_found
  end

  # The reported repro for #340: the delete endpoint used to leave the session's
  # durable scratch dir and prompt attachments on the volume, unreachable by any
  # later query because their only key was the id of the row it had just removed.
  test "should delete the session's scratch dir and prompt attachments" do
    session = sessions(:running)
    env_backup = %w[AGENT_SCRATCH_DIR AGENT_FILES_DIR AGENT_IMAGES_DIR].index_with { |key| ENV[key] }
    scratch_base = Dir.mktmpdir("api-destroy-scratch")
    files_base = Dir.mktmpdir("api-destroy-files")
    images_base = Dir.mktmpdir("api-destroy-images")
    ENV["AGENT_SCRATCH_DIR"] = scratch_base
    ENV["AGENT_FILES_DIR"] = files_base
    ENV["AGENT_IMAGES_DIR"] = images_base

    scratch = SessionScratchDirectory.ensure_for(session.id)
    File.write(File.join(scratch, "pipeline-state.json"), "{}")
    file_service = FileStorageService.new(session_id: session.id)
    file_service.store(data: "notes", filename: "notes.md")
    image_service = ImageStorageService.new(session_id: session.id)
    png = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ].pack("C*") + ("x" * 32)
    image_service.store(data: Base64.strict_encode64(png), filename: "shot.png")

    delete api_v1_session_path(session.id), headers: @headers

    assert_response :no_content
    assert_not Dir.exist?(scratch), "DELETE should reclaim the session's scratch dir"
    assert_not Dir.exist?(file_service.session_dir), "DELETE should reclaim the session's prompt files"
    assert_not Dir.exist?(image_service.session_dir), "DELETE should reclaim the session's prompt images"
  ensure
    env_backup&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    [ scratch_base, files_base, images_base ].compact.each { |dir| FileUtils.rm_rf(dir) }
  end

  # Archive tests
  # Archiving discards whatever is still queued, so the REST surface refuses it
  # for the same reason the MCP one does — and takes the same `force` opt-out.
  test "archive refuses a session with a queued message" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "add the onion back", position: 1, status: "pending")

    post archive_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    body = response.body
    assert_includes body, "1 queued message has not been delivered"
    assert_includes body, "add the onion back"
    assert_equal "running", session.reload.status
    assert_equal "pending", session.enqueued_messages.sole.status
  end

  test "archive with force discards the queue and still records it" do
    session = sessions(:running)
    queued = session.enqueued_messages.create!(content: "discarded", position: 1, status: "pending")

    post archive_api_v1_session_path(session.id), params: { force: true }, headers: @headers

    assert_response :success
    assert_equal "archived", session.reload.status
    assert_equal "undelivered", queued.reload.status
  end

  test "archive ignores a force that is not truthy" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")

    post archive_api_v1_session_path(session.id), params: { force: "0" }, headers: @headers

    assert_response :unprocessable_entity
    assert_equal "running", session.reload.status
  end

  # Forcing chooses the discard; it must not hide it.
  test "a forced archive still names the discarded messages on the archive line" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "thrown away deliberately", position: 1, status: "pending")

    post archive_api_v1_session_path(session.id), params: { force: true }, headers: @headers

    assert_response :success
    line = session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_includes line, "1 queued message was never delivered"
    assert_includes line, "thrown away deliberately"
  end

  test "bulk_archive skips sessions with queued messages and reports them" do
    blocked = sessions(:running)
    blocked.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")
    archivable = sessions(:needs_input)

    post bulk_archive_api_v1_sessions_path,
      params: { session_ids: [ blocked.id, archivable.id ] },
      headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 1, json["archived_count"]
    assert_equal [ blocked.id ], json["errors"].map { |e| e["id"] }
    assert_includes json["errors"].sole["message"], "applies to every session in the batch",
      "a per-session error inside a batch has to name force's batch-wide reach"
    assert_equal "running", blocked.reload.status
  end

  test "bulk_archive with force archives the whole batch" do
    blocked = sessions(:running)
    queued = blocked.enqueued_messages.create!(content: "discarded in bulk", position: 1, status: "pending")

    post bulk_archive_api_v1_sessions_path,
      params: { session_ids: [ blocked.id ], force: true },
      headers: @headers

    assert_response :success
    assert_equal 1, JSON.parse(response.body)["archived_count"]
    assert_equal "undelivered", queued.reload.status
  end

  test "should archive running session" do
    session = sessions(:running)
    post archive_api_v1_session_path(session.id), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "archived", json["session"]["status"]
  end

  test "should archive waiting session" do
    session = sessions(:waiting)
    post archive_api_v1_session_path(session.id), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "archived", json["session"]["status"]
  end

  test "should not archive already archived session" do
    session = sessions(:archived)
    post archive_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Cannot trash", json["error"]
  end

  # Unarchive tests
  test "should unarchive archived session" do
    session = sessions(:archived)

    # Create the clone directory so unarchive can find it (quick path)
    clone_path = session.metadata&.dig("clone_path")
    FileUtils.mkdir_p(clone_path) if clone_path

    begin
      post unarchive_api_v1_session_path(session.id), headers: @headers

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "needs_input", json["session"]["status"]
      assert json.key?("clone_restored"), "Response should include clone_restored flag"
    ensure
      FileUtils.rm_rf(clone_path) if clone_path
    end
  end

  # zimmer#557, reproducing sessions 5936, 5988 and 6136: a session created by a
  # trigger, held by the spot gate, then archived without its agent process ever
  # launching. Restore failed with "Failed to restore: Session has no session_id"
  # on both front doors, which made Trash irreversible for it.
  test "should unarchive a session that never ran" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Investigate the flaky test",
      status: :archived,
      archived_at: 1.hour.ago,
      metadata: { "paused_by" => "recovery" }
    )
    assert session.never_ran?

    post unarchive_api_v1_session_path(session.id), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "needs_input", json["session"]["status"]
    assert_not json["clone_restored"], "there is no clone to restore for a session that never ran"
    assert_nil session.reload.archived_at
  end

  test "should not unarchive non-archived session" do
    session = sessions(:running)
    post unarchive_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Cannot restore", json["error"]
  end

  # Follow-up tests
  test "should send follow-up to needs_input session and transition to running" do
    session = sessions(:needs_input)

    assert_enqueued_with(job: AgentSessionJob) do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Follow-up prompt"
      }, headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Follow-up prompt sent", json["message"]
    assert_equal "running", session.reload.status
  end

  # message_parent — the child -> parent direction. :id names the CHILD; the
  # target is read from parent_session_id and is never a parameter.
  test "should deliver a child's report to the parent Zimmer resolves" do
    parent = sessions(:needs_input)
    child = sessions(:waiting)
    child.update!(parent_session_id: parent.id)

    assert_enqueued_with(job: AgentSessionJob) do
      post message_parent_api_v1_session_path(child.id), params: {
        message: "the deploy scripts live in the infra root", reason: "wrong_scope"
      }, headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal parent.id, json["parent_session"]["id"]
    assert_equal "sent", json["delivery"]
    assert_equal "running", parent.reload.status
    assert_match(/the deploy scripts live in the infra root/, parent.metadata["pending_follow_up_prompt"])
  end

  test "should queue a child's report for a running parent" do
    parent = sessions(:running)
    child = sessions(:waiting)
    child.update!(parent_session_id: parent.id)

    assert_difference "EnqueuedMessage.count", 1 do
      post message_parent_api_v1_session_path(child.id), params: {
        message: "no ssh key on this box", reason: "missing_tools"
      }, headers: @headers
    end

    assert_response :accepted
    json = JSON.parse(response.body)
    assert_equal "queued", json["delivery"]
    assert_equal "pending", json["enqueued_message"]["status"]
    assert_equal "caller", parent.enqueued_messages.sole.origin
  end

  test "should reject a report with no message or an unknown reason" do
    parent = sessions(:needs_input)
    child = sessions(:waiting)
    child.update!(parent_session_id: parent.id)

    post message_parent_api_v1_session_path(child.id), params: { reason: "wrong_scope" }, headers: @headers
    assert_response :unprocessable_entity
    assert_match(/message is required/, JSON.parse(response.body)["message"])

    post message_parent_api_v1_session_path(child.id), params: { message: "x", reason: "vibes" }, headers: @headers
    assert_response :unprocessable_entity
    assert_match(/wrong_scope, missing_tools, other/, JSON.parse(response.body)["message"])
  end

  test "should reject a report from a session with no parent" do
    post message_parent_api_v1_session_path(sessions(:waiting).id), params: {
      message: "stuck", reason: "other"
    }, headers: @headers

    assert_response :unprocessable_entity
    assert_match(/has no parent session/, JSON.parse(response.body)["message"])
  end

  test "should refuse an archived parent rather than deliver into the trash" do
    parent = sessions(:archived)
    child = sessions(:waiting)
    child.update!(parent_session_id: parent.id)

    post message_parent_api_v1_session_path(child.id), params: {
      message: "wrong root", reason: "wrong_scope"
    }, headers: @headers

    assert_response :conflict
    assert_match(/unarchive_parent/, JSON.parse(response.body)["message"])
    assert_equal "archived", parent.reload.status
    assert_empty parent.enqueued_messages
  end

  test "should reject follow-up without prompt" do
    session = sessions(:needs_input)
    post follow_up_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Missing parameter", json["error"]
  end

  test "should queue follow-up to running session as enqueued message" do
    session = sessions(:running)

    assert_difference "EnqueuedMessage.count", 1 do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Follow-up prompt"
      }, headers: @headers
    end

    assert_response :accepted
    json = JSON.parse(response.body)
    assert_includes json["message"], "queued"
    assert json["enqueued_message"].present?
    assert_equal "pending", json["enqueued_message"]["status"]
    assert_equal 1, json["enqueued_message"]["position"]

    # Verify the enqueued message was created correctly
    enqueued = session.enqueued_messages.last
    assert_equal "Follow-up prompt", enqueued.content
    assert_equal "pending", enqueued.status
  end

  test "should reject follow-up to failed session" do
    session = sessions(:failed)
    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Follow-up prompt"
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["message"], "failed"
  end

  test "should reject follow-up to archived session" do
    session = sessions(:archived)
    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Follow-up prompt"
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["message"], "archived"
  end

  test "should send follow-up to waiting session" do
    session = sessions(:waiting)

    assert_enqueued_with(job: AgentSessionJob) do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Follow-up prompt"
      }, headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Follow-up prompt sent", json["message"]
    assert_equal "running", session.reload.status
  end

  test "should queue multiple follow-ups to running session with correct positions" do
    session = sessions(:running)

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "First message"
    }, headers: @headers
    assert_response :accepted

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Second message"
    }, headers: @headers
    assert_response :accepted

    json = JSON.parse(response.body)
    assert_equal 2, json["enqueued_message"]["position"]

    assert_equal 2, session.enqueued_messages.pending.count
    assert_equal "First message", session.enqueued_messages.ordered.first.content
    assert_equal "Second message", session.enqueued_messages.ordered.last.content
  end

  test "should reject follow-up with prompt exceeding max length" do
    session = sessions(:needs_input)
    long_prompt = "x" * (Session::PROMPT_MAX_LENGTH + 1)

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: long_prompt
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Validation failed", json["error"]
    assert_includes json["message"], "too long"
  end

  test "should queue follow-up with goal to running session" do
    session = sessions(:running)

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Do this task",
      goal: "PR is merged"
    }, headers: @headers

    assert_response :accepted
    enqueued = session.enqueued_messages.last
    assert_equal "Do this task", enqueued.content
    assert_equal "PR is merged", enqueued.goal
  end

  test "should preserve session goal on queued follow-up when goal param is omitted" do
    session = sessions(:running)
    session.update!(goal: "existing goal")

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "No goal change"
    }, headers: @headers

    assert_response :accepted
    assert_nil session.enqueued_messages.last.goal
    assert_equal "existing goal", session.reload.goal
  end

  # Goal on the direct (immediate) path — waiting/needs_input sessions.
  # These three branches (direct, force_immediate, running) must agree on goal
  # handling: a non-blank goal is applied, a blank or absent one preserves
  # whatever goal the session already has.
  test "should apply goal on direct follow-up to needs_input session" do
    session = sessions(:needs_input)
    session.update!(goal: "old condition")

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Follow-up prompt",
      goal: "new condition"
    }, headers: @headers

    assert_response :success
    assert_equal "new condition", session.reload.goal
    assert_equal "new condition", JSON.parse(response.body)["session"]["goal"]
  end

  test "should log a goal change on direct follow-up" do
    session = sessions(:needs_input)
    session.update!(goal: "old condition")

    assert_difference -> { session.logs.where(content: "Goal updated from follow-up").count }, 1 do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Goal changed",
        goal: "new condition"
      }, headers: @headers
    end

    assert_response :success
  end

  test "should not log a goal change on direct follow-up when the goal is unchanged" do
    session = sessions(:needs_input)
    session.update!(goal: "same goal")

    assert_no_difference -> { session.logs.where(content: "Goal updated from follow-up").count } do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Goal unchanged",
        goal: "same goal"
      }, headers: @headers
    end

    assert_response :success
    assert_equal "same goal", session.reload.goal
  end

  test "should apply goal on direct follow-up to waiting session" do
    session = sessions(:waiting)

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Follow-up prompt",
      goal: "PR is merged"
    }, headers: @headers

    assert_response :success
    assert_equal "PR is merged", session.reload.goal
  end

  test "should preserve session goal on direct follow-up when goal param is omitted" do
    session = sessions(:needs_input)
    session.update!(goal: "existing goal")

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "No goal change"
    }, headers: @headers

    assert_response :success
    assert_equal "existing goal", session.reload.goal
  end

  test "should preserve session goal on direct follow-up when goal param is blank" do
    session = sessions(:needs_input)
    session.update!(goal: "existing goal")

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Blank goal",
      goal: "   "
    }, headers: @headers

    assert_response :success
    assert_equal "existing goal", session.reload.goal
  end

  test "should reject direct follow-up with goal exceeding max length without touching the session" do
    session = sessions(:needs_input)
    session.update!(goal: "existing goal")
    original_prompt = session.prompt

    assert_no_enqueued_jobs only: AgentSessionJob do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Follow-up prompt",
        goal: "x" * (Session::GOAL_MAX_LENGTH + 1)
      }, headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Validation failed", json["error"]
    assert_includes json["message"], "goal is too long"

    session.reload
    assert_equal "existing goal", session.goal
    assert_equal original_prompt, session.prompt
    assert_equal "needs_input", session.status
  end

  test "should reject queued follow-up with goal exceeding max length" do
    session = sessions(:running)

    assert_no_difference "EnqueuedMessage.count" do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Follow-up prompt",
        goal: "x" * (Session::GOAL_MAX_LENGTH + 1)
      }, headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Validation failed", json["error"]
    assert_includes json["message"], "goal is too long"
  end

  test "should reject force_immediate follow-up with goal exceeding max length" do
    session = sessions(:running)

    assert_no_difference "EnqueuedMessage.count" do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Follow-up prompt",
        goal: "x" * (Session::GOAL_MAX_LENGTH + 1),
        force_immediate: true
      }, headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Validation failed", json["error"]
    assert_includes json["message"], "goal is too long"
  end

  # force_immediate follow-up tests
  test "should send follow-up immediately to running session with force_immediate" do
    session = sessions(:running)

    original_prompt = session.prompt

    assert_no_difference "EnqueuedMessage.count" do
      assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Urgent message" ]) do
        post follow_up_api_v1_session_path(session.id), params: {
          prompt: "Urgent message",
          force_immediate: true
        }, headers: @headers
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Follow-up prompt sent immediately", json["message"]
    assert_equal "running", json["session"]["status"]
    # force_immediate delivers the prompt via the enqueued-message/processor
    # path (the AgentSessionJob argument asserted above), consistent with the
    # web interrupt button and the plain queue path. The session's original
    # prompt column is intentionally preserved, not overwritten.
    assert_equal original_prompt, session.reload.prompt
  end

  test "should send follow-up immediately to needs_input session with force_immediate" do
    session = sessions(:needs_input)

    assert_enqueued_with(job: AgentSessionJob) do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Immediate message",
        force_immediate: true
      }, headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Follow-up prompt sent immediately", json["message"]
  end

  test "should send follow-up immediately to waiting session with force_immediate" do
    session = sessions(:waiting)

    assert_enqueued_with(job: AgentSessionJob) do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Immediate message",
        force_immediate: true
      }, headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Follow-up prompt sent immediately", json["message"]
  end

  test "should reject force_immediate follow-up to failed session" do
    session = sessions(:failed)
    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Urgent message",
      force_immediate: true
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["message"], "failed"
  end

  test "should reject force_immediate follow-up to archived session" do
    session = sessions(:archived)
    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Urgent message",
      force_immediate: true
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["message"], "archived"
  end

  test "should update goal with force_immediate" do
    session = sessions(:running)
    session.update!(goal: "old condition")

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Update goal",
      goal: "new condition",
      force_immediate: true
    }, headers: @headers

    assert_response :success
    assert_equal "new condition", session.reload.goal
  end

  test "should preserve session goal with force_immediate when goal param is omitted" do
    session = sessions(:running)
    session.update!(goal: "existing goal")

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "No goal change",
      force_immediate: true
    }, headers: @headers

    assert_response :success
    assert_equal "existing goal", session.reload.goal
  end

  test "should preserve session goal with force_immediate when goal param is blank" do
    session = sessions(:running)
    session.update!(goal: "existing goal")

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Blank goal",
      goal: "",
      force_immediate: true
    }, headers: @headers

    assert_response :success
    assert_equal "existing goal", session.reload.goal
  end

  test "should reset sigterm retry state with force_immediate" do
    session = sessions(:running)
    session.update!(metadata: {
      "sigterm_retry_count" => 2,
      "sigterm_retry_timestamps" => [ "2024-01-01" ],
      "last_sigterm_at" => "2024-01-01",
      "other_key" => "preserved"
    })

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Reset sigterm",
      force_immediate: true
    }, headers: @headers

    assert_response :success
    metadata = session.reload.metadata
    assert_nil metadata["sigterm_retry_count"]
    assert_nil metadata["sigterm_retry_timestamps"]
    assert_nil metadata["last_sigterm_at"]
    assert_equal "preserved", metadata["other_key"]
  end

  test "should create log entry with force_immediate" do
    session = sessions(:running)

    post follow_up_api_v1_session_path(session.id), params: {
      prompt: "Logged message",
      force_immediate: true
    }, headers: @headers

    assert_response :success
    assert session.logs.exists?([ "content LIKE ?", "%force_immediate%" ])
  end

  test "should not create enqueued message with force_immediate on running session" do
    session = sessions(:running)

    assert_no_difference "EnqueuedMessage.count" do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "No queue",
        force_immediate: true
      }, headers: @headers
    end

    assert_response :success
  end

  test "should still queue without force_immediate on running session" do
    session = sessions(:running)

    assert_difference "EnqueuedMessage.count", 1 do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "Should queue"
      }, headers: @headers
    end

    assert_response :accepted
  end

  test "should accept force_immediate as string true" do
    session = sessions(:needs_input)

    assert_enqueued_with(job: AgentSessionJob) do
      post follow_up_api_v1_session_path(session.id), params: {
        prompt: "String param",
        force_immediate: "true"
      }, headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Follow-up prompt sent immediately", json["message"]
  end

  test "should reject force_immediate follow-up without prompt" do
    session = sessions(:running)
    post follow_up_api_v1_session_path(session.id), params: {
      force_immediate: true
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Missing parameter", json["error"]
  end

  # Pause tests
  test "should pause running session" do
    session = sessions(:running)
    post pause_api_v1_session_path(session.id), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "needs_input", json["session"]["status"]
  end

  test "should not pause non-running session" do
    session = sessions(:waiting)
    post pause_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Cannot pause", json["error"]
  end

  # Sleep tests
  test "should sleep needs_input session" do
    session = sessions(:running)
    session.update!(status: :needs_input)

    post sleep_api_v1_session_path(session.id), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "waiting", json["session"]["status"]
  end

  test "should accept sleep for running session and set pending_sleep flag" do
    session = sessions(:running)
    post sleep_api_v1_session_path(session.id), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "running", json["session"]["status"]

    session.reload
    assert_equal true, session.metadata["pending_sleep"]
  end

  test "should not sleep failed session" do
    session = sessions(:running)
    session.update!(status: :failed)
    post sleep_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Cannot sleep", json["error"]
  end

  test "should not sleep archived session" do
    session = sessions(:running)
    session.update!(status: :archived)
    post sleep_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Cannot sleep", json["error"]
  end

  test "should not sleep waiting session" do
    session = sessions(:waiting)
    post sleep_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Cannot sleep", json["error"]
  end

  # Restart tests
  test "should restart needs_input session" do
    clone_path = Rails.root.join("tmp", "test_api_restart_needs_input")
    FileUtils.mkdir_p(clone_path)

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => clone_path.to_s, "working_directory" => clone_path.to_s }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Session restarted", json["message"]
    assert_equal "running", session.reload.status
  ensure
    FileUtils.rm_rf(clone_path)
  end

  # A pause outranks precedence and scheduling class, and REST is a non-interactive
  # door onto the same start `action_session restart` guards — a script or an
  # integration working a queue, not a person taking one session over. Without this
  # the refusal was reachable through MCP and not through the API, and `resume!`
  # here would have consumed the pause before any deeper guard could see it.
  test "should refuse to restart a session paused until a time it has not reached" do
    clone_path = Rails.root.join("tmp", "test_api_restart_paused")
    FileUtils.mkdir_p(clone_path)

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => clone_path.to_s, "working_directory" => clone_path.to_s,
                  "agent_root_key" => "zimmer" }
    )
    trigger = Sessions::ScheduleWakeUp.call(
      session: session,
      wake_at: 3.hours.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S"),
      prompt: "Resume after the pause"
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :unprocessable_entity
    assert_match(/does not start early/, JSON.parse(response.body)["message"])
    assert_equal "waiting", session.reload.status
    assert Trigger.exists?(trigger.id), "refusing must leave the pause armed"
  ensure
    FileUtils.rm_rf(clone_path)
  end

  test "should restart failed session" do
    clone_path = Rails.root.join("tmp", "test_api_restart_failed")
    FileUtils.mkdir_p(clone_path)

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => clone_path.to_s, "working_directory" => clone_path.to_s }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :success
  ensure
    FileUtils.rm_rf(clone_path)
  end

  test "should not restart archived session" do
    session = sessions(:archived)
    post restart_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Cannot restart", json["error"]
  end

  # The inverse guard for zimmer#557. A session holding a transcript with no
  # session_id HAS work — that is what a fresh-start recovery leaves behind on a
  # runtime that mints its own conversation id — so it must stay refused rather
  # than being restarted from scratch, which would discard the conversation.
  test "should not restart session with a transcript but no session_id" do
    session = sessions(:failed)
    session.update!(transcript: %({"type":"user","message":{"role":"user","content":"Hi"}}\n))

    assert_no_enqueued_jobs only: AgentSessionJob do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Cannot restart", json["error"]
    assert_equal "Session has no session_id", json["message"]
    assert_equal "failed", session.reload.status
  end

  # zimmer#557, reproducing session 6026: created by a trigger, held by the spot
  # gate, paused into needs_input by recovery — no session_id, no transcript, no
  # clone. Restarting it was refused with "Session has no session_id", which is a
  # precondition for RESUMING a conversation and says nothing about a session
  # that never had one. Its prompt and configuration are intact, so it starts.
  test "should restart a session that never ran by starting it from scratch" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Investigate the flaky test",
      status: :needs_input,
      metadata: { "paused_by" => "recovery" }
    )
    assert session.never_ran?

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Session restarted from scratch", json["message"]

    session.reload
    assert_equal "running", session.status
    assert_equal "Investigate the flaky test", session.prompt
  end

  test "should restart session without working directory by letting job handle clone recreation" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: {}
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Session restarted", json["message"]
  end

  test "should restart from scratch when git clone failed" do
    session = Session.create!(
      prompt: "Fix the auth bug",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      metadata: { "failure_reason" => "git_clone_failed" }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Session restarted from scratch", json["message"]

    session.reload
    assert_equal "running", session.status
    assert_nil session.session_id
    assert_nil session.metadata["failure_reason"]
    assert_nil session.metadata["clone_path"]
  end

  # AgentSessionJob receives images and files ONLY as job arguments, so a restart
  # that enqueued bare re-ran the original prompt with the screenshot silently
  # missing (#746). The bytes were on the durable volume the whole time.
  test "should restart from scratch carrying the attachments the first turn was created with" do
    session = Session.create!(
      prompt: "here is the screenshot, fix this",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      metadata: { "failure_reason" => "git_clone_failed" }
    )
    image = store_image_for(session)
    file = store_file_for(session, filename: "notes.txt", content: "read me")

    post restart_api_v1_session_path(session.id), headers: @headers

    assert_response :success
    assert_enqueued_with(
      job: AgentSessionJob,
      args: [
        session.id, nil,
        {
          images: [ { path: image[:path], media_type: "image/png" } ],
          files: [ { path: file[:path], original_filename: "notes.txt", size: "read me".bytesize } ]
        }
      ]
    )
    assert session.logs.where("content LIKE ?", "%carrying 1 image and 1 file%").exists?
  end

  # This path is taken when something has ALREADY gone wrong. A storage tree that
  # cannot be read must cost the attachments, never the restart.
  test "should still restart from scratch when the attachment storage cannot be read" do
    session = Session.create!(
      prompt: "here is the screenshot, fix this",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      metadata: { "failure_reason" => "git_clone_failed" }
    )
    store_image_for(session)

    ImageStorageService.stub(:stored_for, ->(*) { raise Errno::EACCES, "storage" }) do
      assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
        post restart_api_v1_session_path(session.id), headers: @headers
      end
    end

    assert_response :success
    assert_equal "running", session.reload.status
  end

  test "should not restart from scratch without git_root" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      metadata: { "failure_reason" => "git_clone_failed" }
    )
    # Clear git_root to simulate a session missing it
    session.update_column(:git_root, nil)

    post restart_api_v1_session_path(session.id), headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/git_root/i, json["message"])
  end

  test "should clear transcript polling metadata on restart" do
    clone_path = Rails.root.join("tmp", "test_api_restart_metadata_clear")
    FileUtils.mkdir_p(clone_path)

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "broadcast_message_count" => 42,
        "transcript_waiting_logged" => true,
        "transcript_files_waiting_logged" => true,
        "transcript_reading_started_logged" => true,
        "sigterm_retry_count" => 3
      }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :success
    session.reload

    # Transcript polling metadata should be cleared
    assert_nil session.metadata["broadcast_message_count"]
    assert_nil session.metadata["transcript_waiting_logged"]
    assert_nil session.metadata["transcript_files_waiting_logged"]
    assert_nil session.metadata["transcript_reading_started_logged"]
    # Other stale retry metadata should also be cleared
    assert_nil session.metadata["sigterm_retry_count"]
    # Non-stale metadata should be preserved
    assert_equal clone_path.to_s, session.metadata["clone_path"]
    assert_equal clone_path.to_s, session.metadata["working_directory"]
  ensure
    FileUtils.rm_rf(clone_path)
  end

  test "should clear quota limit metadata on restart to prevent stale re-detection" do
    clone_path = Rails.root.join("tmp", "test_api_restart_quota_clear")
    FileUtils.mkdir_p(clone_path)

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "quota_limit_count" => 4,
        "last_quota_limit_at" => "2026-03-28T22:07:55Z",
        "last_quota_limit_message" => "You've hit your limit · resets 11pm (UTC)",
        "api_error_retry_count" => 3,
        "api_error_last_checked_line" => 2264,
        "exit_status" => "Account quota limit reached — retry skipped (resets at time shown in error)"
      }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :success
    session.reload

    # Quota limit metadata should be cleared to prevent stale re-detection
    assert_nil session.metadata["quota_limit_count"],
      "quota_limit_count must be cleared on restart to prevent re-detecting old quota errors"
    assert_nil session.metadata["last_quota_limit_at"],
      "last_quota_limit_at must be cleared on restart"
    assert_nil session.metadata["last_quota_limit_message"],
      "last_quota_limit_message must be cleared on restart"
    # exit_status should be cleared so stale quota error messages don't persist
    assert_nil session.metadata["exit_status"],
      "exit_status must be cleared on restart to prevent stale exit status from persisting in UI"
    # API error retry count should be cleared (fresh retry budget)
    assert_nil session.metadata["api_error_retry_count"]
    # api_error_last_checked_line is intentionally preserved — it tracks the scan
    # position (which errors have been handled), not retry state. Clearing it would
    # cause old errors to be re-detected and misclassified.
    assert_equal 2264, session.metadata["api_error_last_checked_line"]
    # Non-stale metadata should be preserved
    assert_equal clone_path.to_s, session.metadata["clone_path"]
  ensure
    FileUtils.rm_rf(clone_path)
  end

  test "should restart pre-prompt failure with initial prompt and clear runtime_started" do
    clone_path = Rails.root.join("tmp", "test_api_restart_pre_prompt")
    FileUtils.mkdir_p(clone_path)

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Deploy the new feature",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "failure_reason" => "mcp_connection_failed",
        "runtime_started" => true
      }
    )

    # Should re-send original prompt, not system recovery
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Deploy the new feature" ]) do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :success
    session.reload
    assert_equal "running", session.status

    # runtime_started must be cleared for pre-prompt failures
    assert_nil session.metadata["runtime_started"]
    assert_nil session.metadata["failure_reason"]
  ensure
    FileUtils.rm_rf(clone_path)
  end

  test "should preserve runtime_started on restart for post-prompt failures" do
    clone_path = Rails.root.join("tmp", "test_api_restart_post_prompt")
    FileUtils.mkdir_p(clone_path)

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Fix the bug",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "failure_reason" => "process_failed",
        "runtime_started" => true
      }
    )

    # Should use system recovery prompt for post-prompt failures
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_api_v1_session_path(session.id), headers: @headers
    end

    assert_response :success
    session.reload
    assert_equal "running", session.status

    # runtime_started must be preserved for post-prompt failures
    assert_equal true, session.metadata["runtime_started"]
  ensure
    FileUtils.rm_rf(clone_path)
  end

  # Search tests
  test "search should require query parameter" do
    get search_api_v1_sessions_path, headers: @headers
    assert_response :bad_request

    json = JSON.parse(response.body)
    assert_equal "Missing parameter", json["error"]
    assert_includes json["message"], "q (search query) is required"
  end

  test "search should return empty query error for blank query" do
    get search_api_v1_sessions_path, params: { q: "   " }, headers: @headers
    assert_response :bad_request
  end

  test "search should find sessions by title" do
    # Create a session with a unique title
    session = Session.create!(
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "UniqueSearchableTitle12345"
    )

    get search_api_v1_sessions_path, params: { q: "UniqueSearchableTitle" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("sessions")
    assert json.key?("query")
    assert json.key?("search_contents")
    assert json.key?("pagination")

    assert_equal "UniqueSearchableTitle", json["query"]
    assert_equal false, json["search_contents"]

    session_ids = json["sessions"].map { |s| s["id"] }
    assert_includes session_ids, session.id
  ensure
    session&.destroy
  end

  test "search should find sessions by metadata" do
    # Create a session with searchable metadata
    session = Session.create!(
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: { "searchable_key" => "unique_metadata_value_xyz" }
    )

    get search_api_v1_sessions_path, params: { q: "unique_metadata_value_xyz" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    session_ids = json["sessions"].map { |s| s["id"] }
    assert_includes session_ids, session.id
  ensure
    session&.destroy
  end

  test "search should find sessions by custom_metadata" do
    session = Session.create!(
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      custom_metadata: { "user_tag" => "special_custom_tag_abc" }
    )

    get search_api_v1_sessions_path, params: { q: "special_custom_tag_abc" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    session_ids = json["sessions"].map { |s| s["id"] }
    assert_includes session_ids, session.id
  ensure
    session&.destroy
  end

  test "search should not find transcript content by default" do
    session = sessions(:with_transcript)

    # Search for content that only exists in transcript
    get search_api_v1_sessions_path, params: { q: "I'd be happy to help" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    session_ids = json["sessions"].map { |s| s["id"] }
    assert_not_includes session_ids, session.id
  end

  test "search should find transcript content when search_contents is true" do
    session = sessions(:with_transcript)

    # Search for content in transcript with search_contents enabled
    get search_api_v1_sessions_path, params: { q: "I'd be happy to help", search_contents: "true" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["search_contents"]
    session_ids = json["sessions"].map { |s| s["id"] }
    assert_includes session_ids, session.id
  end

  test "search accepts the dashboard's search_contents=1 spelling too" do
    session = sessions(:with_transcript)

    get search_api_v1_sessions_path, params: { q: "I'd be happy to help", search_contents: "1" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["search_contents"],
      "a caller who copied the dashboard's query string must not get a silent title-only search"
    assert_includes json["sessions"].map { |s| s["id"] }, session.id
  end

  test "search accepts query as an alias for q" do
    get search_api_v1_sessions_path, params: { query: "UniqueSearchableTitle" }, headers: @headers
    assert_response :success

    assert_equal "UniqueSearchableTitle", JSON.parse(response.body)["query"]
  end

  test "a multi-word query is a phrase on the title path too" do
    phrase = Session.create!(
      title: "Kestrel manoeuvre", prompt: "p", git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code", status: :needs_input
    )
    apart = Session.create!(
      title: "Kestrel, and later a manoeuvre", prompt: "p", git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code", status: :needs_input
    )

    get search_api_v1_sessions_path, params: { q: "kestrel manoeuvre" }, headers: @headers
    assert_response :success

    ids = JSON.parse(response.body)["sessions"].map { |s| s["id"] }
    assert_includes ids, phrase.id
    assert_not_includes ids, apart.id,
      "the cheap search binds the whole query as one substring, exactly as the transcript one does"
  end

  test "content search reports how far it scanned instead of a total count" do
    get search_api_v1_sessions_path,
      params: { q: "I'd be happy to help", search_contents: "true" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    scan = json["content_scan"]
    assert scan["complete"]
    assert_not scan["timed_out"]
    assert scan["candidate_sessions"].positive?
    assert_nil scan["next_cursor"]
    # Counting matches over the transcript corpus costs exactly the full scan the
    # bounded search exists to avoid, so no count is offered rather than a wrong one.
    assert_nil json["pagination"]["total_count"]
  end

  test "content search hands back a cursor that resumes where it stopped" do
    older = Session.create!(
      title: "Older content match", prompt: "p", git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code", status: :needs_input, created_at: 3.days.ago,
      transcript: [ { "type" => "assistant", "message" => { "content" => "peregrine falcon" } } ]
    )
    newer = Session.create!(
      title: "Newer content match", prompt: "p", git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code", status: :needs_input, created_at: 1.day.ago,
      transcript: [ { "type" => "assistant", "message" => { "content" => "peregrine falcon" } } ]
    )

    get search_api_v1_sessions_path,
      params: { q: "peregrine falcon", search_contents: "true", per_page: 1 }, headers: @headers
    assert_response :success

    first = JSON.parse(response.body)
    assert_equal [ newer.id ], first["sessions"].map { |s| s["id"] }
    assert_not first["content_scan"]["complete"]
    cursor = first["content_scan"]["next_cursor"]
    assert cursor.present?

    get search_api_v1_sessions_path,
      params: { q: "peregrine falcon", search_contents: "true", per_page: 25, scan_cursor: cursor },
      headers: @headers
    assert_response :success

    second = JSON.parse(response.body)
    assert_equal [ older.id ], second["sessions"].map { |s| s["id"] }
    assert second["content_scan"]["complete"]
  end

  test "search should exclude archived sessions by default" do
    archived_session = sessions(:archived)
    # Set a searchable title on the archived session
    archived_session.update!(title: "ArchivedSessionSearchTest123")

    # Search for archived session's title
    get search_api_v1_sessions_path, params: { q: "ArchivedSessionSearchTest123" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    session_ids = json["sessions"].map { |s| s["id"] }
    assert_not_includes session_ids, archived_session.id
  end

  test "search should include archived sessions when show_archived is true" do
    archived_session = sessions(:archived)
    # Set a searchable title on the archived session
    archived_session.update!(title: "ArchivedSessionSearchTest456")

    get search_api_v1_sessions_path, params: { q: "ArchivedSessionSearchTest456", show_archived: "true" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    session_ids = json["sessions"].map { |s| s["id"] }
    assert_includes session_ids, archived_session.id
  end

  test "search should filter by status" do
    get search_api_v1_sessions_path, params: { q: "program", status: "running" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["sessions"].each do |session|
      assert_equal "running", session["status"]
    end
  end

  test "search should filter by agent_runtime" do
    get search_api_v1_sessions_path, params: { q: "test", agent_runtime: "claude_code" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["sessions"].each do |session|
      assert_equal "claude_code", session["agent_runtime"]
    end
  end

  test "search should paginate results" do
    get search_api_v1_sessions_path, params: { q: "test", page: 1, per_page: 2 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 1, json["pagination"]["page"]
    assert_equal 2, json["pagination"]["per_page"]
    assert json["sessions"].length <= 2
  end

  test "search should require authentication" do
    get search_api_v1_sessions_path, params: { q: "test" }
    assert_response :unauthorized
  end

  test "search should sanitize SQL wildcards in query" do
    # This test ensures % and _ characters in search queries don't cause SQL injection issues
    get search_api_v1_sessions_path, params: { q: "test%_injection" }, headers: @headers
    assert_response :success

    # Should not error and should return valid response
    json = JSON.parse(response.body)
    assert json.key?("sessions")
  end

  test "search should reject query over 1000 characters" do
    long_query = "a" * 1001
    get search_api_v1_sessions_path, params: { q: long_query }, headers: @headers
    assert_response :bad_request

    json = JSON.parse(response.body)
    assert_equal "Query too long", json["error"]
    assert_includes json["message"], "1000 characters"
  end

  # Response format tests
  test "should return JSON with correct content type" do
    get api_v1_sessions_path, headers: @headers
    assert_response :success
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "should return session with all expected fields" do
    session = sessions(:running)
    get api_v1_session_path(session.id), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["session"]
    expected_fields = %w[
      id slug title status agent_runtime prompt git_root branch subdirectory
      execution_provider goal mcp_servers all_mcp_servers injected_mcp_servers
      config metadata custom_metadata session_id job_id running_job_id
      archived_at created_at updated_at
    ]

    expected_fields.each do |field|
      assert json.key?(field), "Expected field '#{field}' to be present"
    end
  end

  # Consumers (e.g. the Zimmer router) need an unambiguous answer to "which MCP
  # servers does this session actually have wired?". `injected_mcp_servers` is
  # only the auto-injected subset and legitimately omits every user-selected
  # server on a healthy session, so it must never be read as that answer.
  # `all_mcp_servers` is the effective set.
  test "session response distinguishes selected, injected, and effective MCP servers" do
    ServersConfig.stubs(:exists?).returns(true)
    session = sessions(:running)
    session.update!(
      mcp_servers: [ "digitalocean-tadasant" ],
      custom_metadata: { "injected_mcp_servers" => [ "agent-orchestrator-prod-self-session" ] }
    )

    get api_v1_session_path(session.id), headers: @headers
    assert_response :success
    json = JSON.parse(response.body)["session"]

    assert_equal [ "digitalocean-tadasant" ], json["mcp_servers"],
      "mcp_servers is only the explicitly selected list"
    assert_equal [ "agent-orchestrator-prod-self-session" ], json["injected_mcp_servers"],
      "injected_mcp_servers is only the auto-injected subset"
    assert_equal [ "digitalocean-tadasant", "agent-orchestrator-prod-self-session" ],
      json["all_mcp_servers"],
      "all_mcp_servers is the effective set a consumer should read"

    assert_not_includes json["injected_mcp_servers"], "digitalocean-tadasant",
      "a healthy session's injected_mcp_servers omits selected servers — a narrow " \
      "value here is not evidence that a server was lost"
  end
end

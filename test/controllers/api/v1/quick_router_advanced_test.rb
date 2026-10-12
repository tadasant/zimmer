# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

# The web bubble's Advanced accordion and attach buttons, on `POST /api/v1/quick_router`:
# harness, model, spot, a parent session and inline attachments, validated the way the
# bubble validates them, so the iOS app can offer what the web does.
class Api::V1::QuickRouterAdvancedTest < ActionDispatch::IntegrationTest
  include AttachmentFixtures

  setup do
    @original_env = ENV[ApiKey::ENV_VAR]
    ENV[ApiKey::ENV_VAR] = "fleet-wide-env-key"
    _key, token = ApiKey.mint!(name: "chrome on the laptop", grant: ApiKey::QUICK_ROUTER_GRANT)
    @headers = { "X-API-Key" => token }

    AgentRootsConfig.stubs(:find!).with(AgentRootsConfig.router_root_name).returns(
      OpenStruct.new(url: "https://github.com/test/repo.git", default_branch: "main",
                     subdirectory: "agent-roots/zimmer-orchestrator", default_mcp_servers: [])
    )
    AgentSessionJob.stubs(:enqueue_new_session)
    Session.any_instance.stubs(:broadcast_status_change)
  end

  teardown do
    @original_env.nil? ? ENV.delete(ApiKey::ENV_VAR) : ENV[ApiKey::ENV_VAR] = @original_env
    cleanup_stored_attachments!
  end

  def post_router(**params)
    post api_v1_quick_router_path, params: { prompt: "Fix the login bug" }.merge(params), headers: @headers, as: :json
  end

  def created_session
    Session.find(JSON.parse(response.body)["session_id"])
  end

  # --- Harness and model ---

  test "the session runs on the harness and model posted" do
    model = ModelCatalog.model_ids_for("codex").first

    post_router(agent_runtime: "codex", model: model)

    assert_response :created
    created = created_session
    assert_equal "codex", created.agent_runtime
    assert_equal model, created.config["model"]
  end

  test "harness and model are left to the ordinary chain when neither is posted" do
    post_router

    assert_response :created
    created = created_session
    assert_equal QuickRouterOptions.new.default_runtime, created.agent_runtime
  end

  test "an unregistered harness is refused without creating a session" do
    assert_no_difference("Session.count") { post_router(agent_runtime: "not-a-runtime") }

    assert_response :unprocessable_entity
    assert_equal "That harness is not available.", JSON.parse(response.body)["message"]
  end

  test "a model that does not belong to the posted harness is refused" do
    claude_model = ModelCatalog.model_ids_for("claude_code").first

    assert_no_difference("Session.count") { post_router(agent_runtime: "codex", model: claude_model) }

    assert_response :unprocessable_entity
    assert_equal "That model is not available for the Codex harness.", JSON.parse(response.body)["message"]
  end

  # --- Spot ---

  test "scheduling_class spot lands at the top of the spot queue" do
    post_router(scheduling_class: "spot")

    assert_response :created
    created = created_session
    assert_equal SessionGenesis::SPOT, created.scheduling_class
    assert_equal Session.precedence_for_place(SessionPrecedence::PLACE_TOP_OF_SPOT), created.precedence
  end

  test "anything but spot leaves the class alone" do
    post_router(scheduling_class: "priority")
    assert_response :created
    assert_nil created_session.scheduling_class, "an extension start keeps deriving its class from its genesis"
  end

  # --- Parent ---

  test "a parent session threads the new one under it" do
    parent = sessions(:needs_input)

    post_router(parent_session_id: parent.id)

    assert_response :created
    assert_equal parent.id, created_session.parent_session_id
  end

  test "a parent that does not exist is refused" do
    assert_no_difference("Session.count") { post_router(parent_session_id: 999_999) }

    assert_response :unprocessable_entity
    assert_match(/parent_session_id/, JSON.parse(response.body)["message"])
  end

  # --- Attachments ---

  def attachments
    [
      { filename: "screen.png", media_type: "image/png", data: Base64.strict_encode64(minimal_png) },
      { filename: "deploy.log", media_type: "text/plain", data: Base64.strict_encode64("deploy failed at step 3\n") }
    ]
  end

  test "attachments are stored under the new session and handed to its first turn" do
    AgentSessionJob.unstub(:enqueue_new_session)
    AgentSessionJob.expects(:enqueue_new_session).with do |id, images:, files:|
      id == Session.maximum(:id) &&
        images.sole[:media_type] == "image/png" && File.exist?(images.sole[:path]) &&
        files.sole[:original_filename] == "deploy.log" && File.read(files.sole[:path]) == "deploy failed at step 3\n"
    end

    post_router(attachments: attachments)

    assert_response :created, response.body
    created = created_session
    remember_storage(ImageStorageService.new(session_id: created.id))
    remember_storage(FileStorageService.new(session_id: created.id))
    assert_equal 1, ImageStorageService.new(session_id: created.id).list.size
    assert_equal 1, FileStorageService.new(session_id: created.id).list.size
  end

  test "a bad attachment refuses the prompt before any session exists" do
    assert_no_difference("Session.count") do
      post_router(attachments: [ { filename: "notes.txt", media_type: "text/plain", data: "%%%" } ])
    end
    assert_response :unprocessable_entity
    assert_equal "Invalid attachment", JSON.parse(response.body)["error"]
    assert_match(/not valid base64/, JSON.parse(response.body)["message"])

    assert_no_difference("Session.count") { post_router(attachments: "abc") }
    assert_response :unprocessable_entity

    too_many = Array.new(InlineAttachments::LIMIT + 1) { { filename: "f.txt", data: "eA==" } }
    assert_no_difference("Session.count") { post_router(attachments: too_many) }
    assert_response :unprocessable_entity
    assert_equal "Too many attachments", JSON.parse(response.body)["error"]
    assert_match(/Quick Router prompt carries at most/, JSON.parse(response.body)["message"])
  end

  test "a body over the limit is refused before it is read" do
    Api::V1::QuickRouterController.stubs(:body_limit).returns(100)

    assert_no_difference("Session.count") { post_router(attachments: attachments) }
    assert_response :content_too_large
  end

  # --- Everything together ---

  test "harness, model, spot and a parent ride together" do
    model = ModelCatalog.model_ids_for("codex").first
    parent = sessions(:needs_input)

    post_router(agent_runtime: "codex", model: model, scheduling_class: "spot", parent_session_id: parent.id)

    assert_response :created
    created = created_session
    assert_equal "codex", created.agent_runtime
    assert_equal model, created.config["model"]
    assert_equal SessionGenesis::SPOT, created.scheduling_class
    assert_equal parent.id, created.parent_session_id
    assert_equal "Fix the login bug", created.metadata["original_prompt"]
  end
end

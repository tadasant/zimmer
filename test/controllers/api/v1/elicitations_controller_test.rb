# frozen_string_literal: true

require "test_helper"

class Api::V1::ElicitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @session = sessions(:elicitation_session)
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # === POST /api/v1/elicitations (create) ===

  test "should create elicitation with valid params" do
    request_id = "req-#{SecureRandom.hex(8)}"

    assert_difference("Elicitation.count") do
      post api_v1_elicitations_path,
        params: {
          mode: "form",
          message: "Confirm sending email to user@example.com",
          requestedSchema: { type: "object", properties: { confirmed: { type: "boolean" } } },
          _meta: {
            "com.pulsemcp/request-id" => request_id,
            "com.pulsemcp/session-id" => @session.id.to_s,
            "com.pulsemcp/tool-name" => "send_email",
            "com.pulsemcp/context" => "User wants to send an email"
          }
        },
        as: :json
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "pending", json["action"]
    assert_equal request_id, json["_meta"]["com.pulsemcp/request-id"]
    assert json["_meta"]["com.pulsemcp/poll-url"].present?

    # Verify elicitation was created correctly
    elicitation = Elicitation.find_by!(request_id: request_id)
    assert_equal @session.id, elicitation.session_id
    assert_equal "form", elicitation.mode
    assert_equal "send_email", elicitation.tool_name
    assert_equal "pending", elicitation.status
  end

  test "should create elicitation with default mode" do
    request_id = "req-#{SecureRandom.hex(8)}"

    post api_v1_elicitations_path,
      params: {
        message: "Confirm action",
        _meta: {
          "com.pulsemcp/request-id" => request_id,
          "com.pulsemcp/session-id" => @session.id.to_s
        }
      },
      as: :json

    assert_response :created
    elicitation = Elicitation.find_by!(request_id: request_id)
    assert_equal "form", elicitation.mode
  end

  test "should set default expiration when none provided" do
    request_id = "req-#{SecureRandom.hex(8)}"

    post api_v1_elicitations_path,
      params: {
        message: "Confirm action",
        _meta: {
          "com.pulsemcp/request-id" => request_id,
          "com.pulsemcp/session-id" => @session.id.to_s
        }
      },
      as: :json

    assert_response :created
    elicitation = Elicitation.find_by!(request_id: request_id)
    assert_not_nil elicitation.expires_at
    assert_in_delta 10.minutes.from_now, elicitation.expires_at, 5.seconds
  end

  test "should use provided expiration" do
    request_id = "req-#{SecureRandom.hex(8)}"
    expires_at = 30.minutes.from_now.iso8601

    post api_v1_elicitations_path,
      params: {
        message: "Confirm action",
        _meta: {
          "com.pulsemcp/request-id" => request_id,
          "com.pulsemcp/session-id" => @session.id.to_s,
          "com.pulsemcp/expires-at" => expires_at
        }
      },
      as: :json

    assert_response :created
    elicitation = Elicitation.find_by!(request_id: request_id)
    assert_in_delta Time.parse(expires_at), elicitation.expires_at, 2.seconds
  end

  test "should return 422 when request_id is missing" do
    post api_v1_elicitations_path,
      params: {
        message: "Confirm action",
        _meta: {
          "com.pulsemcp/session-id" => @session.id.to_s
        }
      },
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Missing parameter", json["error"]
  end

  test "should return 422 when message is missing" do
    post api_v1_elicitations_path,
      params: {
        _meta: {
          "com.pulsemcp/request-id" => "req-#{SecureRandom.hex(8)}",
          "com.pulsemcp/session-id" => @session.id.to_s
        }
      },
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Missing parameter", json["error"]
  end

  test "should return 404 when session not found" do
    post api_v1_elicitations_path,
      params: {
        message: "Confirm action",
        _meta: {
          "com.pulsemcp/request-id" => "req-#{SecureRandom.hex(8)}",
          "com.pulsemcp/session-id" => "99999999"
        }
      },
      as: :json

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Session not found", json["error"]
  end

  test "should return 404 and warn when session-id is blank (missing ELICITATION_SESSION_ID)" do
    # A blank session-id is the signature of an MCP server spawned without
    # ELICITATION_SESSION_ID (the @pulsemcp/mcp-elicitation library omits the tag
    # entirely). It must warn — not silently 404 — so obs surfaces the spawn-env defect.
    warned = false
    Rails.logger.stub(:warn, ->(msg) { warned = true if msg.to_s.include?("blank session-id") }) do
      post api_v1_elicitations_path,
        params: {
          message: "Confirm action",
          _meta: {
            "com.pulsemcp/request-id" => "req-#{SecureRandom.hex(8)}",
            "com.pulsemcp/session-id" => ""
          }
        },
        as: :json
    end

    assert_response :not_found
    assert warned, "expected a .warn log for a blank session-id elicitation POST"
  end

  test "should return 404 without warning when session-id is present but unknown" do
    # A present-but-unknown id is a plausible stale/expired session, not a spawn-env
    # defect — it must stay at .info so it doesn't add noise to the obs alert stream.
    # This pins the warn/info split so a refactor can't silently escalate it to .warn.
    warned = false
    Rails.logger.stub(:warn, ->(msg) { warned = true if msg.to_s.include?("session-id") }) do
      post api_v1_elicitations_path,
        params: {
          message: "Confirm action",
          _meta: {
            "com.pulsemcp/request-id" => "req-#{SecureRandom.hex(8)}",
            "com.pulsemcp/session-id" => "99999999"
          }
        },
        as: :json
    end

    assert_response :not_found
    refute warned, "a present-but-unknown session-id must not warn (info only)"
  end

  test "should return 422 for duplicate request_id" do
    existing = create_pending_elicitation

    post api_v1_elicitations_path,
      params: {
        message: "Confirm action",
        _meta: {
          "com.pulsemcp/request-id" => existing.request_id,
          "com.pulsemcp/session-id" => @session.id.to_s
        }
      },
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Unprocessable Entity", json["error"]
  end

  test "should enqueue push notification job" do
    request_id = "req-#{SecureRandom.hex(8)}"

    assert_enqueued_with(job: SendPushNotificationJob) do
      post api_v1_elicitations_path,
        params: {
          message: "Confirm sending email",
          _meta: {
            "com.pulsemcp/request-id" => request_id,
            "com.pulsemcp/session-id" => @session.id.to_s
          }
        },
        as: :json
    end
  end

  test "creating an elicitation flips the running session to needs_input without clearing running_job_id" do
    @session.update!(running_job_id: "job-live-123")
    assert_equal "running", @session.status
    request_id = "req-#{SecureRandom.hex(8)}"

    post api_v1_elicitations_path,
      params: {
        message: "Confirm sending email",
        _meta: {
          "com.pulsemcp/request-id" => request_id,
          "com.pulsemcp/session-id" => @session.id.to_s
        }
      },
      as: :json

    assert_response :created
    @session.reload
    assert_equal "needs_input", @session.status
    assert @session.blocked_on_elicitation?
    assert_equal "job-live-123", @session.running_job_id,
      "the live agent process must not be torn down on the elicitation flip"
  end

  test "should find session by slug" do
    @session.update!(slug: "test-session-slug-#{SecureRandom.hex(4)}")
    request_id = "req-#{SecureRandom.hex(8)}"

    post api_v1_elicitations_path,
      params: {
        message: "Confirm action",
        _meta: {
          "com.pulsemcp/request-id" => request_id,
          "com.pulsemcp/session-id" => @session.slug
        }
      },
      as: :json

    assert_response :created
    elicitation = Elicitation.find_by!(request_id: request_id)
    assert_equal @session.id, elicitation.session_id
  end

  # === GET /api/v1/elicitations/:id (show/poll) ===

  test "should return pending status for pending elicitation" do
    elicitation = create_pending_elicitation

    get api_v1_elicitation_path(elicitation.request_id)

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "pending", json["action"]
    assert_nil json["content"]
    assert_equal elicitation.request_id, json["_meta"]["com.pulsemcp/request-id"]
  end

  test "should return resolved status with content when accepted" do
    elicitation = create_resolved_elicitation

    get api_v1_elicitation_path(elicitation.request_id)

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "accept", json["action"]
    assert_equal({ "approved" => true }, json["content"])
    assert json["_meta"]["com.pulsemcp/responded-at"].present?
  end

  test "should auto-expire when past expiration" do
    elicitation = create_expired_elicitation
    assert_equal "pending", elicitation.status

    get api_v1_elicitation_path(elicitation.request_id)

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "expired", json["action"]

    elicitation.reload
    assert_equal "expired", elicitation.status
  end

  test "should return 404 for unknown request_id" do
    get api_v1_elicitation_path("nonexistent-request-id")

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Not Found", json["error"]
  end

  # === PATCH /api/v1/elicitations/:id/respond ===

  test "should accept a pending elicitation and return the poll response" do
    elicitation = create_pending_elicitation

    patch respond_api_v1_elicitation_path(elicitation.request_id),
      params: { action_type: "accept" },
      headers: @headers,
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "accept", json["action"]
    assert_equal elicitation.request_id, json["_meta"]["com.pulsemcp/request-id"]
    assert json["_meta"]["com.pulsemcp/responded-at"].present?

    elicitation.reload
    assert_equal "accept", elicitation.status
    assert_not_nil elicitation.responded_at
  end

  test "should decline a pending elicitation" do
    elicitation = create_pending_elicitation

    patch respond_api_v1_elicitation_path(elicitation.request_id),
      params: { action_type: "decline" },
      headers: @headers,
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "decline", json["action"]

    elicitation.reload
    assert_equal "decline", elicitation.status
  end

  test "should persist content when accepting with a form response" do
    elicitation = create_pending_elicitation

    patch respond_api_v1_elicitation_path(elicitation.request_id),
      params: { action_type: "accept", content: { confirmed: true, note: "looks good" } },
      headers: @headers,
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "accept", json["action"]
    assert_equal({ "confirmed" => true, "note" => "looks good" }, json["content"])

    elicitation.reload
    assert_equal({ "confirmed" => true, "note" => "looks good" }, elicitation.response_content)
  end

  test "should parse content supplied as a JSON string" do
    elicitation = create_pending_elicitation

    patch respond_api_v1_elicitation_path(elicitation.request_id),
      params: { action_type: "accept", content: '{"confirmed":true}' },
      headers: @headers,
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal({ "confirmed" => true }, json["content"])

    elicitation.reload
    assert_equal({ "confirmed" => true }, elicitation.response_content)
  end

  test "should return 401 when responding without an API key" do
    elicitation = create_pending_elicitation

    patch respond_api_v1_elicitation_path(elicitation.request_id),
      params: { action_type: "accept" },
      as: :json

    assert_response :unauthorized
    elicitation.reload
    assert_equal "pending", elicitation.status
  end

  test "should return 401 when responding with an invalid API key" do
    elicitation = create_pending_elicitation

    patch respond_api_v1_elicitation_path(elicitation.request_id),
      params: { action_type: "accept" },
      headers: { "X-API-Key" => "wrong-key" },
      as: :json

    assert_response :unauthorized
    elicitation.reload
    assert_equal "pending", elicitation.status
  end

  test "should return 404 when responding to an unknown request_id" do
    patch respond_api_v1_elicitation_path("nonexistent-request-id"),
      params: { action_type: "accept" },
      headers: @headers,
      as: :json

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Not Found", json["error"]
  end

  test "should return 422 when responding to a non-pending elicitation" do
    elicitation = create_resolved_elicitation

    patch respond_api_v1_elicitation_path(elicitation.request_id),
      params: { action_type: "accept" },
      headers: @headers,
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Unprocessable Entity", json["error"]

    elicitation.reload
    assert_equal "accept", elicitation.status
    assert_equal({ "approved" => true }, elicitation.response_content)
  end

  test "should return 422 for an invalid action_type" do
    elicitation = create_pending_elicitation

    patch respond_api_v1_elicitation_path(elicitation.request_id),
      params: { action_type: "cancel" },
      headers: @headers,
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Unprocessable Entity", json["error"]

    elicitation.reload
    assert_equal "pending", elicitation.status
  end

  private

  def create_pending_elicitation
    Elicitation.create!(
      session: @session,
      request_id: "req-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Confirm sending email",
      requested_schema: { "type" => "object" },
      meta: { "com.pulsemcp/request-id" => "test" },
      tool_name: "send_email",
      expires_at: 1.hour.from_now
    )
  end

  def create_expired_elicitation
    Elicitation.create!(
      session: @session,
      request_id: "req-expired-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Expired elicitation",
      requested_schema: { "type" => "object" },
      meta: {},
      expires_at: 1.hour.ago
    )
  end

  def create_resolved_elicitation
    Elicitation.create!(
      session: @session,
      request_id: "req-resolved-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Approve deployment",
      requested_schema: { "type" => "object" },
      meta: {},
      status: "accept",
      response_content: { "approved" => true },
      responded_at: 5.minutes.ago,
      expires_at: 1.hour.from_now
    )
  end
end

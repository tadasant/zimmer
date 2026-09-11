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
      post protocol_create_path,
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

    post protocol_create_path,
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

    post protocol_create_path,
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
    assert_in_delta Elicitation::DEFAULT_EXPIRATION.from_now, elicitation.expires_at, 5.seconds
  end

  test "should use the operator-configured expiration when the server names none" do
    request_id = "req-#{SecureRandom.hex(8)}"

    with_expiration_env("240") do
      post protocol_create_path,
        params: {
          message: "Confirm action",
          _meta: {
            "com.pulsemcp/request-id" => request_id,
            "com.pulsemcp/session-id" => @session.id.to_s
          }
        },
        as: :json
    end

    assert_response :created
    elicitation = Elicitation.find_by!(request_id: request_id)
    assert_in_delta 240.minutes.from_now, elicitation.expires_at, 5.seconds
  end

  test "an MCP server's own expires-at wins over the operator default" do
    request_id = "req-#{SecureRandom.hex(8)}"
    server_deadline = 3.minutes.from_now

    with_expiration_env("240") do
      post protocol_create_path,
        params: {
          message: "Confirm action",
          _meta: {
            "com.pulsemcp/request-id" => request_id,
            "com.pulsemcp/session-id" => @session.id.to_s,
            "com.pulsemcp/expires-at" => server_deadline.iso8601
          }
        },
        as: :json
    end

    assert_response :created
    elicitation = Elicitation.find_by!(request_id: request_id)
    assert_in_delta server_deadline, elicitation.expires_at, 5.seconds
  end

  test "an unparseable expires-at falls back to the operator default" do
    request_id = "req-#{SecureRandom.hex(8)}"

    with_expiration_env("240") do
      post protocol_create_path,
        params: {
          message: "Confirm action",
          _meta: {
            "com.pulsemcp/request-id" => request_id,
            "com.pulsemcp/session-id" => @session.id.to_s,
            "com.pulsemcp/expires-at" => "not-a-timestamp"
          }
        },
        as: :json
    end

    assert_response :created
    elicitation = Elicitation.find_by!(request_id: request_id)
    assert_in_delta 240.minutes.from_now, elicitation.expires_at, 5.seconds
  end

  test "should use provided expiration" do
    request_id = "req-#{SecureRandom.hex(8)}"
    expires_at = 30.minutes.from_now.iso8601

    post protocol_create_path,
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
    post protocol_create_path,
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
    post protocol_create_path,
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

  # The client omits the session tag when ELICITATION_SESSION_ID is unset. On a
  # token route that loses nothing: the token already names the session.
  test "a token-routed create with no session-id in _meta is raised on the token's session" do
    request_id = "req-#{SecureRandom.hex(8)}"

    post protocol_create_path,
      params: { message: "Confirm action", _meta: { "com.pulsemcp/request-id" => request_id } },
      as: :json

    assert_response :created
    assert_equal @session.id, Elicitation.find_by!(request_id: request_id).session_id
  end

  test "should return 422 for duplicate request_id" do
    existing = create_pending_elicitation

    post protocol_create_path,
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
      post protocol_create_path,
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

    post protocol_create_path,
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

    post protocol_create_path,
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

    get protocol_poll_path(elicitation.request_id)

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "pending", json["action"]
    assert_nil json["content"]
    assert_equal elicitation.request_id, json["_meta"]["com.pulsemcp/request-id"]
  end

  test "should return resolved status with content when accepted" do
    elicitation = create_resolved_elicitation

    get protocol_poll_path(elicitation.request_id)

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "accept", json["action"]
    assert_equal({ "approved" => true }, json["content"])
    assert json["_meta"]["com.pulsemcp/responded-at"].present?
  end

  test "should auto-expire when past expiration" do
    elicitation = create_expired_elicitation
    assert_equal "pending", elicitation.status

    get protocol_poll_path(elicitation.request_id)

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "expired", json["action"]

    elicitation.reload
    assert_equal "expired", elicitation.status
  end

  test "should return 404 for unknown request_id" do
    get protocol_poll_path("nonexistent-request-id")

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

  # #82: respond takes the same identifiers the web path takes, so an API
  # consumer holding either one can act on the elicitation.
  test "should accept a pending elicitation by database id" do
    elicitation = create_pending_elicitation

    patch respond_api_v1_elicitation_path(elicitation.id),
      params: { action_type: "accept" },
      headers: @headers,
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "accept", json["action"]
    assert_equal elicitation.request_id, json["_meta"]["com.pulsemcp/request-id"]
    assert_equal "accept", elicitation.reload.status
  end

  test "respond returns 404 for an identifier that is neither request_id nor id" do
    patch respond_api_v1_elicitation_path("no-such-elicitation"),
      params: { action_type: "accept" },
      headers: @headers,
      as: :json

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Not Found", json["error"]
    assert_kind_of String, json["message"]
    assert_kind_of Array, json["messages"]
  end

  # show stays request_id-only: the poll protocol speaks nothing else, and a
  # primary key would make it a sequential-id enumeration.
  test "show does not resolve an elicitation by database id" do
    elicitation = create_pending_elicitation

    get protocol_poll_path(elicitation.id)

    assert_response :not_found
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
      params: { action_type: "expired" },
      headers: @headers,
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Unprocessable Entity", json["error"]

    elicitation.reload
    assert_equal "pending", elicitation.status
  end

  # cancel is the protocol's "dismissed without answering". It ends the round-trip
  # with an outcome the polling MCP server can read, instead of leaving the request
  # pending until it expires.
  test "should cancel a pending elicitation" do
    elicitation = create_pending_elicitation

    patch respond_api_v1_elicitation_path(elicitation.request_id),
      params: { action_type: "cancel", content: { confirmed: true } },
      headers: @headers,
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "cancel", json["action"]
    assert_nil json["content"], "a cancel answers nothing, so it must not carry content"

    elicitation.reload
    assert_equal "cancel", elicitation.status
    assert_nil elicitation.response_content
  end

  # === Who may create and poll (#45) ===
  #
  # An MCP server holds no API key. The token in the URL Zimmer gave it is its
  # credential, and it names exactly one session: the session comes from the
  # token, never from `_meta`, and a poll sees only that session's elicitations.

  test "create without a token or an API key is refused, and warns" do
    warned = false
    Rails.logger.stub(:warn, ->(msg) { warned = true if msg.to_s.include?("without a session token or an API key") }) do
      assert_no_enqueued_jobs(only: SendPushNotificationJob) do
        assert_no_difference("Elicitation.count") do
          post api_v1_elicitations_path, params: protocol_params, as: :json
        end
      end
    end

    assert_response :unauthorized
    assert warned, "a keyless POST on the bare route is a server that never got its session's URL — obs must see it"
  end

  test "create with a forged token is refused" do
    assert_no_difference("Elicitation.count") do
      post api_v1_session_elicitations_path("#{@session.id}-#{'A' * 43}"), params: protocol_params, as: :json
    end

    assert_response :unauthorized
  end

  test "a valid API key does not rescue a forged token" do
    assert_no_difference("Elicitation.count") do
      post api_v1_session_elicitations_path("#{@session.id}-#{'A' * 43}"), params: protocol_params, headers: @headers, as: :json
    end

    assert_response :unauthorized
  end

  test "another session's token cannot raise a prompt on this session" do
    other = sessions(:pending_oauth)

    assert_no_enqueued_jobs(only: SendPushNotificationJob) do
      assert_no_difference("Elicitation.count") do
        post protocol_create_path(other), params: protocol_params(session_id: @session.id.to_s), as: :json
      end
    end

    assert_response :forbidden
    assert_equal "Forbidden", JSON.parse(response.body)["error"]
  end

  test "a _meta session-id that disagrees with the token is refused" do
    other = sessions(:pending_oauth)

    assert_no_difference("Elicitation.count") do
      post protocol_create_path, params: protocol_params(session_id: other.id.to_s), as: :json
    end

    assert_response :forbidden
  end

  test "a _meta session-id that names the token's session by slug is accepted" do
    @session.update!(slug: "token-slug-#{SecureRandom.hex(4)}")

    post protocol_create_path, params: protocol_params(session_id: @session.slug), as: :json

    assert_response :created
  end

  test "the token decides the session: another session's token lands on that session" do
    other = sessions(:pending_oauth)
    request_id = "req-#{SecureRandom.hex(8)}"

    post protocol_create_path(other), params: protocol_params(session_id: nil, request_id: request_id), as: :json

    assert_response :created
    assert_equal other.id, Elicitation.find_by!(request_id: request_id).session_id
  end

  test "show without a token or an API key is refused" do
    elicitation = create_resolved_elicitation

    get api_v1_elicitation_path(elicitation.request_id)

    assert_response :unauthorized
    assert_not_includes response.body, "approved"
  end

  test "show with a forged token is refused" do
    elicitation = create_pending_elicitation

    get api_v1_session_elicitation_path("#{@session.id}-#{'A' * 43}", elicitation.request_id)

    assert_response :unauthorized
  end

  test "show with another session's token cannot see this session's elicitation" do
    elicitation = create_resolved_elicitation

    get protocol_poll_path(elicitation.request_id, sessions(:pending_oauth))

    assert_response :not_found
    assert_not_includes response.body, "approved"
  end

  # The client polls the poll URL it was configured with, but the create response's
  # poll-url is the protocol's own statement of where to poll, so it must be one
  # the server can use without a key.
  test "create's poll-url is the token route, and polling it answers" do
    request_id = "req-#{SecureRandom.hex(8)}"

    post protocol_create_path, params: protocol_params(request_id: request_id), as: :json
    assert_response :created
    poll_url = JSON.parse(response.body).dig("_meta", "com.pulsemcp/poll-url")

    assert_equal "http://www.example.com#{protocol_poll_path(request_id)}", poll_url
    get URI(poll_url).path
    assert_response :success
    assert_equal "pending", JSON.parse(response.body)["action"]
  end

  test "an API-key holder can still create and poll on the bare routes" do
    request_id = "req-#{SecureRandom.hex(8)}"

    post api_v1_elicitations_path, params: protocol_params(request_id: request_id), headers: @headers, as: :json
    assert_response :created
    assert_equal "http://www.example.com#{api_v1_elicitation_path(request_id)}",
      JSON.parse(response.body).dig("_meta", "com.pulsemcp/poll-url")

    get api_v1_elicitation_path(request_id), headers: @headers
    assert_response :success
  end

  test "the bare route answers an API-key holder 404 for an unknown session" do
    post api_v1_elicitations_path, params: protocol_params(session_id: "99999999"), headers: @headers, as: :json

    assert_response :not_found
    assert_equal "Session not found", JSON.parse(response.body)["error"]
  end

  test "a token does not reach respond" do
    elicitation = create_pending_elicitation

    patch "#{protocol_poll_path(elicitation.request_id)}/respond", params: { action_type: "accept" }, as: :json

    assert_response :not_found
    assert_equal "pending", elicitation.reload.status
  end

  # ElicitationEndpoint.probe counts any HTTP answer as reachable; this pins which
  # answer it gets, from the route MCP servers actually poll.
  test "the reachability probe's poll answers 401 from the token route" do
    probe = ElicitationEndpoint::PROBE_REQUEST_ID

    get "#{ElicitationEndpoint::PATH}/#{ElicitationEndpoint::SESSION_SEGMENT}/#{probe}/#{probe}"

    assert_response :unauthorized
  end

  test "the token route takes a .json suffix without reading it as part of the token" do
    post "#{protocol_create_path}.json", params: protocol_params, as: :json

    assert_response :created
  end

  # The WARN lines quote what an uncredentialed caller sent, and obs ships them.
  test "a caller's _meta cannot forge a line in the WARN log" do
    logged = []
    Rails.logger.stub(:warn, ->(msg) { logged << msg.to_s }) do
      post api_v1_elicitations_path, params: protocol_params(request_id: "req-1\nFAKE: all clear"), as: :json
    end

    assert_response :unauthorized
    assert_equal 1, logged.size
    assert_not_includes logged.first, "\n"
  end

  private

  def protocol_create_path(session = @session)
    api_v1_session_elicitations_path(ElicitationEndpoint.token_for(session.id))
  end

  def protocol_poll_path(request_id, session = @session)
    api_v1_session_elicitation_path(ElicitationEndpoint.token_for(session.id), request_id)
  end

  def protocol_params(session_id: @session.id.to_s, request_id: "req-#{SecureRandom.hex(8)}")
    meta = { "com.pulsemcp/request-id" => request_id }
    meta["com.pulsemcp/session-id"] = session_id if session_id
    { message: "Approve the 1Password reveal", _meta: meta }
  end

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

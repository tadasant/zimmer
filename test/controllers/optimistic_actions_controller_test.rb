require "test_helper"
require "mocha/minitest"
require "ostruct"

# The server half of "the page shows it at the click": a refusal answers with a
# status the page reads as "put it back", a start answers as JSON for the page
# that opened before it had an id, and a refused restart says why over Turbo.
class OptimisticActionsControllerTest < ActionDispatch::IntegrationTest
  # --- Quick Router as JSON ------------------------------------------------

  test "quick_prompt answers JSON with where the session is" do
    stub_router_agent_root

    assert_difference("Session.count", 1) do
      post quick_prompt_sessions_url, params: { prompt: "Fix the login bug" }, as: :json
    end

    session = Session.last
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal session.id, body["session_id"]
    assert_equal session_path(session), body["url"]
    assert_equal session_path(session), body["session_url"]
    assert_match(/Router session created/, body["notice"])
  end

  test "quick_prompt refuses a blank prompt as JSON with a 422" do
    assert_no_difference("Session.count") do
      post quick_prompt_sessions_url, params: { prompt: "   " }, as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "Prompt cannot be empty.", JSON.parse(response.body)["error"]
  end

  test "quick_prompt still redirects a native post" do
    post quick_prompt_sessions_url, params: { prompt: "   " }
    assert_redirected_to root_path
    assert_equal "Prompt cannot be empty.", flash[:alert]
  end

  test "the starting page renders its controller and nothing about any session" do
    get starting_sessions_url
    assert_response :success
    assert_select "[data-controller='session-start']"
    assert_select "[data-session-start-target='pending']"
    assert_select "[data-session-start-target='failed'].hidden"
  end

  # --- Trash ---------------------------------------------------------------

  test "a trash the queued-message guard refuses answers 422 with the Archive anyway alert" do
    session = sessions(:failed)
    session.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")

    post archive_session_url(session), as: :turbo_stream

    assert_response :unprocessable_entity
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_match(/Archive anyway/, response.body)
    assert_not session.reload.archived?
  end

  test "the session page's own Trash with the optimistic header gets the streams, not the redirect" do
    session = sessions(:failed)

    post archive_session_url(session), as: :turbo_stream,
         headers: { "Referer" => session_url(session), "X-Zimmer-Optimistic" => "1" }

    assert_response :success
    assert_match(/<turbo-stream\s+action="remove"\s+target="session_#{session.id}"/, response.body)
    assert_match(/undo_archive/, response.body)
    assert session.reload.archived?
  end

  test "the session page's own Trash without the header still redirects home" do
    session = sessions(:failed)

    post archive_session_url(session), as: :turbo_stream, headers: { "Referer" => session_url(session) }

    assert_response :see_other
    assert_redirected_to root_path
  end

  # --- Restart -------------------------------------------------------------

  test "a restart the server refuses says so over Turbo instead of redrawing silently" do
    session = sessions(:running)

    post restart_session_url(session), as: :turbo_stream

    assert_response :unprocessable_entity
    assert_match(/target="flash"/, response.body)
    assert_match(/Cannot restart a session that is running/, response.body)
  end

  # --- Queued messages -----------------------------------------------------

  test "a Send Now the server refuses answers 422 with the refusal, not a redirect" do
    session = sessions(:running)
    message = session.enqueued_messages.create!(content: "queued words", position: 1, status: "pending")
    Sessions::InterruptService.any_instance.stubs(:call).returns(
      Sessions::Result.new(success: false, error: "The agent is not listening", error_code: :conflict)
    )
    EnqueuedMessagesController.any_instance.stubs(:wait_for_pending_message_delivery)

    post interrupt_session_enqueued_message_url(session, message), as: :turbo_stream

    assert_response :unprocessable_entity
    assert_match(/target="flash"/, response.body)
    assert_match(/The agent is not listening/, response.body)
  end

  # --- Elicitations ----------------------------------------------------------

  test "answering an elicitation already resolved removes the banner and says so, as a stream" do
    elicitation = Elicitation.create!(
      session: sessions(:elicitation_session), request_id: "req-#{SecureRandom.hex(8)}", mode: "form",
      message: "Confirm sending email", requested_schema: { "type" => "object" }, meta: {},
      tool_name: "send_email", expires_at: 1.hour.from_now
    )
    elicitation.resolve!(action: "accept")

    patch respond_elicitation_url(elicitation), params: { action_type: "decline" }, as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="remove"\s+target="elicitation_#{elicitation.id}"/, response.body)
    assert_match(/already been resolved/, response.body)
  end

  # --- Triggers ------------------------------------------------------------

  test "a trigger toggled from its own page redirects back to it rather than streaming a row the page lacks" do
    trigger = triggers(:enabled_schedule_trigger)

    post toggle_trigger_url(trigger), as: :turbo_stream, headers: { "Referer" => trigger_url(trigger) }

    assert_response :see_other
    assert_redirected_to trigger_path(trigger)
    assert_not trigger.reload.enabled?
  end

  test "a trigger toggled from the index streams its row" do
    trigger = triggers(:enabled_schedule_trigger)

    post toggle_trigger_url(trigger), as: :turbo_stream, headers: { "Referer" => triggers_url }

    assert_response :success
    assert_match(/target="trigger_#{trigger.id}"/, response.body)
  end

  private

  def stub_router_agent_root
    AgentRootsConfig.stubs(:find!).with(AgentRootsConfig.router_root_name).returns(
      OpenStruct.new(
        url: "https://github.com/test/repo.git",
        default_branch: "main",
        subdirectory: "agent-roots/zimmer-orchestrator",
        default_mcp_servers: []
      )
    )
    AgentSessionJob.stubs(:enqueue_new_session)
  end
end

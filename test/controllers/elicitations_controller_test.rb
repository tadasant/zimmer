# frozen_string_literal: true

require "test_helper"

class ElicitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @session = sessions(:elicitation_session)
  end

  # === PATCH /elicitations/:id/respond ===

  test "should accept a pending elicitation" do
    elicitation = create_pending_elicitation

    patch respond_elicitation_path(elicitation),
      params: {
        action_type: "accept",
        content: { confirmed: true }.to_json
      }

    assert_redirected_to session_path(elicitation.session)
    elicitation.reload
    assert_equal "accept", elicitation.status
    assert_equal({ "confirmed" => true }, elicitation.response_content)
    assert_not_nil elicitation.responded_at
  end

  test "should decline a pending elicitation" do
    elicitation = create_pending_elicitation

    patch respond_elicitation_path(elicitation),
      params: { action_type: "decline" }

    assert_redirected_to session_path(elicitation.session)
    elicitation.reload
    assert_equal "decline", elicitation.status
    assert_nil elicitation.response_content
    assert_not_nil elicitation.responded_at
  end

  test "accepting the last pending elicitation flips the session back to running" do
    elicitation = create_pending_elicitation
    assert_equal "needs_input", @session.reload.status

    patch respond_elicitation_path(elicitation),
      params: { action_type: "accept", content: { confirmed: true }.to_json }

    assert_equal "running", @session.reload.status
    assert_not @session.blocked_on_elicitation?
  end

  test "should redirect with alert for already resolved elicitation" do
    elicitation = create_resolved_elicitation

    patch respond_elicitation_path(elicitation),
      params: { action_type: "accept" }

    assert_redirected_to session_path(elicitation.session)
    assert_equal "This elicitation has already been resolved.", flash[:alert]
  end

  test "should respond with turbo_stream format" do
    elicitation = create_pending_elicitation

    patch respond_elicitation_path(elicitation),
      params: { action_type: "accept" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, "turbo-stream"
    assert_includes response.body, "elicitation_#{elicitation.id}"
  end

  test "should reject invalid action_type" do
    elicitation = create_pending_elicitation

    patch respond_elicitation_path(elicitation),
      params: { action_type: "expired" }

    assert_redirected_to session_path(elicitation.session)
    assert_equal "Invalid action.", flash[:alert]
    elicitation.reload
    assert_equal "pending", elicitation.status
  end

  test "should handle hash content params" do
    elicitation = create_pending_elicitation

    patch respond_elicitation_path(elicitation),
      params: {
        action_type: "accept",
        content: { confirmed: true }
      }

    assert_redirected_to session_path(elicitation.session)
    elicitation.reload
    assert_equal "accept", elicitation.status
    assert elicitation.response_content.present?
  end

  private

  def create_pending_elicitation
    Elicitation.create!(
      session: @session,
      request_id: "req-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Confirm sending email",
      requested_schema: { "type" => "object" },
      meta: {},
      tool_name: "send_email",
      expires_at: 1.hour.from_now
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

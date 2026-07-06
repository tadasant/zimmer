# frozen_string_literal: true

require "test_helper"

class ElicitationTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:elicitation_session)
  end

  # === Validations ===

  test "valid with all required attributes" do
    elicitation = Elicitation.new(
      session: @session,
      request_id: "unique-req-#{SecureRandom.hex(4)}",
      mode: "form",
      message: "Confirm action",
      requested_schema: { "type" => "object" },
      status: "pending",
      expires_at: 10.minutes.from_now
    )
    assert elicitation.valid?
  end

  test "invalid without request_id" do
    elicitation = Elicitation.new(
      session: @session,
      mode: "form",
      message: "Confirm",
      requested_schema: {}
    )
    assert_not elicitation.valid?
    assert_includes elicitation.errors[:request_id], "can't be blank"
  end

  test "invalid with duplicate request_id" do
    existing = create_pending_elicitation
    elicitation = Elicitation.new(
      session: @session,
      request_id: existing.request_id,
      mode: "form",
      message: "Confirm",
      requested_schema: {}
    )
    assert_not elicitation.valid?
    assert_includes elicitation.errors[:request_id], "has already been taken"
  end

  test "invalid without mode" do
    elicitation = Elicitation.new(
      session: @session,
      request_id: "req-#{SecureRandom.hex(4)}",
      message: "Confirm",
      requested_schema: {}
    )
    assert_not elicitation.valid?
    assert_includes elicitation.errors[:mode], "can't be blank"
  end

  test "invalid with unsupported mode" do
    elicitation = Elicitation.new(
      session: @session,
      request_id: "req-#{SecureRandom.hex(4)}",
      mode: "unsupported_mode",
      message: "Confirm",
      requested_schema: {}
    )
    assert_not elicitation.valid?
    assert_includes elicitation.errors[:mode], "is not included in the list"
  end

  test "invalid without message" do
    elicitation = Elicitation.new(
      session: @session,
      request_id: "req-#{SecureRandom.hex(4)}",
      mode: "form",
      requested_schema: {}
    )
    assert_not elicitation.valid?
    assert_includes elicitation.errors[:message], "can't be blank"
  end

  test "invalid with unsupported status" do
    elicitation = Elicitation.new(
      session: @session,
      request_id: "req-#{SecureRandom.hex(4)}",
      mode: "form",
      message: "Confirm",
      requested_schema: {},
      status: "invalid_status"
    )
    assert_not elicitation.valid?
    assert_includes elicitation.errors[:status], "is not included in the list"
  end

  # === Scopes ===

  test "pending scope returns only pending elicitations" do
    pending = create_pending_elicitation
    resolved = create_resolved_elicitation

    results = Elicitation.pending
    assert_includes results, pending
    assert_not_includes results, resolved
  end

  test "active scope returns pending elicitations not yet expired" do
    pending = create_pending_elicitation
    expired = create_expired_elicitation

    results = Elicitation.active
    assert_includes results, pending
    assert_not_includes results, expired
  end

  test "expired_pending scope returns pending elicitations past expiration" do
    expired = create_expired_elicitation
    pending = create_pending_elicitation

    results = Elicitation.expired_pending
    assert_includes results, expired
    assert_not_includes results, pending
  end

  test "for_session scope returns elicitations for a given session" do
    create_pending_elicitation
    results = Elicitation.for_session(@session)
    assert results.all? { |e| e.session_id == @session.id }
  end

  # === Instance Methods ===

  test "pending? returns true for pending status" do
    assert create_pending_elicitation.pending?
  end

  test "pending? returns false for resolved status" do
    assert_not create_resolved_elicitation.pending?
  end

  test "resolved? returns true for non-pending status" do
    assert create_resolved_elicitation.resolved?
  end

  test "resolved? returns false for pending status" do
    assert_not create_pending_elicitation.resolved?
  end

  test "expired? returns true when past expiration" do
    assert create_expired_elicitation.expired?
  end

  test "expired? returns false when before expiration" do
    assert_not create_pending_elicitation.expired?
  end

  # === resolve! ===

  test "resolve! transitions from pending to accept with content" do
    elicitation = create_pending_elicitation

    elicitation.resolve!(action: "accept", content: { "confirmed" => true })

    assert_equal "accept", elicitation.status
    assert_equal({ "confirmed" => true }, elicitation.response_content)
    assert_not_nil elicitation.responded_at
  end

  test "resolve! transitions from pending to decline without content" do
    elicitation = create_pending_elicitation

    elicitation.resolve!(action: "decline")

    assert_equal "decline", elicitation.status
    assert_nil elicitation.response_content
    assert_not_nil elicitation.responded_at
  end

  test "resolve! raises when not pending" do
    elicitation = create_resolved_elicitation

    assert_raises(RuntimeError, "Cannot resolve a non-pending elicitation") do
      elicitation.resolve!(action: "decline")
    end
  end

  test "resolve! raises for invalid action" do
    elicitation = create_pending_elicitation

    error = assert_raises(ArgumentError) do
      elicitation.resolve!(action: "expired")
    end
    assert_match(/Invalid action/, error.message)
  end

  # === expire_if_needed! ===

  test "expire_if_needed! expires a pending elicitation past its expiration" do
    elicitation = create_expired_elicitation

    elicitation.expire_if_needed!

    assert_equal "expired", elicitation.status
    assert_not_nil elicitation.responded_at
  end

  test "expire_if_needed! does nothing for non-expired pending elicitation" do
    elicitation = create_pending_elicitation

    elicitation.expire_if_needed!

    assert_equal "pending", elicitation.status
    assert_nil elicitation.responded_at
  end

  test "expire_if_needed! does nothing for already resolved elicitation" do
    elicitation = create_resolved_elicitation
    original_status = elicitation.status

    elicitation.expire_if_needed!

    assert_equal original_status, elicitation.status
  end

  # === to_poll_response ===

  test "to_poll_response for pending elicitation" do
    elicitation = create_pending_elicitation
    response = elicitation.to_poll_response

    assert_equal "pending", response[:action]
    assert_nil response[:content]
    assert_equal elicitation.request_id, response[:_meta]["com.pulsemcp/request-id"]
    assert_not response[:_meta].key?("com.pulsemcp/responded-at")
  end

  test "to_poll_response for accepted elicitation" do
    elicitation = create_resolved_elicitation
    response = elicitation.to_poll_response

    assert_equal "accept", response[:action]
    assert_equal({ "approved" => true }, response[:content])
    assert_equal elicitation.request_id, response[:_meta]["com.pulsemcp/request-id"]
    assert response[:_meta].key?("com.pulsemcp/responded-at")
  end

  test "to_poll_response for declined elicitation" do
    elicitation = create_pending_elicitation
    elicitation.resolve!(action: "decline")
    response = elicitation.to_poll_response

    assert_equal "decline", response[:action]
  end

  # === Session blocking sync ===

  test "creating a pending elicitation flips a running session to needs_input" do
    assert_equal "running", @session.status

    create_pending_elicitation

    assert_equal "needs_input", @session.reload.status
    assert @session.blocked_on_elicitation?
  end

  test "blocking on an elicitation does NOT tear down the live agent process" do
    @session.update!(running_job_id: "job-abc-123")

    create_pending_elicitation

    @session.reload
    assert_equal "needs_input", @session.status
    assert_equal "job-abc-123", @session.running_job_id,
      "running_job_id must be preserved — the agent process is still alive awaiting the elicitation response"
  end

  test "resolving the last pending elicitation flips the session back to running" do
    elicitation = create_pending_elicitation
    assert_equal "needs_input", @session.reload.status

    elicitation.resolve!(action: "accept", content: { "confirmed" => true })

    assert_equal "running", @session.reload.status
    assert_not @session.blocked_on_elicitation?
  end

  test "declining the last pending elicitation flips the session back to running" do
    elicitation = create_pending_elicitation
    assert_equal "needs_input", @session.reload.status

    elicitation.resolve!(action: "decline")

    assert_equal "running", @session.reload.status
  end

  test "expiring the last pending elicitation flips the session back to running" do
    elicitation = create_pending_elicitation
    assert_equal "needs_input", @session.reload.status

    # Travel past the helper's 1-hour expiry so expire_if_needed! actually expires it.
    travel_to 2.hours.from_now do
      elicitation.expire_if_needed!
    end

    assert_equal "running", @session.reload.status
  end

  test "session stays needs_input while any pending elicitation remains" do
    first = create_pending_elicitation
    second = create_pending_elicitation
    assert_equal "needs_input", @session.reload.status

    first.resolve!(action: "accept")
    assert_equal "needs_input", @session.reload.status,
      "still blocked: a second elicitation is pending"

    second.resolve!(action: "decline")
    assert_equal "running", @session.reload.status,
      "unblocked: no pending elicitation remains"
  end

  test "does not flip a session that is not running" do
    @session.pause!
    assert_equal "needs_input", @session.status
    assert_not @session.blocked_on_elicitation?

    create_pending_elicitation

    @session.reload
    assert_equal "needs_input", @session.status
    assert_not @session.blocked_on_elicitation?,
      "a normal turn-completion pause must not be re-labelled as an elicitation block"
  end

  test "resolving an elicitation does not flip a normally-paused session to running" do
    # Session paused for a normal turn completion, then an elicitation is resolved.
    # The unblock guard (blocked_on_elicitation?) must prevent a spurious resume.
    elicitation = create_pending_elicitation
    assert_equal "needs_input", @session.reload.status

    # Simulate the marker being absent (normal pause) by clearing it.
    @session.update_column(:metadata, (@session.metadata || {}).except("blocked_on_elicitation"))

    elicitation.resolve!(action: "accept")

    assert_equal "needs_input", @session.reload.status,
      "without the marker, resolution must not force the session to running"
  end

  # === Association ===

  test "belongs to session" do
    elicitation = create_pending_elicitation
    assert_instance_of Session, elicitation.session
  end

  test "session has_many elicitations" do
    assert @session.respond_to?(:elicitations)
    assert_kind_of ActiveRecord::Associations::CollectionProxy, @session.elicitations
  end

  test "destroying session destroys elicitations" do
    create_pending_elicitation
    elicitation_ids = @session.elicitation_ids

    assert elicitation_ids.any?, "Test setup: session should have elicitations"

    @session.destroy!

    elicitation_ids.each do |id|
      assert_nil Elicitation.find_by(id: id), "Elicitation #{id} should be destroyed"
    end
  end

  private

  def create_pending_elicitation
    Elicitation.create!(
      session: @session,
      request_id: "req-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Confirm sending email to user@example.com",
      requested_schema: { "type" => "object", "properties" => { "confirmed" => { "type" => "boolean" } } },
      meta: { "com.pulsemcp/request-id" => "test", "com.pulsemcp/tool-name" => "send_email" },
      tool_name: "send_email",
      expires_at: 1.hour.from_now
    )
  end

  def create_expired_elicitation
    Elicitation.create!(
      session: @session,
      request_id: "req-expired-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "This elicitation has expired",
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
      message: "Approve deployment to staging",
      requested_schema: { "type" => "object" },
      meta: {},
      tool_name: "deploy",
      status: "accept",
      response_content: { "approved" => true },
      responded_at: 5.minutes.ago,
      expires_at: 1.hour.from_now
    )
  end
end

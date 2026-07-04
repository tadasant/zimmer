# frozen_string_literal: true

require "test_helper"

class CleanupExpiredElicitationsJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:elicitation_session)
  end

  test "expires pending elicitations past their expiration time" do
    expired = create_expired_elicitation
    assert_equal "pending", expired.status

    CleanupExpiredElicitationsJob.perform_now

    expired.reload
    assert_equal "expired", expired.status
  end

  test "does not affect non-expired pending elicitations" do
    pending_elicitation = create_pending_elicitation
    assert_equal "pending", pending_elicitation.status

    CleanupExpiredElicitationsJob.perform_now

    pending_elicitation.reload
    assert_equal "pending", pending_elicitation.status
  end

  test "expiring the last pending elicitation flips the blocked session back to running" do
    # A pending (active) elicitation blocks the running session into needs_input.
    elicitation = create_active_then_expired_elicitation
    assert_equal "needs_input", @session.reload.status
    assert @session.blocked_on_elicitation?

    CleanupExpiredElicitationsJob.perform_now

    elicitation.reload
    assert_equal "expired", elicitation.status
    assert_equal "running", @session.reload.status
    assert_not @session.blocked_on_elicitation?
  end

  test "does not affect already resolved elicitations" do
    resolved = create_resolved_elicitation
    assert_equal "accept", resolved.status

    CleanupExpiredElicitationsJob.perform_now

    resolved.reload
    assert_equal "accept", resolved.status
  end

  test "reconciles a session stranded with a stale elicitation block" do
    # Reproduce the stranding: an active elicitation blocks the session
    # (needs_input, marker set), then the elicitation becomes non-active WITHOUT
    # the reactive after_commit reconciliation ever clearing the marker — e.g. a
    # swallowed state-race InvalidTransition or an MCP server that crashed
    # mid round-trip. update_column bypasses callbacks to mimic that missed pass.
    elicitation = create_active_then_expired_elicitation
    assert_equal "needs_input", @session.reload.status
    assert @session.blocked_on_elicitation?
    elicitation.update_column(:status, "expired") # now non-pending => expiry loop skips it

    CleanupExpiredElicitationsJob.perform_now

    assert_not @session.reload.blocked_on_elicitation?, "Sweep should clear the stale marker"
    assert_equal "needs_input", @session.reload.status,
      "A stranded block must stay in needs_input for the user, not flip to running"
  end

  test "does not reconcile a session that is legitimately blocked on an active elicitation" do
    create_pending_elicitation_blocking_session
    assert_equal "needs_input", @session.reload.status
    assert @session.blocked_on_elicitation?

    CleanupExpiredElicitationsJob.perform_now

    assert @session.reload.blocked_on_elicitation?,
      "An active elicitation must keep the session blocked"
    assert_equal "needs_input", @session.reload.status
  end

  private

  # A pending, unexpired elicitation that actively blocks the running fixture
  # session into needs_input (marker set) and stays active.
  def create_pending_elicitation_blocking_session
    Elicitation.create!(
      session: @session,
      request_id: "req-active-block-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Active block",
      requested_schema: { "type" => "object" },
      meta: {},
      expires_at: 1.hour.from_now
    )
  end

  def create_pending_elicitation
    Elicitation.create!(
      session: @session,
      request_id: "req-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Confirm action",
      requested_schema: { "type" => "object" },
      meta: {},
      expires_at: 1.hour.from_now
    )
  end

  # Create an elicitation that is active (blocks the session) at creation time,
  # then push its expiration into the past so the cleanup job will expire it.
  # This mirrors the real flow: the elicitation blocks the session while live,
  # then expiry must flip the session back to running.
  def create_active_then_expired_elicitation
    elicitation = Elicitation.create!(
      session: @session,
      request_id: "req-active-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Active then expired",
      requested_schema: { "type" => "object" },
      meta: {},
      expires_at: 1.hour.from_now
    )
    elicitation.update_column(:expires_at, 1.hour.ago)
    elicitation
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
      message: "Resolved elicitation",
      requested_schema: { "type" => "object" },
      meta: {},
      status: "accept",
      response_content: { "approved" => true },
      responded_at: 5.minutes.ago,
      expires_at: 1.hour.from_now
    )
  end
end

# frozen_string_literal: true

# Periodically expires pending elicitations that have passed their expiration time,
# and reconciles sessions stranded with a stale elicitation block.
#
# Runs every 5 minutes via GoodJob cron. This ensures that MCP servers polling
# for elicitation responses get a timely "expired" status rather than seeing
# "pending" indefinitely for abandoned requests.
#
# Also broadcasts banner removal so users with the session page open see the
# expired elicitation disappear in real time.
class CleanupExpiredElicitationsJob < ApplicationJob
  queue_as :default

  def perform
    expire_pending_elicitations
    reconcile_stranded_elicitation_blocks
  end

  private

  def expire_pending_elicitations
    expired_count = 0

    Elicitation.expired_pending.find_each do |elicitation|
      elicitation.update!(status: "expired", responded_at: Time.current)
      BroadcastService.new.remove_elicitation_banner(elicitation.session, elicitation)
      expired_count += 1
    rescue => e
      Rails.logger.error "[CleanupExpiredElicitationsJob] Error expiring elicitation #{elicitation.id}: #{e.message}"
    end

    Rails.logger.info "[CleanupExpiredElicitationsJob] Expired #{expired_count} elicitations" if expired_count > 0
  end

  # Reconcile sessions whose `blocked_on_elicitation` marker is set but that have
  # no active elicitation remaining. The block/unblock lifecycle normally
  # reconciles reactively on every Elicitation commit; when that reactive pass is
  # missed (a swallowed state-race InvalidTransition, or an MCP server that crashed
  # mid round-trip so no resolve/expire commit ever fires), nothing re-runs it and
  # the session is stranded in needs_input showing a phantom block forever. This
  # periodic sweep restores the invariant. See Session#clear_stale_elicitation_block!
  # for why stranded sessions are left in needs_input rather than flipped to running.
  #
  # Runs after the expiry pass above so that sessions blocked by a just-expired
  # elicitation are already unblocked (via that expiry's after_commit) and skipped
  # here — this sweep only catches genuinely stranded markers.
  def reconcile_stranded_elicitation_blocks
    reconciled_count = 0

    # Only non-terminal sessions can be genuinely stranded (a stranded session is
    # stuck live in needs_input, or still running after a swallowed transition). A
    # leftover marker on an archived/failed session is inert, so skip those rather
    # than lock/clear/log them.
    Session.blocked_on_elicitation.where(status: [ :running, :needs_input ]).find_each do |session|
      reconciled_count += 1 if session.clear_stale_elicitation_block!
    rescue => e
      Rails.logger.error "[CleanupExpiredElicitationsJob] Error reconciling stranded elicitation block for session #{session.id}: #{e.message}"
    end

    Rails.logger.info "[CleanupExpiredElicitationsJob] Reconciled #{reconciled_count} stranded elicitation blocks" if reconciled_count > 0
  end
end

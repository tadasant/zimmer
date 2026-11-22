# frozen_string_literal: true

# The token broker's backstop (TokenBroker). Every few minutes:
#
# 1. A session child that is still `live` while its session is not running
#    (and not blocked on an elicitation) is marked for revocation — the case a
#    missed after_commit, a dead worker or a crash would otherwise leave live
#    until it expired. Children younger than TokenBroker::SWEEP_GRACE are left
#    alone, because a turn mints before its process has started.
# 2. A `live` child past its expiry is closed as `expired`.
# 3. Every revocation that is due (new, or a failed one whose backoff has run)
#    is attempted. One that keeps failing is retried until the token expires,
#    and then closed as `expired`: an unrevoked child simply stops working.
# 4. Rows that are revoked or expired and older than
#    McpBrokeredToken::RETENTION are deleted.
#
# Idempotent, and free when the broker has never been used: the first query
# finds no rows and the job returns.
class TokenBrokerSweepJob < ApplicationJob
  include SingletonSweep

  queue_as :default

  # Bound one run's network work; the next run picks up the rest.
  BATCH = 200

  def perform
    now = Time.current
    return unless McpBrokeredToken.exists?

    mark_resting_sessions(now)
    McpBrokeredToken.live.where("expires_at <= ?", now).update_all(state: "expired", updated_at: now)

    due = McpBrokeredToken.revoke_due(now).includes(:grant).order(:next_revoke_attempt_at).limit(BATCH).to_a
    revoked = due.count { |row| TokenBroker.revoke!(row, now: now) }

    McpBrokeredToken.where(state: %w[revoked expired]).where("updated_at < ?", now - McpBrokeredToken::RETENTION).delete_all

    Rails.logger.info("[TokenBrokerSweepJob] revoked #{revoked} of #{due.size} due brokered token(s)") if due.any?
  end

  private

  def mark_resting_sessions(now)
    McpBrokeredToken.for_sessions.live.unexpired(now).where("created_at <= ?", now - TokenBroker::SWEEP_GRACE)
      .includes(:session).find_each do |row|
      session = row.session
      next if session && (session.running? || (session.needs_input? && session.blocked_on_elicitation?))

      row.request_revoke!(now: now)
    end
  end
end

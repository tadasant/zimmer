# frozen_string_literal: true

# Retires the queued messages already stranded by an archive.
#
# Archiving ends every path by which a queued message could be delivered:
# EnqueuedMessageProcessorService claims `pending` rows only, and the only
# caller that claims them for a live session is AgentSessionJob's end-of-turn
# drain, which an archived session never reaches. Until now the rows stayed
# `pending` anyway, so the queue kept reporting a delivery that was never
# coming — the queue panel, the REST index and the MCP list all read `pending`
# as "still going to be sent".
#
# `Session#strand_pending_enqueued_messages` retires them at archive time from
# here on. This clears the ones already sitting in the fleet, which are exactly
# the population that would otherwise keep misreporting itself: production
# session 6073 is the one a user noticed, and nothing had ever swept the rest.
#
# Also matters for unarchive. A restored session's queue would hand the agent a
# message from weeks earlier as if it had just arrived; `undelivered` is
# terminal, so it cannot.
class RetireEnqueuedMessagesStrandedByAnArchive < ActiveRecord::Migration[8.0]
  # Session statuses are an integer enum; 3 is `archived`.
  ARCHIVED_STATUS = 3

  def up
    move_status(from: "pending", to: "undelivered")
  end

  # Reverses the mapping, which necessarily also repoints rows retired by the
  # archive callback rather than by this backfill — after the fact the two are
  # indistinguishable. That is the honest inverse: it restores the state in
  # which an archived session's queue claims a delivery is still coming.
  def down
    move_status(from: "undelivered", to: "pending")
  end

  private

  def move_status(from:, to:)
    execute(<<~SQL.squish)
      UPDATE enqueued_messages AS em
      SET status = #{connection.quote(to)}, updated_at = NOW()
      FROM sessions AS s
      WHERE em.session_id = s.id
        AND em.status = #{connection.quote(from)}
        AND s.status = #{ARCHIVED_STATUS}
    SQL
  end
end

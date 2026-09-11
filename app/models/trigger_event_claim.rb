# frozen_string_literal: true

# A trigger condition's claim on one external event — "this Slack message has fired (or been
# folded into) a session for this condition, and nothing else may fire it again".
#
# Two paths can see the same Slack message: Slack's Events API delivering it to
# Webhooks::SlackController, and SlackTriggerPollerJob finding it a minute later. Each claims
# the message before firing, inside the same transaction as Trigger#create_session!, and the
# unique index on (trigger_condition_id, event_key) decides the winner. The loser fires
# nothing, so running both paths at once costs no duplicate session. Because the claim commits
# with the session, a fire that raises rolls its claim back and the other path can still fire
# the message.
#
# The claim is per CONDITION, not per message: two triggers watching the same channel each fire
# on the same message, exactly as they do when only the poller runs.
#
# group_key and anchor_ts carry coalescing across deliveries. The poller sees a burst as one list
# and folds it in one pass (SlackTriggerFiring#coalesced_groups); the webhook sees it one message
# per request, so it finds the burst's open group here instead — see .open_group.
class TriggerEventClaim < ApplicationRecord
  VIA = %w[webhook poll].freeze

  # How long a claim must outlive the message it covers. In webhook_with_poll_fallback mode the
  # poller sees a message within a poll or two — a few minutes across Slack deferrals, about
  # seventeen for a tracked thread waiting its turn in the re-check rotation. Thirty days is far
  # past both, and rows are one per FIRED message (roughly one per session), so it costs little.
  RETENTION = 30.days

  # Advisory-lock namespace for .lock_group!. "TEGC" in ASCII: trigger event group coalesce.
  GROUP_LOCK_NAMESPACE = 0x5445_4743

  belongs_to :trigger_condition
  belongs_to :session, optional: true

  validates :event_key, presence: true
  validates :claimed_via, inclusion: { in: VIA }

  scope :expired, ->(now = Time.current) { where(created_at: ...(now - RETENTION)) }

  # The identity of a Slack message: its channel and its `ts`, which Slack guarantees unique
  # within a channel. The same string whichever path saw it, which is the whole point.
  def self.slack_event_key(channel_id, ts)
    "slack:#{channel_id}:#{ts}"
  end

  # Claim each of +event_keys+ for +condition+ and return the ones this call won.
  #
  # `INSERT ... ON CONFLICT DO NOTHING RETURNING event_key`: a key another transaction has
  # already claimed comes back missing, and a key another transaction is claiming right now
  # blocks until that transaction commits or rolls back, then comes back missing or won.
  def self.claim!(condition, event_keys, via:, group_key: nil, anchor_ts: nil, session_id: nil, now: Time.current)
    return [] if event_keys.empty?

    anchor = anchor_ts&.to_s&.to_d
    rows = event_keys.map do |key|
      {
        trigger_condition_id: condition.id, event_key: key, claimed_via: via,
        group_key: group_key, anchor_ts: anchor, session_id: session_id, created_at: now
      }
    end

    insert_all(rows, unique_by: %i[trigger_condition_id event_key], returning: %i[event_key]).rows.flatten
  end

  # Point claims at the session their fire produced, so a later message in the same burst can
  # find it (see .open_group).
  def self.attach_session!(condition, event_keys, session)
    where(trigger_condition_id: condition.id, event_key: event_keys).update_all(session_id: session.id)
  end

  # The most recent group for +condition+ and +group_key+ still open to a message stamped +ts+:
  # opened within +window+ seconds before it, and holding a session to fold into.
  #
  # Anchored on the message that opened the group, never chained off the latest one, so a group
  # spans at most the window — the same rule the poller follows.
  def self.open_group(condition, group_key, ts, window)
    return nil if group_key.blank? || !window.to_i.positive?

    at = ts.to_s.to_d
    where(trigger_condition_id: condition.id, group_key: group_key)
      .where(anchor_ts: (at - window.to_i)..at)
      .where.not(session_id: nil)
      .order(anchor_ts: :desc)
      .first
  end

  # Serialize every decision about one (condition, group) until the caller's transaction ends.
  #
  # Two messages of one burst arrive on two requests a fraction of a second apart. Without this
  # both would look for an open group, both would find none, and both would spawn — the exact
  # fan-out coalescing exists to stop. With it the second waits for the first to commit its
  # session, then finds the group and folds into it.
  def self.lock_group!(condition, group_key)
    connection.select_value(
      sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, hashtext(?))", GROUP_LOCK_NAMESPACE, "#{condition.id}:#{group_key}" ])
    )
  end
end

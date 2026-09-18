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
# GitHub's two paths — Webhooks::GithubController delivering an issue or a label, and
# GithubTriggerPollerJob searching for it a minute later — claim the same way, through
# GithubTriggerFiring#fire_claimed. The difference is the claim's LIFETIME. A `github_issue` claim
# covers an event that can never recur, so RETENTION expires it. A `github_label` claim covers one
# that can: removing a label and adding it back is a second event, and the poller's seen-set is what
# decides when that has happened. So a label claim lives exactly as long as the poller's key for the
# same item and label, released in the same transaction as the seen-set write that drops it.
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
  #
  # A `github_label` claim does not use it as its lifetime, and must not: removing a label and
  # adding it back is a second, legitimate event, so a claim that outlived the poller's seen-set
  # would swallow the re-add. Those claims are released by GithubTriggerPollerJob the tick it drops
  # the key (#release_label_claims), which is always sooner than this — so for them this is only the
  # backstop for a row whose key the poller never recorded, which is an item that left `is:open`
  # inside the minute between the webhook's fire and the poller's next tick.
  RETENTION = 30.days

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

  # The identity of a new GitHub issue for a `github_issue` condition: its repository and number,
  # which never change and never recur. The repository is downcased because GitHub's API and a
  # condition's configuration can disagree on its case. GithubTriggerFiring#fire_claimed takes it.
  def self.github_issue_event_key(repo, number)
    "github:#{repo.to_s.downcase}##{number}:opened"
  end

  # The identity of one "the label was added" event: the item, and the label that was added.
  # GithubTriggerFiring#fire_claimed takes it, and GithubTriggerPollerJob releases it when it drops
  # the item's key from its seen-set.
  #
  # Repository and label are both downcased, for the same reason the issue key downcases the
  # repository: GitHub returns its own casing, a condition's configuration carries the user's, and
  # `repo:`/`label:` search qualifiers ignore both. The two paths must spell one event one way.
  def self.github_label_event_key(repo, number, label)
    "github:#{repo.to_s.downcase}##{number}:label:#{label.to_s.downcase}"
  end

  # The same key, for one of GithubTriggerPollerJob's seen-set keys ("owner/repo#12:ready to
  # merge"). The seen-set and the claim table are two spellings of one identity, and this is the
  # only route between them: a key the poller is DROPPING is by definition absent from the search,
  # so there is no item to rebuild it from.
  #
  # Split on the FIRST colon, because a GitHub label may contain one ("area: docs"); a repository
  # name may not contain "#" or ":".
  def self.github_label_event_key_from_seen_key(seen_key)
    item, label = seen_key.to_s.split(":", 2)
    repo, number = item.to_s.split("#", 2)

    github_label_event_key(repo, number, label)
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
  # spans at most the window — the same rule the poller follows. Only earlier anchors count, so a
  # message Slack delivers before an earlier one opens a group of its own.
  #
  # Two deliveries of one burst race each other here, so the caller asks under the trigger's
  # spawn lock (Trigger.lock_spawn_for_transaction!): the second waits for the first to commit its
  # session, then finds it.
  def self.open_group(condition, group_key, ts, window)
    return nil if group_key.blank? || !window.to_i.positive?

    at = ts.to_s.to_d
    where(trigger_condition_id: condition.id, group_key: group_key)
      .where(anchor_ts: (at - window.to_i)..at)
      .where.not(session_id: nil)
      .order(anchor_ts: :desc)
      .first
  end
end

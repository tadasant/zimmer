# frozen_string_literal: true

# Announces a trigger fire whose session died holding the work.
#
# == The hole this closes
#
# A trigger fire is a one-shot event. `GithubTriggerPollerJob` records the item
# key in `seen_items` the moment a session exists for it, `SlackTriggerPollerJob`
# advances its cursor, `AoEventTriggerJob` spends the wake — all of them
# deliberately, because the alternative is the double dispatch of #704. From that
# point the session IS the work item, and there is exactly one of it.
#
# So when that session reaches terminal `failed`, the fire is spent and nothing
# is carrying its subject any more. Nothing said so. `failed` is terminal —
# no message is delivered to it, no wake reaches it, and the merge-gate contract
# reads it as unreachable — and every surface a human or an agent would check
# reported health: the trigger's own history showed the fire, the labelled PR
# showed a clean `ready to merge` and no comment, and no alert fired.
#
# On 2026-08-23 trigger 352 fired correctly on a `ready to merge` label and
# created session 7844. Eighty-six seconds later that session failed at first
# start (`Runtime session id … is already in use`, its recovery budget spent —
# the start failure itself is #519, fixed since). The PR then sat with no gate on
# it for eleven hours, until a human noticed an unrelated alert storm and had a
# router spawn a replacement gate by hand. See #632.
#
# == Surfaced, not retried
#
# The issue asks for one or the other. This is the surface.
#
# Re-dispatching automatically would put a second session on an event the fleet
# has already spent, and the population includes the merge gate — the one
# mechanism authorized to merge without human sign-off, and the one Zimmer
# already has a scar from double-dispatching (#704). The only after-the-fact
# guard against re-doing work is "did the runtime write a conversation", which
# `RuntimeConversationPresence` answers off a clone the reaper may have already
# removed, and which fails toward "a conversation exists" — so it would decline
# to retry precisely in the long-delay case that hurt.
#
# Surfacing is also what was actually missing: every recovery in the timeline was
# a human noticing. The alert names the trigger, the session and — when it can
# find one in the prompt the fire carried — the GitHub subject, so the next actor
# re-dispatches deliberately, in minutes rather than in hours.
#
# == Noise budget
#
# One alert per orphaned session, and deliberately not the choice
# `UnclassifiedFailureReporter` makes. There, N sessions hitting one unknown
# failure mode are one fact and collapse into one message. Here, N orphaned fires
# are N distinct work items, each needing its own re-dispatch: collapsing them
# would leave every subject but one still dropped, which is the defect this
# exists to remove.
#
# The bound is that each session reports at most once — {REPORTED_AT_KEY} is
# written before the alert and checked before the work — so a wave costs one
# message per dropped item once, not one per item per hour forever. The key is in
# `Session::STALE_RETRY_METADATA_KEYS`, so a session that is genuinely restarted
# and fails again reports again.
class OrphanedTriggerFire
  # Written on the session when its orphaned fire has been reported. Doubles as
  # the in-app record: the row itself says the drop was announced, so the fact
  # does not live only in a Slack channel.
  REPORTED_AT_KEY = "orphaned_trigger_fire_reported_at"

  # The GitHub item a fire was about, as it appears in the prompt the poller
  # built (`context_block`) or in a template that interpolated it. Best-effort
  # and never load-bearing: a fire with no GitHub subject — a schedule, a Slack
  # message, an `ao_event` — simply reports without one.
  SUBJECT_URL_PATTERN = %r{https://github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/\d+}

  class << self
    # Whether this session's failure leaves a trigger's work item dropped.
    #
    # Asked by the `fail` transition before it enqueues anything, so an ordinary
    # session failure — the overwhelming majority — costs one hash lookup and no
    # job at all.
    #
    # Status-summary forks are out by construction rather than by a check here:
    # the `fail` transition harvests a fork and never reaches this branch. A fork
    # is not a work item anyway — it summarizes a session, and its own failure is
    # recorded against the session it was summarizing.
    #
    # @param session [Session, nil]
    # @return [Boolean]
    def candidate?(session)
      return false if session.nil?
      return false unless session.failed?

      session.metadata&.dig("trigger_id").present?
    end

    # Report one orphaned fire.
    #
    # Never raises. Announcing a dropped work item must not become a second way
    # for the failure to blow up — the same self-guard `UnclassifiedFailureReporter`
    # and `SessionStateMachine#report_swallowed_side_effect` carry.
    #
    # @param session [Session, nil] the failed trigger-originated session
    # @return [Boolean] whether an alert was raised
    def report!(session)
      return false unless candidate?(session)

      session.reload
      return false unless candidate?(session)
      return false if session.metadata&.dig(REPORTED_AT_KEY).present?

      # Stamped BEFORE the alert. The alert is a network round trip that can hang
      # or fail, and a job retried over a half-finished report must not send the
      # same drop twice — an unreported drop is recovered by the next genuine
      # failure, a doubled one costs a human the trust in the channel.
      session.merge_metadata!(REPORTED_AT_KEY => Time.current.utc.iso8601)

      trigger = Trigger.find_by(id: session.metadata["trigger_id"])
      record_on_session(session, trigger)
      raise_alert(session, trigger)
    rescue => e
      Rails.logger.error(
        "[OrphanedTriggerFire] Could not report the orphaned fire on session #{session&.id}: " \
        "#{e.class}: #{e.message}"
      )
      false
    end

    private

    # The session's own timeline says it too, so the drop is legible to anyone
    # who opens the session without a Slack account — and to the agent that is
    # eventually pointed at it.
    def record_on_session(session, trigger)
      session.logs.create!(
        level: "error",
        content: "This session was created by #{trigger_label(session, trigger)} and failed before " \
                 "handing its work back. The fire that created it is spent — a label is seen, a " \
                 "cursor has moved, a wake is consumed — so nothing will create a replacement, and " \
                 "#{subject_phrase(session)} now has nobody on it. Zimmer raised an alert; " \
                 "re-dispatch it deliberately if it is still wanted."
      )
    rescue => e
      # The alert is the point; a timeline write that fails must not take it down.
      Rails.logger.warn(
        "[OrphanedTriggerFire] Could not write the timeline entry for session #{session.id}: #{e.message}"
      )
    end

    def raise_alert(session, trigger)
      AlertService.raise_alert(
        "Trigger session failed with its work undone",
        details: alert_details(session, trigger),
        source: "OrphanedTriggerFire",
        dedup_key: "orphaned_trigger_fire_session_#{session.id}"
      )
    end

    def alert_details(session, trigger)
      lines = []
      lines << "The fire from #{trigger_label(session, trigger)} is spent, and the session it " \
               "created failed without doing the work."
      lines << ""
      lines << "*Subject:* #{subject_phrase(session)}"
      lines << "*Why it failed:* #{failure_phrase(session)}"
      lines << ""
      lines << "No retry is coming. The event was consumed when the session was created — a " \
               "`github_label` item is recorded as seen, a Slack cursor has moved, an `ao_event` " \
               "wake is spent — and a `failed` session can be neither messaged nor woken. This work " \
               "item stays dropped until somebody re-dispatches it."
      lines << ""
      lines << "<#{AppUrl.base_url}/sessions/#{session.id}|View session #{session.id} in Zimmer>"
      lines << "<#{AppUrl.base_url}/triggers/#{trigger.id}|View trigger #{trigger.id} in Zimmer>" if trigger
      lines.join("\n")
    end

    # "trigger 352 (`PR ready to merge → merge gate`)", degrading to the id alone
    # for a trigger that has since been deleted — which is itself worth seeing.
    def trigger_label(session, trigger)
      id = session.metadata["trigger_id"]
      name = trigger&.name.presence || session.metadata["trigger_name"].presence
      return "trigger #{id}" if name.blank?

      "trigger #{id} (`#{name}`)"
    end

    def subject_phrase(session)
      subject_url(session) || "the work this fire carried (session #{session.id})"
    end

    def subject_url(session)
      session.prompt.to_s[SUBJECT_URL_PATTERN]
    end

    # The classified summary AND the raw exit status, because for the failure
    # this exists for they say different things: `failure_summary` renders
    # `process_failed` as "Process failed", while the sentence a reader needs —
    # "Runtime session id … is already in use" — is only in `exit_status`.
    def failure_phrase(session)
      parts = [
        session.failure_summary.presence || session.metadata&.dig("failure_reason").presence,
        session.metadata&.dig("exit_status").presence
      ].compact.uniq
      return "no failure reason was recorded" if parts.empty?

      parts.join(" — ")
    end
  end
end

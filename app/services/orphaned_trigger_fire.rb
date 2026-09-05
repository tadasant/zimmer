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
# == Which failures this is about
#
# Only the fires that are genuinely *consumed*. `metadata.trigger_id` alone is
# too wide, because a trigger creates sessions on paths where a retry IS coming
# or a human is already watching, and telling either of those that "no retry is
# coming" would be false:
#
#   - A **recurring `schedule`** re-fires on its next interval, and a
#     **`system_event`** is re-armed when nothing handles it. Both heal
#     themselves.
#   - A **manual Invoke** (`Triggers::ManualFire`, from the web UI, the REST API
#     or MCP `action_trigger`) is somebody pressing a button and watching the
#     session they just made.
#   - A **burst-notice session** is not a work item at all — it exists to say
#     the trigger is bursting.
#
# So the population is keyed on `Session#genesis`, which is stamped at creation
# and is exactly this distinction, plus the `burst_notice` marker. One gap is
# knowingly left: a **one-time** `schedule` whose fire succeeded and whose
# session then died is a real orphan that this does not report, because telling
# it apart from a recurring one costs a condition lookup inside a state
# transition. See docs/limitations.md.
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
# checked on entry — so a wave costs one message per dropped item once, not one
# per item per hour forever. The key is in `Session::STALE_RETRY_METADATA_KEYS`,
# so a session that is genuinely restarted and fails again reports again.
#
# The stamp goes down **after** the report, not before. Stamping first would make
# a Slack outage, or a deploy landing in the window, a permanent silent drop —
# which is the exact bug this service exists to remove, reintroduced inside the
# fix. The cost of the other order is that a job retried over a half-finished
# report writes a second identical timeline line; the Slack side is covered by
# the per-session `dedup_key` inside `AlertService::DEDUP_WINDOW`.
class OrphanedTriggerFire
  # Written on the session when its orphaned fire has been reported. Doubles as
  # the in-app record: the row itself says the drop was announced, so the fact
  # does not live only in a Slack channel.
  REPORTED_AT_KEY = "orphaned_trigger_fire_reported_at"

  # The genesis kinds whose fire is CONSUMED by the session carrying it, so a
  # failure really does drop the work item. See "Which failures this is about"
  # above for what each exclusion is protecting, and why the discriminator is
  # `genesis` rather than the presence of `trigger_id`.
  CONSUMED_EVENT_GENESES = [
    SessionGenesis::GITHUB_LABEL,
    SessionGenesis::GITHUB_ISSUE,
    SessionGenesis::SLACK,
    SessionGenesis::AO_EVENT
  ].freeze

  # The GitHub item a fire was about. Best-effort and never load-bearing: a fire
  # with no GitHub subject — a Slack message, an `ao_event` — simply reports
  # without one.
  SUBJECT_URL_PATTERN = %r{https://github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/\d+}

  # The same URL, but in the line `GithubTriggerPollerJob#context_block` writes.
  # Preferred over a bare scan of the prompt because the poller appends that
  # block AFTER the operator's interpolated template, and the template can carry
  # `{{text}}` — the issue or PR body, which anyone who can file an issue writes.
  # A bare first match would let them name a repository of their choosing as the
  # dropped subject.
  CONTEXT_BLOCK_URL_PATTERN = /^- \*\*URL:\*\*\s*(#{SUBJECT_URL_PATTERN})/

  # Raw runtime text carried by a failure, in the order a reader wants it. It
  # travels as `error:`, never in `details:` — see #raise_alert.
  RUNTIME_FAILURE_KEYS = %w[exit_status exception_message].freeze

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
      return false unless CONSUMED_EVENT_GENESES.include?(session.genesis)
      return false if session.metadata&.dig("burst_notice").present?

      session.metadata&.dig("trigger_id").present?
    end

    # Report one orphaned fire.
    #
    # Never raises. Announcing a dropped work item must not become a second way
    # for the failure to blow up — the same self-guard `UnclassifiedFailureReporter`
    # and `SessionStateMachine#report_swallowed_side_effect` carry.
    #
    # Re-reads the row before deciding, so a recovery between the enqueue and the
    # run is seen. That discards unsaved in-memory changes on the object passed
    # in, which is why the only caller hands it a freshly loaded one.
    #
    # @param session [Session, nil] the failed trigger-originated session
    # @return [Boolean] whether an alert was raised
    def report!(session)
      return false if session.nil?

      session.reload
      return false unless candidate?(session)
      return false if session.metadata&.dig(REPORTED_AT_KEY).present?

      trigger = Trigger.find_by(id: session.metadata["trigger_id"])
      record_on_session(session, trigger)
      alerted = raise_alert(session, trigger)

      # Stamped AFTER the report, so a failure on the way here leaves the session
      # eligible rather than marked-as-reported over a message nobody got. See
      # "Noise budget" above for the trade this makes with a retried job.
      session.merge_metadata!(REPORTED_AT_KEY => Time.current.utc.iso8601)
      alerted
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
        content: "This session was created by #{trigger_label(session, trigger)}, and it has failed. " \
                 "The fire that created it is spent — a label is seen, a cursor has moved, a wake is " \
                 "consumed — so nothing will create a replacement, and #{subject_phrase(session)} now " \
                 "has nobody on it. Zimmer raised an alert; re-dispatch it deliberately if it is " \
                 "still wanted."
      )
    rescue => e
      # The alert is the point; a timeline write that fails must not take it down.
      Rails.logger.warn(
        "[OrphanedTriggerFire] Could not write the timeline entry for session #{session.id}: #{e.message}"
      )
    end

    # The raw runtime text goes through `error:`, not into `details:`, and that
    # split is security-relevant rather than cosmetic.
    #
    # `AlertService` runs `error:` through `AlertSnippet`, which owns redaction
    # (14 secret shapes), clamping, UTF-8 coercion and fencing; `details:` is
    # passed to Slack untouched. `exit_status` and `exception_message` are
    # arbitrary runtime output — `AgentSessionJob` documents `AirPrepareError` as
    # embedding `air prepare`'s full stderr, and `air prepare` is the step that
    # resolves `.mcp.json`'s `${VAR}` credential substitutions, so that text can
    # plausibly carry a secret VALUE and not only a variable name. This is the
    # first path by which either field leaves the box, and a secret posted to
    # `#eng-alerts` cannot be un-posted.
    #
    # `UnclassifiedFailureReporter` makes the same call for the same reason, and
    # `AlertService`'s own class comment states the convention: `details:` is for
    # the prose a human needs on top of the snippet, not for a hand-copied
    # `e.message`. What stays in `details:` is `Session#failure_summary`, a
    # closed `case` over enumerated `failure_reason` values that never
    # interpolates runtime output.
    def raise_alert(session, trigger)
      AlertService.raise_alert(
        "Trigger session failed with its work undone",
        details: alert_details(session, trigger),
        source: "OrphanedTriggerFire",
        dedup_key: "orphaned_trigger_fire_session_#{session.id}",
        error: runtime_failure_text(session)
      )
    end

    def alert_details(session, trigger)
      lines = []
      lines << "The fire from #{trigger_label(session, trigger)} is spent, and the session carrying " \
               "it has failed."
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
      text = session.prompt.to_s
      text[CONTEXT_BLOCK_URL_PATTERN, 1] || text[SUBJECT_URL_PATTERN]
    end

    # The classified half, and only the classified half. `failure_summary` is a
    # closed `case` over enumerated `failure_reason` values, so it is safe to
    # render unredacted; the raw half rides on `error:` instead.
    #
    # It is not enough on its own, which is exactly why both are sent: it renders
    # `process_failed` as "Process failed", while the sentence that identifies
    # the 7844 failure — "Runtime session id … is already in use" — lives only in
    # `exit_status`. The alert carries both, in the two places that treat them
    # correctly.
    def failure_phrase(session)
      session.failure_summary.presence ||
        session.metadata&.dig("failure_reason").presence ||
        "no failure reason was recorded"
    end

    # The runtime's own words about the death, for `error:`. `exception_message`
    # is read alongside `exit_status` because a session that died on an exception
    # records no `exit_status` at all — the pair
    # `SessionStatusSummaryHarvestJob#failure_reason` reads for the same reason.
    def runtime_failure_text(session)
      metadata = session.metadata || {}
      RUNTIME_FAILURE_KEYS.filter_map { |key| metadata[key].presence }.uniq.join("\n\n").presence
    end
  end
end

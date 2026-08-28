# frozen_string_literal: true

# What an `ao_event` is ABOUT, and the per-subject rules AoEventTriggerJob applies
# before it fires a condition.
#
# Zimmer's internal event vocabulary began session-scoped — every event was a
# session state transition, so the firing job could take a session id, filter on
# `is_autonomous`, compare against a condition's `watched_session_id`, and check
# whether the transitioning session was one this very trigger had spawned. None
# of that is meaningful for an account falling into `needs_reauth`: there is no
# session to watch, no autonomy flag to consult, and nothing the trigger could
# have created. Rather than thread a `if account_event?` through each of those
# checks, the subject answers them.
#
# Adding a third subject means adding a class here and a name to
# TriggerCondition::AO_EVENT_NAMES. The firing job does not change.
class AoEventSubject
  # Why a condition must not fire for this subject, and how loudly to say so. A
  # broadcast condition skips on most transitions in the system, so the ordinary
  # ones stay at :debug; the loop-prevention skip is rare and worth :info,
  # exactly as it was before this seam existed.
  Skip = Data.define(:level, :message)

  # @param settle_marker [Integer, nil] the needs_input transition counter as it
  #   stood when the event was emitted. Only meaningful for session_needs_input;
  #   nil for every other event and for jobs enqueued before this argument
  #   existed, which is what makes the settle check opt-in rather than a
  #   behaviour change for in-flight work.
  # @return [AoEventSubject, nil] nil when the subject row is gone — it was
  #   deleted between the event being enqueued and this job running, which is
  #   routine and not an error.
  def self.resolve(event_name, subject_id, settle_marker = nil)
    if TriggerCondition::ACCOUNT_AO_EVENT_NAMES.include?(event_name)
      account = ClaudeAccount.find_by(id: subject_id)
      account && AccountSubject.new(account)
    elsif TriggerCondition::SESSION_AO_EVENT_NAMES.include?(event_name)
      session = Session.find_by(id: subject_id)
      session && SessionSubject.new(session, event_name: event_name, settle_marker: settle_marker)
    else
      # Dispatched explicitly rather than defaulting to a session, so an event
      # added to AO_EVENT_NAMES but not mapped here fails loudly. Falling through
      # would load whatever Session happens to own that id and apply session rules
      # to it — a silent misfire against an unrelated row.
      Rails.logger.error "[AoEventSubject] No subject mapped for event #{event_name.inspect}"
      nil
    end
  end

  # A session transitioning to needs_input / failed / archived.
  class SessionSubject
    attr_reader :session, :event_name, :settle_marker

    def initialize(session, event_name: nil, settle_marker: nil)
      @session = session
      @event_name = event_name.to_s
      @settle_marker = settle_marker
    end

    def id = session.id

    def to_s = "session ##{session.id}"

    # `failed` and `archived` are terminal: the transition has happened and there
    # is nothing to re-check. `needs_input` is not, and that asymmetry is the whole
    # flap.
    #
    # `pause` fires at every turn boundary, including the boundaries of a session
    # that is merely cycling — waking on its own `wake_me_up_later`, taking a
    # turn, and sleeping again, or pausing with a message already queued for it.
    # Those sessions are back in `waiting` or `running` microseconds later, but the
    # event they emitted on the way through woke every watcher subscribed to
    # `session_needs_input`. Each such wake cost the watcher a full agent turn and
    # destroyed its sibling wakes, which it then had to re-register — four trigger
    # writes per flap.
    #
    # So a `session_needs_input` event is stale unless, once the settle window has
    # elapsed, the session is still resting there and has not churned through
    # further transitions since the event was emitted. A newer transition has
    # emitted its own event with its own marker; this one is superseded.
    def stale?
      return false unless event_name == "session_needs_input"
      return false unless Session.exists?(session.id)

      session.reload

      if settle_marker && session.needs_input_transition_count != settle_marker
        Rails.logger.info(
          "[AoEventSubject] session ##{session.id} churned past the settle window " \
          "(marker #{settle_marker}, now #{session.needs_input_transition_count}) — superseded"
        )
        return true
      end

      return false if session.resting_in_needs_input?

      Rails.logger.info(
        "[AoEventSubject] session ##{session.id} did not settle in needs_input " \
        "(status=#{session.status}) — turn-boundary flap, not a rest"
      )
      true
    end

    def skip(condition)
      scoped = condition.session_scoped_ao_event?

      if scoped && condition.watched_session_id != session.id
        return Skip.new(level: :debug, message: "condition #{condition.id} watches session ##{condition.watched_session_id}")
      end

      # Session-scoped conditions are one-shot: once they've fired (or been
      # cancelled by a manual resume), don't re-fire on subsequent transitions of
      # the watched session.
      if scoped && condition.last_triggered_at.present?
        return Skip.new(level: :debug, message: "session-scoped condition #{condition.id} already fired")
      end

      # Broadcast (unscoped) conditions only fire for autonomous sessions —
      # user-paused sessions shouldn't trigger global automation. Session-scoped
      # conditions are an explicit per-session opt-in, so they fire regardless.
      if !scoped && !session.is_autonomous
        return Skip.new(level: :debug, message: "session ##{session.id} is not autonomous")
      end

      # Loop prevention: a session this very trigger spawned must not fire it again.
      if session.metadata&.dig("trigger_id").to_s == condition.trigger.id.to_s
        return Skip.new(level: :info, message: "session ##{session.id} was created by trigger #{condition.trigger.id}")
      end

      nil
    end

    def label(event_name)
      title = session.title.presence || "Untitled"
      case event_name
      when "session_needs_input" then "Session ##{session.id} (#{title}) needs input"
      when "session_failed" then "Session ##{session.id} (#{title}) failed"
      when "session_archived" then "Session ##{session.id} (#{title}) archived"
      else "Session ##{session.id} (#{title}) #{event_name}"
      end
    end
  end

  # A runtime account that can no longer refresh its token, so the pool has
  # stopped drawing on it and only a human can put it back.
  class AccountSubject
    RUNTIME_LABELS = {
      "claude_code" => "Claude",
      "codex" => "Codex"
    }.freeze

    attr_reader :account

    def initialize(account) = @account = account

    def id = account.id

    def to_s = "account ##{account.id} (#{account.email})"

    # Unlike a session transition, this condition can un-happen between the
    # transition and this job running: the auto-heal sweep writes `active` back
    # onto an account whose latest reading has cleared, and the recovery sweep
    # probes dead refresh tokens on a timer. Spawning a session to tell a human
    # about an account that is working again is worse than saying nothing.
    #
    # Releasing the throttle slot is part of being stale, not an extra: the claim
    # was taken at emit time for a notification that is now not going to happen,
    # and leaving it taken would silence the NEXT — real — condemnation for the
    # rest of the window. The flood the throttle exists to stop is unaffected,
    # because in that flood the account is still `needs_reauth` when the job runs
    # and this branch is not taken.
    def stale?
      return true unless account.class.exists?(account.id)
      return false if account.reload.needs_reauth?

      account.clear_reauth_alert!
      true
    end

    # An account event has no watched subject, no autonomy flag, and no session
    # the trigger could have created, so every enabled condition for it fires.
    # Repeat-suppression is not this method's job either: it happens once, at the
    # emit site, against ClaudeAccount#reauth_alerted_at — see
    # ClaudeAccount#claim_reauth_alert_slot!.
    def skip(_condition) = nil

    def label(_event_name)
      runtime = RUNTIME_LABELS.fetch(account.runtime.to_s, account.runtime.to_s)
      "#{runtime} account #{account.email} needs re-authentication"
    end
  end
end

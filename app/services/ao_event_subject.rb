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

  # @return [AoEventSubject, nil] nil when the subject row is gone — it was
  #   deleted between the event being enqueued and this job running, which is
  #   routine and not an error.
  def self.resolve(event_name, subject_id)
    if TriggerCondition::ACCOUNT_AO_EVENT_NAMES.include?(event_name)
      account = ClaudeAccount.find_by(id: subject_id)
      account && AccountSubject.new(account)
    else
      session = Session.find_by(id: subject_id)
      session && SessionSubject.new(session)
    end
  end

  # A session transitioning to needs_input / failed / archived.
  class SessionSubject
    attr_reader :session

    def initialize(session) = @session = session

    def id = session.id

    def to_s = "session ##{session.id}"

    # A session event is about a transition that has already happened, so there is
    # nothing to re-check: the session is in the state the event names.
    def stale? = false

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
    # transition and this job running: `sync_from_filesystem!` writes `active`
    # back onto an account whose credentials file still parses, and the recovery
    # sweep probes dead refresh tokens on a timer. Spawning a session to tell a
    # human about an account that is working again is worse than saying nothing.
    def stale? = !account.reload.needs_reauth?

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

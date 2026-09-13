# frozen_string_literal: true

require "automated_prompts"

# Parks a session its provider refused on a quota wall, when the session's runtime
# has no account pool — and wakes it on a timed ladder until the wall is gone.
#
# == Why this is not AuthOutageParkService ==
#
# A Claude or Codex quota wall is a fact about a POOL. The session rotates to
# another account, or parks, and AuthOutageParkService's sweep resumes it once
# QuotaResetCheckerJob sees an account in that pool come back. Every surface that
# reads `auth_outage_reason` — the banner, `get_session`, the fleet wake, the
# stranded-sleep rescue — assumes exactly that.
#
# A Pi session has no pool (PiAuthProvider#pools_accounts? is false). It
# authenticates with one provider key, and the wall is that key's balance or
# plan: a 402 from OpenRouter, a quota-worded 429 (PiTurnError, "Quota walls").
# An auth-outage park would wait for an account that can never appear, and
# nothing reports when a prepaid balance is topped up. So the only evidence that
# the wall is gone is a request that gets through — which is what this schedules.
#
# == What parking does ==
#
# 1. Records the streak on the session (METADATA_KEY): when it began, how many
#    re-checks it has spent, when the next one is, and the provider's own words.
# 2. Arms a one-time wake through Sessions::ScheduleWakeUp — the same trigger
#    `wake_me_up_later` creates. Creating it marks the still-running session
#    `pending_sleep`, and the pause that follows the caller's `needs_input`
#    carries it to `waiting`. When it fires, the session resumes on its own
#    session id with a recovery nudge; Pi re-sends the conversation, and either the
#    turn goes through or the wall answers again and this parks it one rung higher.
# 3. Logs the park on the session, and on the FIRST park of a streak sends a push
#    notification — a balance usually needs a human to top it up, and that human
#    should hear about it once, not every rung.
#
# It spends no API-error retry budget and pages nobody: nothing here logs at
# ERROR, and the caller never reaches UnclassifiedFailureReporter.
#
# == The ladder, and what bounds it ==
#
# Re-checks at LADDER's intervals — 15 minutes, doubling to 8 hours, then every 8
# hours. A re-check against a wall that is still there costs one request the
# provider refuses before any inference, so the steady state is three cheap
# requests a day per parked session.
#
# A streak ends the moment a turn completes (ProcessLifecycleManager calls
# .end_streak!), so the next wall starts again at 15 minutes. A streak that never
# ends is bounded by CEILING, counted from the streak's first park: once the next
# re-check would land past it, Zimmer stops scheduling, clears the streak, and
# leaves the session in `needs_input` saying so, with a second push. Seven days is
# far past any quota window that resets on its own, so a wall still standing
# then is a balance nobody is refilling, and the session is the human's. Clearing
# the streak there is deliberate: resuming it is a human decision, and that
# decision earns a fresh ladder.
#
# The key is deliberately NOT in Session::STALE_RETRY_METADATA_KEYS. The wake
# this arms is a follow-up delivery, and a streak cleared by the resume it paid
# for would restart at 15 minutes on every rung and never reach CEILING.
class ProviderQuotaWallPark
  include DatabaseRetry

  # Wait before each re-check, by park number; the last one repeats.
  LADDER = [ 15.minutes, 30.minutes, 1.hour, 2.hours, 4.hours, 8.hours ].freeze

  # How long a streak may keep re-checking, from its first park.
  CEILING = 7.days

  # Session metadata holding the streak: started_at, parks, next_check_at, message.
  METADATA_KEY = "provider_quota_wall"

  # How much of the provider's message the log, the push and the exit reason carry.
  MESSAGE_LIMIT = 300

  # What #park! did.
  #   parked        - true when a re-check is scheduled and the session will sleep
  #   next_check_at - when it fires, or nil when nothing was scheduled
  #   park_number   - which park of the streak this was
  #   error_message - the sentence the caller's ExitDecision carries
  Outcome = Data.define(:parked, :next_check_at, :park_number, :error_message) do
    def parked? = parked
  end

  attr_reader :session

  def initialize(session, log_buffer: nil, logger: nil)
    @session = session
    @log_buffer = log_buffer
    @logger = logger || StructuredLogger.new({ session_id: session&.id, service: "ProviderQuotaWallPark" })
  end

  # The wait before park number `park_number` (1-based).
  #
  # @param park_number [Integer]
  # @return [ActiveSupport::Duration]
  def self.interval_for(park_number)
    LADDER[[ park_number, 1 ].max - 1] || LADDER.last
  end

  # The streak this session is in, or nil.
  #
  # @param session [Session, nil]
  # @return [Hash, nil] the stored record
  def self.streak(session)
    record = session&.metadata&.dig(METADATA_KEY)
    record.is_a?(Hash) ? record : nil
  end

  # Is this session parked on a quota wall right now — in a streak, and marked to
  # sleep until the re-check? The row-level question AgentSessionJob asks before it
  # treats a `needs_input` exit as a completed turn, alongside
  # AuthOutageParkService's `auth_outage_reason`.
  #
  # Both halves, because each alone says too little: a streak outlives the turn it
  # parked (it ends only when a turn completes), and `pending_sleep` is written by
  # any wake armed from a running turn.
  #
  # @param session [Session, nil]
  # @return [Boolean]
  def self.parked?(session)
    streak(session).present? && session.metadata["pending_sleep"].present?
  end

  # End the streak: a turn got through, so the wall is gone. A no-op, and no
  # write, for a session that is not in one.
  #
  # @param session [Session, nil]
  # @return [Boolean] true when a streak was ended
  def self.end_streak!(session)
    return false unless streak(session)

    session.remove_metadata!(METADATA_KEY)
    true
  rescue => e
    # Best effort: a streak left behind costs the next wall a higher rung, never a
    # session.
    Rails.logger.warn "[ProviderQuotaWallPark] Could not end the quota-wall streak for session " \
      "#{session&.id} (#{e.class}): #{e.message}"
    false
  end

  # Park the session on the next rung of its ladder, or stop at the ceiling.
  #
  # @param message [String] the provider's own words for the refusal
  # @return [Outcome]
  def park!(message:)
    now = Time.current
    session.reload
    streak = self.class.streak(session)
    started_at = parse_time(streak&.dig("started_at")) || now
    park_number = streak ? streak["parks"].to_i + 1 : 1
    next_check_at = now + self.class.interval_for(park_number)
    words = message.to_s.squish.truncate(MESSAGE_LIMIT)

    return stop_at_ceiling!(started_at, park_number - 1, words) if next_check_at > started_at + CEILING

    with_db_retry do
      session.merge_metadata!(
        METADATA_KEY => {
          "started_at" => started_at.utc.iso8601,
          "parks" => park_number,
          "next_check_at" => next_check_at.utc.iso8601,
          "message" => words
        }
      )
    end

    Sessions::ScheduleWakeUp.call(
      session: session,
      wake_at: next_check_at.utc.strftime("%Y-%m-%dT%H:%M:%S"),
      prompt: AutomatedPrompts.system_recovery(reason: "a provider quota-wall re-check (check #{park_number})")
    )

    add_log(park_log(words, park_number, next_check_at, started_at + CEILING))
    notify!("#{headline(words)} Parked; Zimmer re-checks on a schedule and resumes it once the provider answers.") if park_number == 1
    @logger.warn("Parked session on a provider quota wall",
      park_number: park_number, next_check_at: next_check_at.utc.iso8601)

    Outcome.new(
      parked: true,
      next_check_at: next_check_at,
      park_number: park_number,
      error_message: "Provider quota wall — session parked, re-checking at #{next_check_at.utc.iso8601}: #{words}"
    )
  rescue => e
    # The re-check could not be armed, so the session must not sleep on nothing:
    # it comes to rest in needs_input, which the caller's decision already says,
    # with a sentence a human can act on.
    @logger.warn("Could not park session on a provider quota wall", error: "#{e.class}: #{e.message}")
    add_log("Provider quota wall, but Zimmer could not schedule a re-check (#{e.message}). " \
      "Resume this session once the provider balance is restored.")
    Outcome.new(
      parked: false,
      next_check_at: nil,
      park_number: park_number,
      error_message: "Provider quota wall — could not schedule a re-check; resume once the balance is restored: #{words}"
    )
  end

  private

  def stop_at_ceiling!(started_at, spent, words)
    with_db_retry { session.remove_metadata!(METADATA_KEY) }

    add_log(
      "Provider quota wall has stood since #{started_at.utc.iso8601} across #{spent} re-check(s), " \
        "and the next would pass the #{CEILING.inspect} ceiling. Zimmer has stopped re-checking. " \
        "Restore the provider balance, then send this session a message to resume it: #{words}"
    )
    notify!("#{headline(words)} Still refused after #{CEILING.inspect}; Zimmer stopped re-checking. " \
      "Top up, then message the session.")
    @logger.warn("Provider quota wall reached its ceiling", re_checks: spent, started_at: started_at.utc.iso8601)

    Outcome.new(
      parked: false,
      next_check_at: nil,
      park_number: spent,
      error_message: "Provider quota wall still standing after #{CEILING.inspect} — re-checks stopped; " \
        "resume once the balance is restored: #{words}"
    )
  end

  def park_log(words, park_number, next_check_at, ceiling_at)
    "Provider quota wall: #{runtime_label}'s provider refused this turn for lack of quota or credit " \
      "(#{words}). No retry budget spent. Parked — Zimmer re-checks at #{next_check_at.utc.iso8601} " \
      "(check #{park_number}; the wait doubles while the wall stands, up to #{LADDER.last.inspect}). " \
      "Re-checks stop at #{ceiling_at.utc.iso8601} if it is still standing then."
  end

  def headline(words)
    "Session ##{session.id} (#{runtime_label}) hit a provider quota wall: #{words.truncate(120)}"
  end

  def notify!(text)
    SendPushNotificationJob.perform_later(session.id, :custom_message, text)
  rescue => e
    @logger.info("Failed to enqueue quota-wall push notification", error: e.message)
  end

  def add_log(content)
    if @log_buffer
      @log_buffer.add(content, level: "warning")
      @log_buffer.flush
    else
      session.logs.create!(content: content, level: "warning")
    end
  rescue => e
    @logger.info("Failed to log the quota-wall park", error: e.message)
  end

  def runtime_label
    RuntimeRegistry.label_for(session.agent_runtime)
  end

  def parse_time(raw)
    raw.present? ? Time.iso8601(raw.to_s) : nil
  rescue ArgumentError
    nil
  end
end

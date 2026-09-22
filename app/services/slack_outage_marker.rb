# frozen_string_literal: true

# The reaction Zimmer itself puts on a Slack message whose session cannot reach the model.
#
# Both Slack triggers make :eyes: the agent's own first act, so it costs a model turn. While the
# provider is answering 529 Overloaded there is no model turn to take, and the person who posted
# sees nothing at all — sessions 19830 and 19831 sat 30 minutes that way. This is the
# acknowledgement that does not need the model.
#
# It is deliberately NOT :eyes:. On the passive listener, :eyes: means "I will reply", and the
# agent withholds it from chatter it decides to stay out of. A Zimmer-side :eyes: would change what
# the reaction means. So Zimmer uses a different emoji, and only during an outage: a `running` or
# `waiting` session must have hit an outage-class API error (ApiErrorRetryService.outage_error? —
# a server error or transient rate limit, not a quota wall or a malformed tool call) and never had
# a model turn, and the message must be older than THRESHOLD. On an ordinary day Zimmer never
# reacts on a message, and the passive listener's silence stays silent.
#
# The marker comes off when the agent's first model turn lands, or when the session ends
# (archived, failed) without one. A session in `needs_input` keeps a marker it already has: a
# deploy pause or an auth-outage park comes back into the same outage, and a marker removed there
# would never return.
#
# State lives in the session's metadata, so it is visible on the session without a shell:
#
#   slack_channel_id / slack_message_ts   the message the session was spawned for (set at fire)
#   slack_outage_marker_adding_at         Zimmer is about to call Slack to add it (written first, so a
#                                         crash mid-call cannot leave a reaction nothing knows about)
#   slack_outage_marker_added_at          when Slack confirmed the reaction
#   slack_outage_marker_settled_at        nothing more to do for this session, ever
#   slack_outage_marker_outcome           why it settled: not_needed, removed, add_failed:<code>, ...
#   slack_outage_marker_error             the last Slack error that is worth retrying
#   slack_outage_marker_reported_at       when SlackOutageMarkerJob first reported an exception for it
#
# Every write is idempotent and the job that drives this (SlackOutageMarkerJob) is a singleton
# sweep, so running it twice is a no-op. Once settled, a session is never marked again: a marker
# that has come off does not come back on a later outage in the same session, because by then the
# agent has had its turn.
#
# Claude Code only. The two signals come from the stored transcript — an entry with
# `isApiErrorMessage`, and an assistant entry from a real model — and Claude Code is the runtime
# that writes them in that shape. A Codex or Pi session spawned by a Slack trigger is settled
# `unsupported_runtime` and never marked.
class SlackOutageMarker
  # A neutral "this is waiting", not "I will reply".
  REACTION = "hourglass_flowing_sand"

  # How long the poster has waited, from the message's own ts, before Zimmer says anything.
  THRESHOLD = 5.minutes

  # The only runtime whose stored transcript this reads.
  SUPPORTED_RUNTIME = "claude_code"

  # Where a marker may be added.
  ACTIVE_STATUSES = %w[running waiting].freeze

  # Where a session has ended, and a marker comes off.
  ENDED_STATUSES = %w[archived failed].freeze

  # Slack answers that mean the message or its channel is out of reach for good. Nothing to
  # remove, and nothing a retry would change.
  GONE_CODES = %w[message_not_found channel_not_found not_in_channel is_archived thread_locked].freeze

  # Slack's own "try again" answers, which arrive as an HTTP 200 body and so as a plain ApiError
  # rather than a TransientError.
  RETRYABLE_CODES = %w[internal_error fatal_error service_unavailable request_timeout ratelimited].freeze

  CHANNEL_KEY = "slack_channel_id"
  TS_KEY = "slack_message_ts"
  ADDING_KEY = "slack_outage_marker_adding_at"
  ADDED_KEY = "slack_outage_marker_added_at"
  SETTLED_KEY = "slack_outage_marker_settled_at"
  OUTCOME_KEY = "slack_outage_marker_outcome"
  ERROR_KEY = "slack_outage_marker_error"
  REPORTED_KEY = "slack_outage_marker_reported_at"

  # The metadata a Slack trigger fire stamps on the session it spawns.
  # @return [Hash]
  def self.source_metadata(channel_id:, message_ts:)
    return {} if channel_id.blank? || message_ts.blank?

    { CHANNEL_KEY => channel_id, TS_KEY => message_ts.to_s }
  end

  # Sessions this may still have work for: spawned by a Slack trigger and not yet settled. An
  # unmarked one must also be young enough that a reaction on the message still means something;
  # a marked one stays a candidate however old it is, until its marker comes off. Everything else
  # about "is it due" needs the transcript, so it is decided per session in #converge!.
  # @return [ActiveRecord::Relation]
  def self.candidates(now: Time.current, window: 1.day)
    marked = Session.where("metadata ?| array[:keys]", keys: [ ADDING_KEY, ADDED_KEY ])

    Session.where("metadata ? :key", key: TS_KEY)
      .where("NOT metadata ? :key", key: SETTLED_KEY)
      .merge(Session.where(created_at: (now - window)..).or(marked))
  end

  def initialize(session, now: Time.current, logger: Rails.logger)
    @session = session
    @now = now
    @logger = logger
  end

  # Bring the reaction on the Slack message in line with the session, and return what it did.
  #
  # @return [Symbol] :added, :removed, :settled, :waiting (nothing to do yet), or :error (a
  #   transient Slack failure, left for the next sweep)
  def converge!
    return :settled if settled?

    return settle!("unsupported_runtime") unless session.agent_runtime == SUPPORTED_RUNTIME

    if added?
      converge_marked
    elsif adding?
      # An add was started and not confirmed: a crash, or a Slack error worth retrying. Finish it
      # while it is still due. Otherwise the reaction may be on the message, so take it off.
      due? ? add_marker : converge_marked
    else
      converge_unmarked
    end
  end

  private

  attr_reader :session, :now, :logger

  def converge_unmarked
    return settle!("not_needed") if model_turn? || ended?
    return :waiting unless due?

    # The sweep loaded this row in a batch. Read it again right before touching Slack, so a model
    # turn that landed since is not answered with a marker.
    session.reload
    @transcript_signals = nil
    return converge_unmarked unless due?

    session.merge_metadata!(ADDING_KEY => now.iso8601)
    add_marker
  end

  def add_marker
    SlackService.add_reaction(channel: channel_id, timestamp: message_ts, name: REACTION)
    session.merge_metadata!({ ADDED_KEY => now.iso8601 }, [ ERROR_KEY, ADDING_KEY ])
    session.logs.create!(
      content: "Slack: this session has hit API errors and has not reached the model yet, so Zimmer put " \
               ":#{REACTION}: on the message that started it. It comes off when the agent gets its first turn.",
      level: "info"
    )
    logger.info "[SlackOutageMarker] Added :#{REACTION}: to #{channel_id}/#{message_ts} for session #{session.id}"
    :added
  rescue SlackService::TransientError => e
    retry_later(e)
  rescue SlackService::SlackError => e
    code = error_code(e)
    return retry_later(e) if RETRYABLE_CODES.include?(code)

    # A scope the bot lacks does not grow back, and a message that is gone does not return, so
    # there is nothing to retry. Settled with the code, and said on the session, where an operator
    # reading it can see why the poster got nothing.
    logger.warn "[SlackOutageMarker] Could not add :#{REACTION}: for session #{session.id}: #{e.message}"
    session.logs.create!(content: add_failure_note(code), level: "warning")
    settle!("add_failed:#{code}")
  end

  def converge_marked
    return :waiting unless model_turn? || ended?

    result = SlackService.remove_reaction(channel: channel_id, timestamp: message_ts, name: REACTION)
    logger.info "[SlackOutageMarker] Removed :#{REACTION}: from #{channel_id}/#{message_ts} for session #{session.id} (#{result})"
    settle!("removed")
    :removed
  rescue SlackService::SlackError => e
    removal_failed(e)
  end

  # Removal failing is worse than adding failing: the marker would stay on a message whose
  # session has moved on. So only the answers that mean the message is unreachable settle it,
  # and everything else is retried by the next sweep until the candidate window closes.
  def removal_failed(error)
    code = error_code(error)
    return retry_later(error) unless GONE_CODES.include?(code)

    logger.warn "[SlackOutageMarker] Message for session #{session.id} is out of reach (#{code}); nothing to remove"
    settle!("removed:#{code}")
  end

  def retry_later(error)
    logger.warn "[SlackOutageMarker] Slack error for session #{session.id}, retrying next sweep: #{error.message}"
    session.merge_metadata!(ERROR_KEY => error.message.to_s.truncate(500))
    :error
  end

  # Slack's own error string when Slack answered, else the class ("ConfigurationError" for an
  # unset token).
  def error_code(error)
    error.try(:code).presence || error.class.name.demodulize
  end

  def settle!(outcome)
    session.merge_metadata!({ SETTLED_KEY => now.iso8601, OUTCOME_KEY => outcome }, [ ERROR_KEY, ADDING_KEY ])
    :settled
  end

  def add_failure_note(code)
    base = "Slack: this session has hit API errors and has not reached the model yet, but Zimmer could not put " \
           ":#{REACTION}: on the message that started it (#{code})."
    return base unless code == "missing_scope"

    "#{base} The Slack bot token needs the reactions:write scope."
  end

  def settled? = metadata[SETTLED_KEY].present?
  def added? = metadata[ADDED_KEY].present?
  def adding? = metadata[ADDING_KEY].present?
  def active? = ACTIVE_STATUSES.include?(session.status.to_s)
  def ended? = ENDED_STATUSES.include?(session.status.to_s)
  def channel_id = metadata[CHANNEL_KEY]
  def message_ts = metadata[TS_KEY]
  def metadata = session.metadata || {}

  def due?
    active? && !model_turn? && outage_error? && waited_past_threshold?
  end

  def waited_past_threshold?
    seconds = message_ts.to_s.to_f
    seconds.positive? && now - Time.zone.at(seconds) >= THRESHOLD
  end

  def model_turn?
    transcript_signals[:model_turn]
  end

  def outage_error?
    transcript_signals[:outage_error]
  end

  # One pass over the stored transcript. An API-error entry is the runtime's own line
  # (`isApiErrorMessage: true`, `model: "<synthetic>"`), and it counts only when it is the provider
  # being unavailable. A model turn is an assistant entry from a real model: not an API error, and
  # not `<synthetic>`, which also rules out the "No response requested." stub Claude Code writes on
  # resume (ClaudeTranscriptNormalizer.resume_stub?).
  def transcript_signals
    @transcript_signals ||= session.parsed_transcript.each_with_object({ model_turn: false, outage_error: false }) do |entry, found|
      next unless entry.is_a?(Hash) && entry["type"] == "assistant"

      if entry["isApiErrorMessage"] == true
        found[:outage_error] = true if ApiErrorRetryService.outage_error?(entry["error"], entry_text(entry))
      else
        model = entry.dig("message", "model").to_s
        found[:model_turn] = true if model.present? && model != ClaudeTranscriptNormalizer::SYNTHETIC_MODEL
      end
    end
  end

  def entry_text(entry)
    content = entry.dig("message", "content")
    return content.to_s unless content.is_a?(Array)

    content.filter_map { |block| block["text"] if block.is_a?(Hash) }.join(" ")
  end
end

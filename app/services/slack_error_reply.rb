# frozen_string_literal: true

# The threaded reply Zimmer itself posts on a Slack request its session cannot serve.
#
# When a session spawned by an @mention or a DM cannot reach the model — the account pool is out
# of quota, the provider is down, or the session failed outright — the agent cannot take the turn
# that would tell the person who asked. SlackOutageMarker covers the first few minutes of an
# outage with a reaction. This covers the cases where a reaction is not enough: the person gets one
# short, fixed message in the thread of their own request saying what happened and linking the
# session. The model is never involved; the text is one of TEMPLATES.
#
# == When it posts
#
# Only for a message addressed to Zimmer: a session fired by a `bot_mention` or `dm_message`
# condition. A passive-listening or `new_message` session was started for a message nobody asked
# Zimmer about, and the agent may well have stayed out of it, so an error reply there would be
# Zimmer talking where it was never invited — and, during a quota outage, on every message in the
# channel.
#
# Only before the agent has had a model turn. Once a real model has answered, the agent has
# had its chance to reply itself, so Zimmer never posts after it and never doubles up with it.
#
# One reply per session per error class, picked in this order:
#
#   class   | when                                                                    | waited
#   --------|-------------------------------------------------------------------------|-------
#   failed  | the session is `failed`, and not by a failure Zimmer resumes on its own   | any
#           | (a deploy interruption, an MCP server waiting on OAuth)                  |
#   quota   | parked on a quota_exhausted auth outage, or held or paused by the spot   | QUOTA_THRESHOLD
#           | gate for utilization                                                    |
#   outage  | parked as auth_unrecoverable, or outage-class API errors                 | OUTAGE_THRESHOLD
#           | (ApiErrorRetryService.outage_error?) since the last user entry, while a  |
#           | turn is underway                                                        |
#
# A quota-wall line in the transcript is deliberately not a quota signal: Claude Code rotates to
# another account on one, and a pool that is really out of quota ends in a quota_exhausted park.
#
# "Waited" is measured from the Slack message's own ts, so a session that is merely slow to start
# never gets a reply, and the turn-boundary flap of a single API error does not either. Before
# posting, the row is read again, so a model turn that landed since the sweep loaded it wins.
#
# == State, on the session's metadata
#
#   slack_error_reply_<class>_posting_at   about to call Slack (written first)
#   slack_error_reply_<class>_posted_at    Slack confirmed the post
#   slack_error_reply_<class>_outcome      posted, unconfirmed, or failed:<code>
#   slack_error_reply_settled_at           nothing more to do for this session, ever
#   slack_error_reply_outcome              why it settled: not_needed, not_addressed, ...
#   slack_error_reply_reported_at          when SlackErrorReplyJob first reported an exception for it
#
# chat.postMessage is not idempotent, so this is at-most-once rather than at-least-once: the
# posting key is written before the call, and a posting key found without a posted key (a crash
# mid-call) is settled `unconfirmed` and never posted again. It is posted with
# `retry_timeouts: false`, so SlackService does not resend a timed-out post either, since the post may have landed. Only a 429 — which Slack documents as
# not applied — clears the intent and is retried on the next sweep. Every other Slack error (a
# missing scope, a message that is gone) settles the class with its code and is logged on the
# session; nothing here raises or pages.
#
# Claude Code only, for the same reason as SlackOutageMarker: the "has the model answered" signal
# is read off Claude Code's stored transcript.
class SlackErrorReply
  # The only place the wording lives. `%{session_url}` is the session page. Slack mrkdwn.
  TEMPLATES = {
    "failed" => ":x: Zimmer couldn't work on this request: its session failed before the agent " \
                "could reply. Someone needs to look at it, or you can ask again. <%{session_url}|View the session>",
    "quota" => ":hourglass_flowing_sand: Zimmer has run out of inference quota for now, so it can't start on " \
               "this yet. Your request is queued, and the agent will reply here once quota frees up. " \
               "<%{session_url}|View the session>",
    "outage" => ":warning: Zimmer can't reach its AI provider right now, so it hasn't been able to start " \
                "on this. It keeps retrying, and the agent will reply here once it gets through. " \
                "<%{session_url}|View the session>"
  }.freeze

  # The order a session is classified in: the first class that applies is the one considered.
  CLASSES = %w[failed quota outage].freeze

  # How long the poster has waited, from the message's own ts, before Zimmer replies. A quota park
  # lasts hours, so five minutes is enough to know it is not a blip; an outage is often over in
  # minutes, and SlackOutageMarker's reaction already covers the first of them.
  QUOTA_THRESHOLD = 5.minutes
  OUTAGE_THRESHOLD = 15.minutes

  # Failures Zimmer resumes by itself: DeploymentRecoveryJob picks up a session a deploy killed, and
  # McpOauthResumeService one that was waiting on an MCP server's OAuth. Neither is the end of the
  # request, so neither gets the "failed" reply.
  RECOVERABLE_EXCEPTION_CLASSES = %w[GoodJob::InterruptError].freeze
  RECOVERABLE_FAILURE_REASONS = %w[oauth_required].freeze

  # The Slack conditions whose message was addressed to Zimmer.
  ADDRESSED_EVENT_TYPES = %w[bot_mention dm_message].freeze

  SUPPORTED_RUNTIME = SlackOutageMarker::SUPPORTED_RUNTIME

  SETTLED_KEY = "slack_error_reply_settled_at"
  OUTCOME_KEY = "slack_error_reply_outcome"
  REPORTED_KEY = "slack_error_reply_reported_at"

  def self.posting_key(error_class) = "slack_error_reply_#{error_class}_posting_at"
  def self.posted_key(error_class) = "slack_error_reply_#{error_class}_posted_at"
  def self.class_outcome_key(error_class) = "slack_error_reply_#{error_class}_outcome"

  # The reply text for an error class.
  # @return [String]
  def self.render(error_class, session)
    format(TEMPLATES.fetch(error_class), session_url: "#{AppUrl.base_url}/sessions/#{session.id}")
  end

  # Sessions spawned by a Slack trigger, recent enough that a reply still means something, and not
  # yet settled. Whether one is due needs its status and transcript, so it is decided in #converge!.
  # @return [ActiveRecord::Relation]
  def self.candidates(now: Time.current, window: 1.day)
    Session.where("metadata ? :key", key: SlackOutageMarker::TS_KEY)
      .where("NOT metadata ? :key", key: SETTLED_KEY)
      .where(created_at: (now - window)..)
  end

  def initialize(session, now: Time.current, logger: Rails.logger)
    @session = session
    @now = now
    @logger = logger
  end

  # Post the reply the session is due, if any, and return what happened.
  #
  # @return [Symbol] :posted, :post_failed (Slack refused; recorded, not retried), :settled,
  #   :waiting (nothing due yet), or :error (a 429, left for the next sweep)
  def converge!
    return :settled if metadata[SETTLED_KEY].present?
    return settle!("unsupported_runtime") unless session.agent_runtime == SUPPORTED_RUNTIME
    return settle!("not_addressed") unless ADDRESSED_EVENT_TYPES.include?(metadata[SlackOutageMarker::EVENT_TYPE_KEY])

    finish_unconfirmed_posts
    return settle!("not_needed") if model_turn?

    error_class = due_class
    if error_class.nil?
      # Nothing more can become due for a session that has ended.
      return ended? ? settle!("ended") : :waiting
    end

    # The sweep loaded this row in a batch. Read it again right before touching Slack, so a model
    # turn or a resume that landed since is not answered with an error reply.
    session.reload
    @signals = nil
    return converge! unless due_class == error_class

    post(error_class)
  end

  private

  attr_reader :session, :now, :logger

  def post(error_class)
    session.merge_metadata!(self.class.posting_key(error_class) => now.iso8601)
    SlackService.post_message(channel: channel_id, text: self.class.render(error_class, session),
                              thread_ts: thread_ts, retry_timeouts: false)
    session.merge_metadata!(self.class.posted_key(error_class) => now.iso8601,
                            self.class.class_outcome_key(error_class) => "posted")
    session.logs.create!(
      content: "Slack: this session could not serve the request that started it (#{error_class}), so Zimmer " \
               "replied in its thread with a fixed message saying so.",
      level: "info"
    )
    logger.info "[SlackErrorReply] Posted the #{error_class} reply to #{channel_id}/#{thread_ts} for session #{session.id}"
    settle!("failed_reply_posted") if error_class == "failed"
    :posted
  rescue SlackService::RateLimitedError => e
    # A 429 was not applied, so the post can be tried again without risking a second copy.
    session.remove_metadata!(self.class.posting_key(error_class))
    logger.warn "[SlackErrorReply] Rate limited posting for session #{session.id}, retrying next sweep: #{e.message}"
    :error
  rescue SlackService::SlackError => e
    code = e.try(:code).presence || e.class.name.demodulize
    logger.warn "[SlackErrorReply] Could not post the #{error_class} reply for session #{session.id}: #{e.message}"
    session.merge_metadata!(self.class.class_outcome_key(error_class) => "failed:#{code}")
    session.logs.create!(content: failure_note(error_class, code), level: "warning")
    settle!("post_failed:#{code}") if error_class == "failed"
    :post_failed
  end

  # A posting key with no posted key and no outcome: a crash between the intent and the answer.
  # The message may have landed, so it is not posted again.
  def finish_unconfirmed_posts
    CLASSES.each do |error_class|
      next if metadata[self.class.posting_key(error_class)].blank?
      next if metadata[self.class.class_outcome_key(error_class)].present?

      session.merge_metadata!(self.class.class_outcome_key(error_class) => "unconfirmed")
    end
  end

  # The first class that applies to the session right now and has not been handled yet.
  def due_class
    return nil if model_turn?

    CLASSES.find { |error_class| applies?(error_class) && !handled?(error_class) && waited?(error_class) }
  end

  def applies?(error_class)
    case error_class
    when "failed" then session.failed? && !recoverable_failure?
    when "quota" then !ended? && quota_bound?
    when "outage" then !ended? && outage_bound?
    end
  end

  def handled?(error_class)
    metadata[self.class.posting_key(error_class)].present? || metadata[self.class.class_outcome_key(error_class)].present?
  end

  def waited?(error_class)
    threshold = { "failed" => 0.seconds, "quota" => QUOTA_THRESHOLD, "outage" => OUTAGE_THRESHOLD }.fetch(error_class)
    seconds = metadata[SlackOutageMarker::TS_KEY].to_s.to_f
    seconds.positive? && now - Time.zone.at(seconds) >= threshold
  end

  def recoverable_failure?
    RECOVERABLE_EXCEPTION_CLASSES.include?(metadata["exception_class"]) ||
      RECOVERABLE_FAILURE_REASONS.include?(metadata["failure_reason"])
  end

  # Waiting on inference quota: the account pool is out, or the spot gate is holding it for quota.
  def quota_bound?
    return true if metadata["auth_outage_reason"] == AuthOutageParkService::QUOTA_EXHAUSTED
    return true if SpotSessionHold.held?(session) && metadata[SpotSessionHold::HELD_REASON] == SpotSessionHold::UTILIZATION_REASON

    SpotSessionPause.paused?(session) && !SpotSessionPause.queued_by_user?(session) && !SpotSessionPause.preempted?(session)
  end

  # Waiting on the provider itself: its credentials are unusable, or it has kept answering errors
  # since the session's latest prompt. An error before a resume says nothing about now.
  def outage_bound?
    return true if metadata["auth_outage_reason"] == AuthOutageParkService::AUTH_UNRECOVERABLE

    session.in_turn_state? && signals[:outage_error_since_prompt]
  end

  def failure_note(error_class, code)
    base = "Slack: this session could not serve the request that started it (#{error_class}), but Zimmer " \
           "could not reply in its thread (#{code})."
    code == "missing_scope" ? "#{base} The Slack bot token needs the chat:write scope." : base
  end

  def settle!(outcome)
    session.merge_metadata!(SETTLED_KEY => now.iso8601, OUTCOME_KEY => outcome)
    :settled
  end

  def model_turn? = signals[:model_turn]
  def signals = (@signals ||= SlackOutageMarker.transcript_signals(session))
  def ended? = SlackOutageMarker::ENDED_STATUSES.include?(session.status.to_s)
  def channel_id = metadata[SlackOutageMarker::CHANNEL_KEY]
  def thread_ts = metadata[SlackOutageMarker::THREAD_TS_KEY].presence || metadata[SlackOutageMarker::TS_KEY]
  def metadata = session.metadata || {}
end

# Service for centralized broadcasting with robust error handling
#
# This service provides a clean interface for all broadcasting operations
# with the following features:
# - JSON serialization exclusively (no view rendering from jobs)
# - Retry logic for transient failures
# - Circuit breaker pattern for repeated failures
# - Never lets broadcast failures affect job execution
#
# Usage:
#   service = BroadcastService.new
#   service.timeline_message(session, message_data)
#   service.timeline_log(session, log)
#   service.running_loader(session)
#   service.remove_running_loader(session)
#   service.notification_badge(pending_count)
class BroadcastService
  # Circuit breaker settings
  CIRCUIT_BREAKER_THRESHOLD = 5
  CIRCUIT_BREAKER_RESET_TIME = 60 # seconds

  # Retry settings
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.1 # seconds

  # Thread-safe circuit breaker state using Mutex
  @circuit_breaker_mutex = Mutex.new
  @circuit_breaker_failures = 0
  @circuit_breaker_opened_at = nil

  class << self
    attr_reader :circuit_breaker_mutex

    def circuit_breaker_failures
      @circuit_breaker_failures
    end

    def circuit_breaker_failures=(value)
      @circuit_breaker_failures = value
    end

    def circuit_breaker_opened_at
      @circuit_breaker_opened_at
    end

    def circuit_breaker_opened_at=(value)
      @circuit_breaker_opened_at = value
    end
  end

  def initialize(turbo_channel: Turbo::StreamsChannel)
    @turbo_channel = turbo_channel
    @logger = StructuredLogger.new({ service: "BroadcastService" })
  end

  # Broadcast a timeline message (from transcript)
  # @param session [Session] The session to broadcast to
  # @param message [Hash] The raw message from transcript (or MCP log)
  def timeline_message(session, message)
    # Handle MCP log messages specially
    if message["type"] == "mcp_log"
      timeline_mcp_log(session, message)
      return
    end

    # Normalize the raw transcript event into OpenTranscripts events via the
    # session's runtime normalizer. One source line can fan out into several
    # events (e.g. an assistant line -> AssistantMessage + ToolCall), each
    # appended as its own timeline item. transcript_index is omitted for live
    # broadcasts (it only applies to page-load rendering / fork-from-here).
    events = TranscriptRuntime.normalizer_for(session).normalize(message, session: session)

    # Drop content-less message events (e.g. a Claude assistant line carrying
    # only tool_use/thinking blocks). They are retained in the normalized stream
    # for usage metrics and child parent-linkage, but must not stream a bare row
    # — matching the renderer and the controller's filter/count predicate.
    events = events.reject { |event| OpenTranscript.blank_message?(event) } if events.present?

    # normalize returns an empty array for events the runtime does not surface
    # (e.g. Codex event_msg/turn_context bookkeeping lines).
    return if events.blank?

    # Broadcast each fanned-out event; return true only when every append
    # succeeded so callers (and the retry/circuit-breaker tests) keep a boolean
    # success contract.
    results = events.map do |event|
      broadcast_with_retry(
        method: :broadcast_append_to,
        stream: "session_#{session.id}_timeline",
        target: "session_#{session.id}_timeline",
        partial: "timeline_items/item",
        locals: { item: event, session: session }
      )
    end
    results.all?
  end

  # Broadcast an MCP server log entry to the timeline
  # @param session [Session] The session to broadcast to
  # @param mcp_log [Hash] The MCP log entry with server_name, level, message, timestamp
  def timeline_mcp_log(session, mcp_log)
    timestamp = parse_timestamp(mcp_log["timestamp"])

    timeline_item = {
      type: "mcp_log",
      level: mcp_log["level"] || "info",
      server_name: mcp_log["server_name"],
      content: "[MCP:#{mcp_log['server_name']}] #{mcp_log['message']}",
      timestamp: timestamp,
      sort_time: timestamp || session.created_at
    }

    broadcast_with_retry(
      method: :broadcast_append_to,
      stream: "session_#{session.id}_timeline",
      target: "session_#{session.id}_timeline",
      partial: "timeline_items/item",
      locals: { item: timeline_item }
    )
  end

  # Broadcast a log entry to the timeline
  # @param session [Session] The session to broadcast to
  # @param log [Log] The log entry to broadcast
  def timeline_log(session, log)
    timeline_item = {
      type: "log",
      level: log.level,
      content: log.content,
      timestamp: log.created_at,
      sort_time: log.created_at
    }

    broadcast_with_retry(
      method: :broadcast_append_to,
      stream: "session_#{session.id}_timeline",
      target: "session_#{session.id}_timeline",
      partial: "timeline_items/item",
      locals: { item: timeline_item }
    )
  end

  # Broadcast running loader update
  # @param session [Session] The session to broadcast to
  def running_loader(session)
    broadcast_with_retry(
      method: :broadcast_replace_to,
      stream: "session_#{session.id}_timeline",
      target: "session_#{session.id}_running_loader",
      partial: "sessions/running_loader",
      locals: { agent_session: session }
    )
  end

  # Remove running loader from timeline
  # @param session [Session] The session to broadcast to
  def remove_running_loader(session)
    broadcast_with_retry(
      method: :broadcast_remove_to,
      stream: "session_#{session.id}_timeline",
      target: "session_#{session.id}_running_loader"
    )
  end

  # Remove the empty timeline message placeholder
  # Should be called before broadcasting the first timeline item
  # @param session [Session] The session to broadcast to
  def remove_empty_timeline_message(session)
    broadcast_with_retry(
      method: :broadcast_remove_to,
      stream: "session_#{session.id}_timeline",
      target: "empty-timeline-message"
    )
  end

  # Broadcast subagent accordion update (for new subagent or status changes)
  # @param session [Session] The session to broadcast to
  # @param subagent [SubagentTranscript] The subagent to broadcast
  def subagent_accordion(session, subagent)
    broadcast_with_retry(
      method: :broadcast_replace_to,
      stream: "session_#{session.id}_timeline",
      target: "subagent_accordion_#{subagent.agent_id}",
      partial: "subagent_transcripts/accordion",
      locals: { subagent: subagent, session: session }
    )
  end

  # Broadcast subagent messages update (for live streaming within accordion)
  # @param session [Session] The session to broadcast to
  # @param subagent [SubagentTranscript] The subagent to broadcast
  def subagent_messages(session, subagent)
    broadcast_with_retry(
      method: :broadcast_replace_to,
      stream: "session_#{session.id}_timeline",
      target: "subagent_#{subagent.agent_id}_messages",
      partial: "subagent_transcripts/messages",
      locals: { subagent: subagent, session: session }
    )
  end

  # Broadcast enqueued messages list update
  # Called when a message is dequeued and sent to the agent
  # @param session [Session] The session to broadcast to
  def enqueued_messages_list(session)
    broadcast_with_retry(
      method: :broadcast_replace_to,
      stream: "session_#{session.id}_enqueued_messages",
      target: "session_#{session.id}_enqueued_messages",
      partial: "enqueued_messages/enqueued_messages_list",
      locals: { agent_session: session }
    )
  end

  # Broadcast session status change immediately
  #
  # This method broadcasts status badge, follow-up form, and header actions
  # directly, without waiting for after_update_commit callbacks.
  #
  # IMPORTANT: Use this method when you need immediate UI updates, especially
  # from background jobs where the GoodJob transaction may not commit until
  # the job finishes. The normal after_update_commit callbacks on Session
  # model will only fire when the transaction commits, which can cause
  # delays in UI updates.
  #
  # @param session [Session] The session to broadcast status for
  def session_status(session)
    # Reload to ensure we have the latest status
    session.reload

    # Broadcast status badge
    broadcast_with_retry(
      method: :broadcast_replace_to,
      stream: "session_#{session.id}_status",
      target: "session_#{session.id}_status_badge",
      partial: "sessions/status_badge",
      locals: { agent_session: session }
    )

    # Broadcast follow-up form
    # Use SessionsController.render to ensure route helpers are available
    session_skills = ClaudeSkillsCacheService.get_for_session(session)
    follow_up_html = SessionsController.render(
      partial: "sessions/follow_up_form",
      locals: { agent_session: session, session_skills: session_skills }
    )
    broadcast_with_retry(
      method: :broadcast_replace_to,
      stream: "session_#{session.id}_status",
      target: "session_#{session.id}_follow_up_form",
      html: follow_up_html
    )

    # Broadcast header actions
    header_actions_html = SessionsController.render(
      partial: "sessions/session_header_actions",
      locals: { agent_session: session }
    )
    broadcast_with_retry(
      method: :broadcast_replace_to,
      stream: "session_#{session.id}_status",
      target: "session_#{session.id}_header_actions",
      html: header_actions_html
    )
  rescue => e
    @logger.error("Failed to broadcast session status", session_id: session.id, error: e.message, exception: e)
    # Don't re-raise - broadcast failures should not affect job execution
  end

  # Broadcast an optimistic user message (shown immediately before Claude processes it)
  # This provides instant feedback when user sends a follow-up prompt.
  # @param session [Session] The session to broadcast to
  # @param prompt [String] The user's prompt text
  # @param sent_at [Time] When the message was sent
  def optimistic_user_message(session, prompt, sent_at: Time.current)
    timeline_item = OpenTranscript.event(
      type: OpenTranscript::Types::USER_MESSAGE,
      id: "optimistic-#{sent_at.to_f}",
      parent_id: nil,
      ts: sent_at.iso8601,
      sort_time: sent_at,
      transcript_index: nil,
      event_order: 0,
      content: [ OpenTranscript.text_part(prompt) ]
    ).merge(optimistic: true) # Flag to indicate this is an optimistic message

    # First remove the empty timeline message if present
    remove_empty_timeline_message(session)

    broadcast_with_retry(
      method: :broadcast_append_to,
      stream: "session_#{session.id}_timeline",
      target: "session_#{session.id}_timeline",
      partial: "timeline_items/item",
      locals: { item: timeline_item, session: session }
    )
  end

  # Broadcast a new elicitation banner to the session detail page
  # @param session [Session] The session to broadcast to
  # @param elicitation [Elicitation] The elicitation to show
  def elicitation_banner(session, elicitation)
    broadcast_with_retry(
      method: :broadcast_append_to,
      stream: "session_#{session.id}_elicitations",
      target: "session_#{session.id}_elicitations",
      partial: "elicitations/elicitation_banner",
      locals: { elicitation: elicitation, session: session }
    )
  end

  # Remove an elicitation banner from the session detail page
  # @param session [Session] The session to broadcast to
  # @param elicitation [Elicitation] The elicitation to remove
  def remove_elicitation_banner(session, elicitation)
    broadcast_with_retry(
      method: :broadcast_remove_to,
      stream: "session_#{session.id}_elicitations",
      target: "elicitation_#{elicitation.id}"
    )
  end

  # Broadcast notification badge update
  # This broadcasts to a global channel so any page with the notification badge
  # will receive the update in real-time.
  # @param pending_count [Integer] The current pending notification count
  def notification_badge(pending_count)
    broadcast_with_retry(
      method: :broadcast_replace_to,
      stream: "notification_badge",
      target: "notification_badge",
      partial: "notifications/notification_badge",
      locals: { pending_count: pending_count }
    )
  end

  # Check if the circuit breaker is open (thread-safe)
  # @return [Boolean] true if circuit breaker is open
  def circuit_open?
    self.class.circuit_breaker_mutex.synchronize do
      return false unless self.class.circuit_breaker_opened_at

      if Time.current - self.class.circuit_breaker_opened_at > CIRCUIT_BREAKER_RESET_TIME
        reset_circuit_breaker_unlocked
        false
      else
        true
      end
    end
  end

  # Reset the circuit breaker (thread-safe, for testing)
  def reset_circuit_breaker
    self.class.circuit_breaker_mutex.synchronize do
      reset_circuit_breaker_unlocked
    end
  end

  private

  # Reset circuit breaker without acquiring lock (caller must hold mutex)
  def reset_circuit_breaker_unlocked
    self.class.circuit_breaker_failures = 0
    self.class.circuit_breaker_opened_at = nil
  end

  # Parse timestamp from string
  # @param timestamp_str [String, nil] The timestamp string to parse
  # @return [Time, nil] The parsed time or nil
  def parse_timestamp(timestamp_str)
    return nil unless timestamp_str.present?

    Time.parse(timestamp_str)
  rescue ArgumentError
    nil
  end

  # Broadcast with retry logic and circuit breaker
  # @param method [Symbol] The Turbo broadcast method to call
  # @param stream [String] The stream name
  # @param target [String] The target element ID
  # @param partial [String, nil] The partial to render
  # @param locals [Hash] Local variables for the partial
  # @param html [String, nil] Pre-rendered HTML content (alternative to partial)
  def broadcast_with_retry(method:, stream:, target:, partial: nil, locals: {}, html: nil)
    # Check circuit breaker first
    if circuit_open?
      @logger.warn("Circuit breaker open, skipping broadcast", stream: stream, target: target)
      return false
    end

    retries = 0
    begin
      perform_broadcast(method: method, stream: stream, target: target, partial: partial, locals: locals, html: html)
      record_success
      true
    rescue => e
      retries += 1
      if retries <= MAX_RETRIES
        delay = RETRY_BASE_DELAY * (2 ** (retries - 1))
        @logger.debug("Broadcast failed, retrying", attempt: retries, delay: delay, error: e.message)
        sleep delay
        retry
      else
        record_failure(e, stream: stream, target: target)
        false
      end
    end
  end

  # Perform the actual broadcast
  def perform_broadcast(method:, stream:, target:, partial: nil, locals: {}, html: nil)
    args = { target: target }
    if html
      # Use pre-rendered HTML content directly
      args[:html] = html
    elsif partial
      args[:partial] = partial
      args[:locals] = locals if locals.any?
    end

    @turbo_channel.public_send(method, stream, **args)
  end

  # Record a successful broadcast (thread-safe)
  def record_success
    self.class.circuit_breaker_mutex.synchronize do
      if self.class.circuit_breaker_failures > 0
        self.class.circuit_breaker_failures = [ self.class.circuit_breaker_failures - 1, 0 ].max
      end
    end
  end

  # Record a failed broadcast (thread-safe)
  def record_failure(error, stream:, target:)
    self.class.circuit_breaker_mutex.synchronize do
      self.class.circuit_breaker_failures += 1

      @logger.error(
        "Broadcast failed after retries",
        stream: stream,
        target: target,
        error: error.message,
        exception: error,
        failures: self.class.circuit_breaker_failures
      )

      # Open circuit breaker if threshold exceeded
      if self.class.circuit_breaker_failures >= CIRCUIT_BREAKER_THRESHOLD
        self.class.circuit_breaker_opened_at = Time.current
        @logger.warn("Circuit breaker opened due to repeated failures", failures: self.class.circuit_breaker_failures)
      end
    end
  end
end

# frozen_string_literal: true

module SessionEvents
  # Writes one occurrence to the log. Takes part in whatever transaction is
  # open, so an event published with a delivery commits with it or not at all.
  module Publish
    module_function

    # @param reason [String] a Sessions::MessageParent::REASONS key
    # @return [SessionEvent]
    def message(session, reason:, message:)
      text = message.to_s
      write(
        session, MESSAGE, event_id: "session:#{session.id}:message:#{SecureRandom.uuid}",
        data: {
          reason: reason,
          message: text.truncate(MESSAGE_LIMIT),
          messageTruncated: text.length > MESSAGE_LIMIT
        }
      )
    end

    # @param key [String] names this transition, so publishing it twice — a
    #   retried job — writes it once
    # @return [SessionEvent, nil] nil when it was already written
    def state_changed(session, state:, key:, occurred_at: Time.current)
      event_id = "session:#{session.id}:#{state}:#{key}"
      return nil if SessionEvent.exists?(event_id: event_id)

      SessionEvent.transaction(requires_new: true) { write(session, STATE_CHANGED, event_id: event_id, data: { state: state }, occurred_at: occurred_at) }
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def write(session, name, event_id:, data:, occurred_at: Time.current)
      event = SessionEvent.create!(
        event_id: event_id, name: name, session: session, parent_session_id: session.parent_session_id,
        agent_root: session.metadata&.dig("agent_root_key"), occurred_at: occurred_at,
        data: {
          sessionId: session.id,
          parentSessionId: session.parent_session_id,
          title: session.title.to_s,
          agentRoot: session.metadata&.dig("agent_root_key"),
          sessionUrl: "#{AppUrl.base_url.chomp('/')}/sessions/#{session.id}"
        }.merge(data)
      )
      ActiveRecord.after_all_transactions_commit { tell_live_mode(event) }
      event
    end
    private_class_method :write

    # Never at the cost of the event, or of the delivery it commits with.
    def tell_live_mode(event)
      LiveBackgroundResultJob.perform_later(event.id)
    rescue StandardError => e
      ErrorReporter.report_exception(e, context: { source: "SessionEvents::Publish", session_event_id: event.id })
    end
    private_class_method :tell_live_mode
  end
end

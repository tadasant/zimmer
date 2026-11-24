# frozen_string_literal: true

# Works out what a session event means for the Live conversations listening to
# it (LiveConversations::BackgroundResults). Enqueued for every event; finding
# that nobody is listening is the ordinary answer.
class LiveBackgroundResultJob < ApplicationJob
  queue_as :triggers

  def perform(session_event_id, settled: false)
    event = SessionEvent.find_by(id: session_event_id)
    LiveConversations::BackgroundResults.receive(event, settled: settled) if event
  end
end

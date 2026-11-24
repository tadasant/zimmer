# frozen_string_literal: true

# Publishes `session.state_changed` (SessionEvents) for a transition the session
# state machine announced.
#
# The same announcement AoEventTriggerJob gets, with the same settling: a
# `needs_input` is published only if the session is still at rest there when the
# window closes, so a turn boundary is not an event. `key` names the transition,
# which is what makes a retried job publish it once.
class SessionStateEventJob < ApplicationJob
  queue_as :triggers

  STATES_BY_EVENT = {
    "session_needs_input" => "needs_input",
    "session_failed" => "failed",
    "session_archived" => "archived"
  }.freeze

  # @param occurred_at [String] when the transition happened, ISO 8601
  def perform(event_name, session_id, key, occurred_at, settle_marker = nil)
    state = STATES_BY_EVENT.fetch(event_name)
    subject = AoEventSubject.resolve(event_name, session_id, settle_marker)
    return if subject.nil? || subject.session.status_summary_fork?

    # Under the row lock, so a session that archives now cannot have its earlier
    # needs_input published after it.
    subject.session.with_lock do
      next if subject.stale?

      SessionEvents::Publish.state_changed(subject.session, state: state, key: key, occurred_at: Time.iso8601(occurred_at))
    end
  end
end

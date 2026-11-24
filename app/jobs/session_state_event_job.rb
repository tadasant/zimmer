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

  def perform(event_name, session_id, key, settle_marker = nil)
    state = STATES_BY_EVENT.fetch(event_name)
    subject = AoEventSubject.resolve(event_name, session_id, settle_marker)
    return if subject.nil? || subject.stale? || subject.session.status_summary_fork?

    SessionEvents::Publish.state_changed(subject.session, state: state, key: key)
  end
end

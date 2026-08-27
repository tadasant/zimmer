# frozen_string_literal: true

# Re-renders the "Session hierarchy / Human messages" panel for every session in
# one lineage graph, after something changed the graph: a session was spawned, an
# uncle edge was written or removed, a human message was recorded.
#
# This is a fan-out, and it is the reason it is a job rather than a callback.
# The work is proportional to the SQUARE of the lineage: `SessionHierarchy`
# renders up to `MAX_NODES` (150) sessions, the panel is re-rendered once for each
# of them, and each of those renders builds that viewer's own hierarchy and its
# own human-message record — every one of which loads whole `Session` rows,
# `prompt` and `transcript` columns included. For a long-lived router with a wide
# tree that is thousands of row loads and a Redis publish per viewer.
#
# Run inline in `after_create_commit`, all of that sat inside the HTTP request
# that created the session. That is the create-path latency behind #577: the
# reverse proxy gave up and returned its own HTML 504 page while the session —
# already committed, since the callback runs after the commit — went on to run
# perfectly well, leaving the caller with an error it could not tell apart from a
# create that never happened. A create that only enqueues work has no business
# being near a gateway timeout, so the fan-out moved off the request and the
# create now returns as soon as the row is committed and the agent job is queued.
#
# Nothing is lost by deferring it: every consumer is a Turbo Stream repainting an
# already-open browser tab. A tab that repaints a second later is indistinguishable
# from one that repaints immediately; a caller that waits ten seconds for a 504 is
# not.
class SessionProvenanceBroadcastJob < ApplicationJob
  queue_as :default

  # A session deleted between the enqueue and the run has no panel to repaint,
  # and no reader waiting for one.
  discard_on ActiveJob::DeserializationError

  def perform(session_id)
    session = Session.find_by(id: session_id)
    return unless session

    session.broadcast_provenance_change_to_hierarchy
  end
end

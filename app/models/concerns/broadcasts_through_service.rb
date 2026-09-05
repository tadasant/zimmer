# frozen_string_literal: true

# One seam between a model's broadcast callbacks and BroadcastService.
#
# Model-side broadcasting used to call Turbo's helpers (`broadcast_replace_to`,
# `broadcast_append_to`, `broadcast_remove_to`) directly, which meant each
# method got to invent its own answer to "what happens when this fails" —
# several had no `rescue` at all, and since they sit on `after_*_commit` a
# dropped cable write became a failure of whatever happened to be saving the
# row. Going through the service instead gives every one of them the three
# properties it already offers the rest of the app: retry with backoff, the
# circuit breaker behind the "live updates paused" banner, and failure
# isolation.
#
# Including models call `broadcaster.broadcast_partial` /
# `broadcast_html` / `broadcast_removal` and do NOT rescue: the service
# swallows every failure of the broadcast itself — the render, the cable write —
# records it against the breaker, and reports it to ErrorReporter. (It still
# raises ArgumentError on a malformed call, which is a programmer error and
# should surface in tests rather than be absorbed.)
module BroadcastsThroughService
  extend ActiveSupport::Concern

  private

  def broadcaster
    # error_context keeps a failure report naming its subject. Every broadcast in
    # the app now reports from one call site inside the service, so without it a
    # report would identify the record only by whatever the stream name happens
    # to encode.
    @broadcaster ||= BroadcastService.new(error_context: { source: "#{self.class.name}##{id}" })
  end
end

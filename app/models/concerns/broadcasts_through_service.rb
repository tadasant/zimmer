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
# swallows, records to the breaker, and reports to ErrorReporter.
module BroadcastsThroughService
  extend ActiveSupport::Concern

  private

  def broadcaster
    @broadcaster ||= BroadcastService.new
  end
end

# frozen_string_literal: true

# The iOS app's report of what its Live voice calls did, batched
# (LiveConversations::Telemetry), onto the shipped log stream.
#
#   POST /api/v1/live/telemetry   {client: {...}, dropped: n, events: [{seq, name, level, at, mono_ms, call_id, conversation_id, fields}]}
#     → 202 {accepted, filtered, telemetry}
#
# Only the app's own sign-in reports here, on any grant: it is the phone saying
# what happened on the phone, not an action, so a sign-in that may not act as
# its person reports too. An API key is refused, so nothing but the app can put
# lines on the stream. `telemetry` in the answer is the level in force, which
# the app adopts at once: a level turned down on the Live settings page applies
# from the app's next batch.
class Api::V1::LiveTelemetryController < Api::BaseController
  accepts_native_app_tokens

  before_action :require_the_app
  # The app sends a batch at most every few seconds; a phone looping on this
  # route must not crowd the shipped logs.
  rate_limit to: 60, within: 1.minute, by: -> { native_app_grant&.id }, only: :create

  def create
    batch = params.to_unsafe_h.slice("client", "dropped", "events")
    result = LiveConversations::Telemetry.new.ingest(batch)
    render json: { accepted: result.accepted, filtered: result.filtered, telemetry: result.threshold }, status: :accepted
  end

  private

  def require_the_app
    return if native_app_request?

    render_api_error("Forbidden", "Only the iOS app reports call telemetry", status: :forbidden)
  end
end

# frozen_string_literal: true

# The Live settings over the REST API — what /live/settings shows and writes, for
# the iOS app. The same rules as every other writer (LiveConversations::SettingsUpdate).
#
#   GET   /api/v1/live/settings                                  the settings, each field's choices or range, the guidance, recent history
#   PATCH /api/v1/live/settings                                  change some (setting keys, guidance, append_guidance); blank or "default" resets one
#   POST  /api/v1/live/settings/reset                            every setting back to its default (not the guidance)
#   POST  /api/v1/live/settings/changes/:id/restore_guidance     the guidance as it was before that edit
#
# The read takes an API key. The writes take the iOS app's sign-in acting as its
# person, like everything that steers a live conversation: the fleet's API key
# reaches these settings through MCP (`action_live_settings`), where the change
# is recorded as an agent's.
class Api::V1::LiveSettingsController < Api::BaseController
  accepts_native_app_tokens

  HISTORY_LIMIT = 30
  ACTOR = "the iOS app"

  before_action :require_a_person_on_the_app, except: :show

  def show
    render json: payload
  end

  def update
    # Everything the client sent, unfiltered: SettingsUpdate refuses an unknown
    # key with a 422, where a permit list would drop a typo and answer 200.
    attributes = params.to_unsafe_h.except("controller", "action", "format", "live_setting")
    render_result(LiveConversations::SettingsUpdate.call(attributes, actor: actor))
  end

  def reset
    render_result(LiveConversations::SettingsUpdate.call({}, actor: actor, reset: true))
  end

  def restore_guidance
    change = LiveSettingChange.find_by(id: params[:id])
    return render_api_error("Not Found", "Settings change not found", status: :not_found) unless change
    unless change.keys.include?("guidance")
      return render_api_error("Unprocessable Entity", "That edit did not touch the guidance", status: :unprocessable_entity)
    end

    render_result(LiveConversations::SettingsUpdate.call({ "guidance" => change.before("guidance").to_s }, actor: actor))
  end

  rescue_from LiveConversations::SettingsUpdate::Invalid do |error|
    render_api_error("Unprocessable Entity", error.message, status: :unprocessable_entity)
  end

  private

  def actor = LiveConversations::SettingsUpdate::Actor.human(ACTOR)

  def payload
    LiveSetting.current.as_api_json.merge(
      history: LiveSettingChange.recent_first.limit(HISTORY_LIMIT).map(&:as_api_json)
    )
  end

  def render_result(result)
    render json: payload.merge(changed: result.changed?, summary: result.summary)
  end

  def require_a_person_on_the_app
    return if native_app_request? && native_app_grant.acts_as_human?

    message = if native_app_request?
      "This sign-in may not act as you; sign in again and allow acting as you"
    else
      "Only a person changes the Live settings over REST: it takes the iOS app's sign-in, acting as you, " \
        "or the web UI. An agent changes them with the action_live_settings MCP tool."
    end
    render_api_error("Forbidden", message, status: :forbidden)
  end
end

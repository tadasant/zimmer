# frozen_string_literal: true

# /live/settings — Live Mode's tunable settings and the Live mode guidance, with
# the edit history. Writes go through LiveConversations::SettingsUpdate, the
# same path the REST API, the MCP tools and the live model's own
# `update_live_settings` take. After a save the page asks the call dock to push
# the change into an open voice call (live_settings_saved_controller.js).
class LiveSettingsController < ApplicationController
  HISTORY_LIMIT = 30
  ACTOR = "the settings page"

  def show
    @setting = LiveSetting.current
    @changes = LiveSettingChange.recent_first.includes(:live_conversation).limit(HISTORY_LIMIT)
  end

  def update
    attributes = edited(params.fetch(:live_setting, {}).permit(*LiveSetting::KEYS, :guidance).to_h)
    result = LiveConversations::SettingsUpdate.call(attributes, actor: actor)
    saved(result)
  rescue LiveConversations::SettingsUpdate::Invalid => e
    redirect_to live_settings_path, alert: "Nothing saved. #{e.message}"
  end

  def reset
    saved(LiveConversations::SettingsUpdate.call({}, actor: actor, reset: true))
  end

  # Put the guidance back to what it was before one recorded edit.
  def restore_guidance
    change = LiveSettingChange.find(params[:id])
    return redirect_to(live_settings_path, alert: "That edit did not touch the guidance.") unless change.keys.include?("guidance")

    saved(LiveConversations::SettingsUpdate.call({ "guidance" => change.before("guidance").to_s }, actor: actor))
  rescue LiveConversations::SettingsUpdate::Invalid => e
    redirect_to live_settings_path, alert: "Nothing restored. #{e.message}"
  end

  private

  def actor = LiveConversations::SettingsUpdate::Actor.human(ACTOR)

  # Only the fields that differ from what the page was rendered with: the form
  # posts every field, and one the person did not touch must not overwrite a
  # change made elsewhere — by Live Mode itself, say — since the page loaded.
  def edited(attributes)
    loaded = params.fetch(:loaded, {}).permit(*LiveSetting::KEYS, :guidance).to_h
    attributes.reject { |key, value| loaded.key?(key) && normalize(loaded[key]) == normalize(value) }
  end

  def normalize(value) = value.to_s.gsub("\r\n", "\n").strip

  def saved(result)
    if result.changed?
      flash[:live_settings_saved] = true
      redirect_to live_settings_path, notice: "Saved. #{result.summary.lines.first.to_s.strip}#{' …' if result.summary.lines.size > 1}"
    else
      redirect_to live_settings_path, notice: "Nothing changed."
    end
  end
end

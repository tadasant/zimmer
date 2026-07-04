# frozen_string_literal: true

# Persists the global session defaults configured on the settings page — the base
# runtime + model that fill in session creation when nothing more specific applies
# (no form/API param and no explicit roots.json value).
#
# A blank runtime or model clears that part of the override, deferring to the
# hardcoded default (Claude Code / the runtime's catalog default). The runtime +
# model pair is validated by the model so an unusable combination (e.g. Claude
# Code + a GPT model) can never be saved.
class AppSettingsController < ApplicationController
  def update
    setting = AppSetting.editable
    app_params = params[:app_setting] || {}

    # Only touch attributes the submitted form actually carries. The settings
    # page renders independent forms (session defaults, experimental flags), so
    # a flag-only submit must not blank out the runtime/model and vice versa.
    if app_params.key?(:default_runtime) || app_params.key?(:default_model)
      setting.default_runtime = app_params[:default_runtime].to_s.strip.presence
      setting.default_model = app_params[:default_model].to_s.strip.presence
    end

    # AO Extension enablement toggles arrive as app_setting[extensions][<id>].
    # Handled generically off the extension id so adding or removing an extension
    # needs no controller change — the id is the enablement key in extension_states.
    # Guard the param shape (a scalar would raise on #each_pair) and persist only
    # ids of registered extensions, so a crafted or stale submit can't accumulate
    # junk keys in the extension_states map.
    if (extensions = app_params[:extensions]).respond_to?(:each_pair)
      extensions.each_pair do |id, value|
        next unless Ao::ExtensionRegistry.find(id)

        setting.set_extension_enabled(id, ActiveModel::Type::Boolean.new.cast(value))
      end
    end

    if setting.save
      redirect_to settings_path, notice: "Settings updated."
    else
      redirect_to settings_path, alert: "Settings not saved: #{setting.errors.full_messages.join(", ")}"
    end
  end
end

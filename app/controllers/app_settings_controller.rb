# frozen_string_literal: true

# Persists the settings-page fields backed by the AppSetting singleton: the global
# session defaults (the base runtime + model that fill in session creation when
# nothing more specific applies — no form/API param and no explicit roots.json
# value) and the experimental toggles listed by ExperimentalSettingsRegistry.
#
# A blank runtime or model clears that part of the override, deferring to the
# hardcoded default (Claude Code / the runtime's catalog default). The runtime +
# model pair is validated by the model so an unusable combination (e.g. Claude
# Code + a GPT model) can never be saved.
class AppSettingsController < ApplicationController
  # Named on the `[AppSettings]` audit line so a change made here is
  # distinguishable from one an agent made through `action_app_settings`.
  CHANGE_SOURCE = "web:/settings"

  def update
    setting = AppSetting.editable
    setting.policy_change_source = CHANGE_SOURCE
    app_params = params[:app_setting] || {}

    # Only touch attributes the submitted form actually carries. The settings
    # page renders independent forms (session defaults, experimental flags), so
    # a flag-only submit must not blank out the runtime/model and vice versa.
    if app_params.key?(:default_runtime) || app_params.key?(:default_model)
      setting.default_runtime = app_params[:default_runtime].to_s.strip.presence
      setting.default_model = app_params[:default_model].to_s.strip.presence
    end

    # The experimental toggles arrive on their own, from a form that carries no
    # runtime/model — hence the same key-presence guard as above. Driven off
    # ExperimentalSettingsRegistry rather than named one by one, so adding a
    # setting is one registry entry plus its migration, and a setting can never be
    # rendered as a toggle here that this action then ignores.
    ExperimentalSettingsRegistry.all.reject(&:extension?).each do |experimental|
      next unless app_params.key?(experimental.attribute)

      setting.public_send(
        :"#{experimental.attribute}=",
        ActiveModel::Type::Boolean.new.cast(app_params[experimental.attribute])
      )
    end

    # The MCP Apps pair arrives from its own form, so the same key-presence guard
    # applies. The allowlist is sanitized rather than trusted: McpApps::Policy
    # drops anything that is not a remote server in the catalog, so a stale form
    # or a crafted submit cannot name a server the rest of the feature would then
    # have to defend against. The hidden empty-string entry the form always sends
    # is what makes "everything unticked" arrive as an empty list.
    if app_params.key?(:mcp_apps_enabled)
      setting.mcp_apps_enabled = ActiveModel::Type::Boolean.new.cast(app_params[:mcp_apps_enabled])
    end

    if app_params.key?(:mcp_apps_allowed_servers)
      submitted = Array(app_params[:mcp_apps_allowed_servers]).map(&:to_s).reject(&:blank?)
      setting.mcp_apps_allowed_servers = McpApps::Policy.sanitize_allowlist(submitted)
    end

    # Zimmer Extension enablement toggles arrive as app_setting[extensions][<id>].
    # Handled generically off the extension id so adding or removing an extension
    # needs no controller change — the id is the enablement key in extension_states.
    # Guard the param shape (a scalar would raise on #each_pair) and persist only
    # ids of registered extensions, so a crafted or stale submit can't accumulate
    # junk keys in the extension_states map.
    if (extensions = app_params[:extensions]).respond_to?(:each_pair)
      extensions.each_pair do |id, value|
        next unless Zimmer::ExtensionRegistry.find(id)

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

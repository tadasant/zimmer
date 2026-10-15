# frozen_string_literal: true

# The Settings page's AppSetting row over REST: the global session defaults,
# every Settings → Experimental toggle, and the MCP Apps switch with its
# per-server allowlist. The read is what the page renders; the write is what
# AppSettingsController#update accepts from the page's forms, with the same
# key-presence guard, so a client can change one group without naming the rest.
#
# Who may write what follows the page and the MCP tools:
# - Session defaults and the experimental toggles: anyone the API trusts — an
#   API key, or the iOS app's sign-in — as `action_app_settings` already lets an
#   agent change them.
# - MCP Apps: a person. Trusting a server to put HTML on the operator's page is
#   a statement only a human makes, which is why `get_app_settings` leaves it on
#   `/settings`; here it takes the iOS app's sign-in acting as you, the same proof
#   `authorize_merge` asks for. An API key is refused.
#
# Not here: the spot gate, the backlog top-up and the genesis classes, which
# share the row but are the fleet's quota posture (`get_spot_policy`).
class Api::V1::AppSettingsController < Api::BaseController
  # Zimmer's iOS app: its Settings screen reads and writes these.
  accepts_native_app_tokens

  MCP_APPS_KEYS = %w[mcp_apps_enabled mcp_apps_allowed_servers].freeze

  before_action :require_a_person_for_mcp_apps, only: [ :update ]

  # GET /api/v1/app_settings
  def show
    render json: { app_settings: app_settings_json(AppSetting.current(context: "Api::V1::AppSettingsController#show")) }
  end

  # PATCH /api/v1/app_settings
  #
  # Request body, every key optional — only the keys present are touched:
  #   - default_runtime: a runtime id from `runtimes`; "" clears the override, null leaves it
  #   - default_model: a model id valid for that runtime; "" clears the override, null leaves it
  #   - experimental: { "<key>": true|false, ... } keyed as `experimental[].key`
  #   - mcp_apps_enabled: the master switch (a person's sign-in only)
  #   - mcp_apps_allowed_servers: [names] from `mcp_apps.eligible_servers`;
  #     anything else is dropped, as the page drops it (a person's sign-in only)
  #
  # Answers with the same shape as GET, after the save. An unusable runtime +
  # model pair, or an unknown experimental key, is a 422 and nothing changes.
  def update
    attrs = params[:app_settings].respond_to?(:to_unsafe_h) ? params[:app_settings].to_unsafe_h : {}
    setting = AppSetting.editable
    setting.policy_change_source = change_source

    # A null leaves a half alone, as action_app_settings reads it; "" clears it.
    setting.default_runtime = attrs["default_runtime"].to_s.strip.presence unless attrs["default_runtime"].nil?
    setting.default_model = attrs["default_model"].to_s.strip.presence unless attrs["default_model"].nil?

    if attrs.key?("experimental")
      experimental = attrs["experimental"]
      unless experimental.respond_to?(:each_pair)
        return render_api_error("Settings not saved", "experimental must be an object of key: boolean", status: :unprocessable_entity)
      end

      experimental.each_pair do |key, value|
        entry = ExperimentalSettingsRegistry.find(key)
        unless entry
          return render_api_error("Unknown experimental setting", "#{key} is not a setting; valid: #{ExperimentalSettingsRegistry.keys.join(', ')}",
                                  status: :unprocessable_entity)
        end

        enabled = ActiveModel::Type::Boolean.new.cast(value)
        if entry.extension?
          setting.set_extension_enabled(entry.extension.id, enabled)
        else
          setting.public_send(:"#{entry.attribute}=", enabled)
        end
      end
    end

    if attrs.key?("mcp_apps_enabled")
      setting.mcp_apps_enabled = ActiveModel::Type::Boolean.new.cast(attrs["mcp_apps_enabled"])
    end

    if attrs.key?("mcp_apps_allowed_servers")
      submitted = Array(attrs["mcp_apps_allowed_servers"]).map(&:to_s).reject(&:blank?)
      setting.mcp_apps_allowed_servers = McpApps::Policy.sanitize_allowlist(submitted)
    end

    if setting.save
      render json: { app_settings: app_settings_json(setting) }
    else
      render_api_error("Settings not saved", setting.errors.full_messages.join(", "), status: :unprocessable_entity)
    end
  end

  private

  # The MCP Apps pair is a person's to change: the app's sign-in acting as you.
  # Checked before anything is read, so the refusal names the rule and nothing else.
  def require_a_person_for_mcp_apps
    attrs = params[:app_settings]
    return unless attrs.respond_to?(:key?) && MCP_APPS_KEYS.any? { |key| attrs.key?(key) }
    return if native_app_request? && native_app_grant.acts_as_human?

    message = if native_app_request?
      "This sign-in may not act as you; sign in again and allow acting as you to change MCP Apps"
    else
      "Only a person can change MCP Apps: it takes the iOS app's sign-in, acting as you, or the web UI"
    end
    render_api_error("Forbidden", message, status: :forbidden)
  end

  # Named on the `[AppSettings]` audit line, beside the page's `web:/settings`
  # and the MCP tool's, so a change made from the phone reads as the phone's,
  # and whose phone.
  def change_source
    native_app_request? ? "ios-app:/settings (#{native_app_grant.user_email})" : "api:/app_settings"
  end

  def app_settings_json(setting)
    runtime = setting.default_runtime.presence || RuntimeRegistry::DEFAULT_RUNTIME
    model = setting.default_model.presence || ModelCatalog.default_for(runtime)

    {
      session_defaults: {
        runtime: runtime,
        model: model,
        runtime_overridden: setting.default_runtime.present?,
        model_overridden: setting.default_model.present?,
        built_in: { runtime: RuntimeRegistry::DEFAULT_RUNTIME, model: ModelCatalog.default_for(RuntimeRegistry::DEFAULT_RUNTIME) }
      },
      runtimes: RuntimeRegistry.registered_runtimes.map do |id|
        { id: id, label: RuntimeRegistry.label_for(id), default_model: ModelCatalog.default_for(id), models: ModelCatalog.model_ids_for(id) }
      end,
      # Read off the row in hand, not re-read per entry: the answer to a PATCH is
      # the row it saved.
      experimental: ExperimentalSettingsRegistry.all.map do |entry|
        {
          key: entry.key,
          title: entry.title,
          description: entry.description,
          enabled: entry.extension? ? setting.extension_enabled?(entry.extension.id, default: entry.extension.default_enabled?) : setting.public_send(:"#{entry.attribute}?"),
          default_enabled: ExperimentalSettingsRegistry.default_on?(entry),
          extension: entry.extension?
        }
      end,
      mcp_apps: {
        enabled: setting.mcp_apps_enabled?,
        allowed_servers: Array(setting.mcp_apps_allowed_servers).map(&:to_s),
        eligible_servers: McpApps::Policy.eligible_servers.map { |server| { name: server.name, title: server.title } }
      }
    }
  end
end

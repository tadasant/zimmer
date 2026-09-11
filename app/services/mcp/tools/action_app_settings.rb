# frozen_string_literal: true

module Mcp
  module Tools
    # The write half of the Settings page — what AppSettingsController does for
    # the Session Defaults and Experimental forms, reachable by an agent.
    #
    # Follows ActionSpotPolicy's dispatch shape: one `action` argument validated
    # against a constant, one private method per action. Validation is the
    # model's, as it is for the form: the tool assigns and saves, and a runtime +
    # model pair the Settings page would refuse is refused here with the same
    # message.
    class ActionAppSettings < Tool
      tool_name "action_app_settings"

      ACTIONS = %w[
        set_session_defaults
        set_experimental_setting
      ].freeze

      # Named on the audit line AppSetting writes for every settings change, so a
      # change an agent made is distinguishable from one a human made on
      # /settings. The action and the calling session are appended, the same way
      # ActionSpotPolicy does it: one API key is shared by the whole fleet, so the
      # tool alone narrows a change to "some agent".
      CHANGE_SOURCE = "mcp:action_app_settings"

      description <<~DESC
        Change Zimmer's global settings — the defaults every NEW session is created under. Read the current values first with `get_app_settings`.

        These are deployment-wide. A change here affects every session spawned after it, not just
        yours, so make one only when you were asked to.

        **Actions:**
        - **set_session_defaults**: Set the global base runtime and/or model (Settings → Session
          Defaults). A session gets these only when neither its creator nor its agent root names a
          runtime or model — and a `start_session` call with no `agent_root` skips them entirely.
          Pass `runtime`, `model`, or both; an omitted one is left alone, and an
          empty string clears that half of the override so it falls back to the shipped default
          (Claude Code, and the runtime's own default model). The pair is validated exactly as the
          Settings form validates it: a model that runtime cannot run (e.g. Claude Code + a GPT
          model) is refused and nothing is saved. Switching `runtime` while a model for the old one
          is stored is refused for that reason — pass the new `model` with it, or `model: ""`.
        - **set_experimental_setting**: Turn one Settings → Experimental toggle on or off (requires
          `setting` and `enabled`). `setting` is the key `get_app_settings` lists: `mcp_tool_search`,
          `session_scoped_credentials`, or `extension.<id>` for a registered experimental Zimmer
          Extension. An unknown key, or an extension that is not registered, is refused. Every
          session is tagged with each toggle's value as it runs, and the Costs page compares those
          cohorts — so switching a setting back and forth is how its cohorts come to interleave in
          time rather than split at one date.

        Every change is echoed back as before → after, and recorded on an `[AppSettings]` audit log
        line naming this tool, the action and the calling session.

        The spot/priority policy and backlog top-up live on the same row but are changed with
        `action_spot_policy`.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ACTIONS,
            description: "The action to perform"
          },
          runtime: {
            type: "string",
            description: "set_session_defaults: the global default runtime id (e.g. `claude_code`, `codex`). " \
                         "Empty string clears the override. `get_app_settings` lists the valid runtimes."
          },
          model: {
            type: "string",
            description: "set_session_defaults: the global default model id, valid for the runtime " \
                         "(e.g. `opus`). Empty string clears the override, falling back to the runtime's " \
                         "own default. `get_app_settings` lists each runtime's models."
          },
          setting: {
            type: "string",
            description: "set_experimental_setting: the toggle's key, as `get_app_settings` lists it " \
                         "(`mcp_tool_search`, `session_scoped_credentials`, or `extension.<id>`)."
          },
          enabled: {
            type: "boolean",
            description: "set_experimental_setting: whether the toggle is on."
          }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action)
        raise ToolError, "Unknown action: #{action}. Valid actions: #{ACTIONS.join(', ')}" unless ACTIONS.include?(action)

        case action
        when "set_session_defaults" then set_session_defaults(args)
        when "set_experimental_setting" then set_experimental_setting(args)
        end
      end

      private

      # Mirrors AppSettingsController: strip, blank → nil, and let the model's
      # validations decide. `.nil?` rather than `key?`, so an explicit null is
      # "leave it alone" (as it is in action_spot_policy) and only an empty
      # string clears.
      def set_session_defaults(args)
        if args["runtime"].nil? && args["model"].nil?
          raise ToolError, "Nothing to change: pass runtime, model, or both (an empty string clears one)"
        end

        setting = AppSetting.editable
        setting.policy_change_source = change_source("set_session_defaults")
        before = session_defaults_phrase(setting)

        setting.default_runtime = args["runtime"].to_s.strip.presence unless args["runtime"].nil?
        setting.default_model = args["model"].to_s.strip.presence unless args["model"].nil?

        unless setting.save
          raise ToolError, "Session defaults not saved: #{setting.errors.full_messages.join(', ')}. " \
                           "#{valid_models_hint(setting.default_runtime)}"
        end

        "Session defaults updated.\n\n- **Before:** #{before}\n- **After:** #{session_defaults_phrase(setting)}\n\n" \
          "Applies to sessions created from now on whose creator and agent root name no runtime or model."
      end

      # Keyed off ExperimentalSettingsRegistry — the list Settings → Experimental
      # renders and AppSettingsController writes back — so a toggle added there is
      # settable here without an edit, and one that is not there cannot be written.
      # An experimental extension's key only exists while the extension is
      # registered, which is the controller's "registered ids only" rule reached
      # from the same place.
      def set_experimental_setting(args)
        key = require_arg(args, :setting)
        experimental = ExperimentalSettingsRegistry.find(key)
        unless experimental
          raise ToolError, "Unknown experimental setting: #{key}. Valid: #{ExperimentalSettingsRegistry.keys.join(', ')}"
        end
        raise ToolError, "Missing required parameter: enabled" if args["enabled"].nil?

        enabled = ActiveModel::Type::Boolean.new.cast(args["enabled"])
        before = experimental.current_value

        setting = AppSetting.editable
        setting.policy_change_source = change_source("set_experimental_setting")
        if experimental.extension?
          setting.set_extension_enabled(experimental.extension.id, enabled)
        else
          setting.public_send(:"#{experimental.attribute}=", enabled)
        end
        raise ToolError, "Setting not saved: #{setting.errors.full_messages.join(', ')}" unless setting.save

        default = ExperimentalSettingsRegistry.default_on?(experimental)
        "#{experimental.title} (`#{experimental.key}`) is now **#{on_off(enabled)}** (was #{on_off(before)}; " \
          "shipped default #{on_off(default)}). Sessions spawned from now on run with it #{on_off(enabled)}, " \
          "and are tagged that way for the Costs page."
      end

      def session_defaults_phrase(setting)
        runtime = setting.default_runtime.presence || RuntimeRegistry::DEFAULT_RUNTIME
        model = setting.default_model.presence || ModelCatalog.default_for(runtime)
        runtime_source = setting.default_runtime.present? ? "override" : "shipped default"
        model_source = setting.default_model.present? ? "override" : "runtime default"

        "runtime `#{runtime}` (#{runtime_source}), model `#{model}` (#{model_source})"
      end

      # The one thing a caller needs to fix a refused pair: which models the
      # runtime it asked for can actually run.
      def valid_models_hint(runtime)
        runtime = runtime.presence || RuntimeRegistry::DEFAULT_RUNTIME
        unless RuntimeRegistry.registered_runtimes.include?(runtime)
          return "Valid runtimes: #{RuntimeRegistry.registered_runtimes.join(', ')}."
        end

        "Valid models for `#{runtime}`: #{ModelCatalog.model_ids_for(runtime).join(', ')}."
      end

      def change_source(action)
        [ CHANGE_SOURCE, action, ("session ##{context.self_session_id}" if context.self_session_id) ]
          .compact.join(" ")
      end

      def on_off(value)
        value ? "on" : "off"
      end
    end
  end
end

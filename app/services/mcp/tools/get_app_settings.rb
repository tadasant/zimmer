# frozen_string_literal: true

module Mcp
  module Tools
    # The read half of the Settings page: the global session defaults and every
    # Settings → Experimental toggle, as the page renders them.
    #
    # The other half of the same AppSetting row — the spot gate, the concurrency
    # limit, the backlog top-up and the genesis classes — is `get_spot_policy`'s,
    # because that half is the fleet's quota posture rather than a harness
    # default. This tool names it rather than repeating it.
    class GetAppSettings < Tool
      tool_name "get_app_settings"

      description <<~DESC
        Read Zimmer's global settings — the defaults on the Settings page that every NEW session is created under.

        Reports, for each setting, its current value and whether that is the shipped default or an
        operator override:

        - **Session defaults** — the global base runtime and model, the bottom of the fallback chain.
          Each half resolves on its own: a new session gets the global runtime when neither its
          creator (`agent_runtime`) nor its agent root (`default_runtime` in roots.json) names one,
          and the global model when neither names a model valid for the runtime it ends up on. A
          global model that is not valid for that runtime is never handed to it; the session gets
          its runtime's own default instead. Lists the valid runtimes and each runtime's models.
        - **Experimental settings** — every toggle under Settings → Experimental, by key: MCP tool
          search today, plus any registered experimental Zimmer Extension (`extension.<id>`). Each
          is also recorded on every session as it runs, which is what the Costs page compares
          cohorts by.

        Not here either: the MCP Apps master switch and its per-server allowlist, on the same page
        and the same row. Trusting a server to put HTML on an operator's page is a statement only a
        human can make, so it stays on `/settings`.

        Change them with `action_app_settings`. The session defaults apply to sessions created after
        the change. MCP tool search and experimental extensions are read when a session's agent
        process is spawned, so a turn already running keeps what it started with. Session-scoped
        credentials is the exception: the credential sync, account rotation and auth recovery read it
        live, so flipping it changes how the shared credentials file is maintained at once, for
        running sessions too.

        Not here: the spot/priority policy and backlog top-up, which live on the same row but are
        read with `get_spot_policy`.
      DESC

      input_schema({ type: "object", properties: {} })

      def call(_args)
        setting = AppSetting.current(context: "Mcp::Tools::GetAppSettings")

        [
          "## Settings",
          "",
          *session_default_lines(setting),
          "",
          *experimental_lines,
          "",
          "Change these with `action_app_settings`. The spot/priority policy on the same row is read " \
          "with `get_spot_policy`."
        ].join("\n")
      end

      private

      def session_default_lines(setting)
        runtime = setting.default_runtime.presence || RuntimeRegistry::DEFAULT_RUNTIME
        model = setting.default_model.presence || ModelCatalog.default_for(runtime)

        [
          "### Session defaults",
          "",
          "The bottom of the fallback chain, each half on its own: used when neither the session's " \
          "creator nor its agent root names a runtime (or a model valid for its runtime).",
          "",
          "- **Runtime:** `#{runtime}` (#{RuntimeRegistry.label_for(runtime)}) — " \
          "#{setting.default_runtime.present? ? "operator override" : "shipped default, no override set"}",
          "- **Model:** `#{model}` — " \
          "#{setting.default_model.present? ? "operator override" : "that runtime's own default, no override set"}",
          "- **Valid choices:**",
          *RuntimeRegistry.registered_runtimes.map do |id|
            models = ModelCatalog.model_ids_for(id).map { |m| "`#{m}`" }.join(", ")
            "  - `#{id}` (#{RuntimeRegistry.label_for(id)}): #{models} — default `#{ModelCatalog.default_for(id)}`"
          end
        ]
      end

      def experimental_lines
        lines = [ "### Experimental settings", "" ]

        ExperimentalSettingsRegistry.all.each do |experimental|
          value = experimental.current_value
          default = ExperimentalSettingsRegistry.default_on?(experimental)
          lines << "- **#{experimental.title}** (`#{experimental.key}`): **#{on_off(value)}** — " \
                   "#{value == default ? "shipped default" : "operator override; shipped default is #{on_off(default)}"}. " \
                   "#{experimental.description}"
        end

        lines
      end

      def on_off(value)
        value ? "on" : "off"
      end
    end
  end
end

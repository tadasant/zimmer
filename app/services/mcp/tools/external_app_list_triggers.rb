# frozen_string_literal: true

module Mcp
  module Tools
    # The read half of a Zimmer plugin's surface: the triggers this credential may
    # invoke. The REST sibling is `GET /api/v1/external_app/triggers`, and both
    # return ExternalApps::Presenter.triggers_json.
    class ExternalAppListTriggers < ExternalAppTool
      tool_name "list_triggers"

      description <<~DESC
        List the Zimmer triggers this credential may invoke — its Zimmer plugin's allowlist.

        Returns JSON: `external_app` (this plugin's id, name, description) and `triggers`, each with
        its `id`, `name`, the template `variables` its prompt uses (pass them to invoke_trigger's
        `variables`), and `max_sessions_per_minute` — the trigger's burst cap, or null for none. A
        batch of invokes larger than the cap within one minute gets a burst notice instead of the
        extra sessions.
      DESC

      input_schema({ type: "object", properties: {} })

      def call(_args)
        ExternalApps::Presenter.triggers_json(external_app)
      end
    end
  end
end

# frozen_string_literal: true

module Mcp
  module Tools
    # The one write a Zimmer plugin has: fire one of its allowlisted triggers now,
    # with template variables. The REST sibling is
    # `POST /api/v1/external_app/triggers/:id/invoke`; both go through
    # ExternalApps::InvokeTrigger and return ExternalApps::Presenter.invocation_json.
    class ExternalAppInvokeTrigger < ExternalAppTool
      tool_name "invoke_trigger"

      description <<~DESC
        Invoke one of this credential's allowlisted Zimmer triggers now, with template variables. Each
        successful invoke starts (or, for a trigger that reuses a session, follows up) one Zimmer
        session. To act on several items, call this once per item.

        Returns JSON: `outcome`, `fired`, `message`, `trigger` ({id, name}) and `session`
        ({id, status, url}, or null). `outcome` is one of:
        - `fired` — the session was created; `session` is it.
        - `burst_notice` — the trigger exceeded its per-minute cap; `session` is the one burst-notice
          session it spawned instead, and the requested session was NOT created.
        - `burst_suppressed` — the trigger is inside a burst (up to 5 minutes after it last exceeded
          its cap); nothing was created. Retry later.
        - `pending_session` — the trigger skips a fire while a session it spawned is still pending;
          `session` is that one.
        - `not_reusable` — a one-time reuse trigger whose target session is gone; nothing fired.
        - `not_found` — no trigger with that id is on this credential's allowlist.
        - `invalid_variables` — an unknown variable name, or a value over 10,000 characters.
        - `not_invokable` — the trigger runs a workflow, so it takes no variables.
        Anything other than `fired` is returned as a tool error, with the same JSON.
      DESC

      input_schema(
        type: "object",
        properties: {
          trigger_id: { type: "integer", description: "The trigger to invoke. One of the ids list_triggers returns." },
          variables: {
            type: "object",
            description: "Values for the trigger's prompt-template placeholders. Known names: " \
                         "#{Trigger::USER_INPUT_VARIABLES.join(', ')}. `labels` may be an array; every other " \
                         "value is a string. A placeholder the template uses but this omits renders empty. " \
                         "An unknown name is an error.",
            additionalProperties: true
          }
        },
        required: [ "trigger_id" ]
      )

      def call(args)
        result = ExternalApps::InvokeTrigger.call(
          external_app: external_app,
          trigger_id: require_arg(args, "trigger_id"),
          variables: args["variables"]
        )
        payload = ExternalApps::Presenter.invocation_json(result, base_url: context.base_url)
        raise ToolError, JSON.pretty_generate(payload) unless result.fired?

        payload
      rescue AgentRootsConfig::AgentRootNotFoundError => e
        raise ToolError, JSON.pretty_generate(outcome: "error", fired: false,
                                              message: "The trigger's agent root cannot be resolved: #{e.message}",
                                              trigger: nil, session: nil)
      end
    end
  end
end

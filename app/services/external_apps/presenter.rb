# frozen_string_literal: true

module ExternalApps
  # The JSON a Zimmer plugin reads back, identical on both surfaces: the MCP tools
  # on `POST /mcp/external_app` return exactly these hashes, and the REST
  # controller renders them as its bodies. One shape is one contract.
  #
  # Deliberately thin. A plugin sees the trigger's id, name, the template
  # variables it uses and its burst cap — enough to build a button and to size a
  # batch — and never the prompt template, the agent root or the equipment. For a
  # session it gets the id, status and URL: enough to link to it, nothing a
  # transcript read would give.
  module Presenter
    module_function

    def external_app_json(external_app)
      {
        id: external_app.id,
        name: external_app.name,
        description: external_app.description.to_s
      }
    end

    def trigger_json(trigger)
      {
        id: trigger.id,
        name: trigger.name,
        variables: trigger.prompt_variables,
        max_sessions_per_minute: trigger.max_sessions_per_minute
      }
    end

    def triggers_json(external_app)
      {
        external_app: external_app_json(external_app),
        triggers: external_app.triggers.where(workflow_id: nil).order(Arel.sql("lower(triggers.name)")).map { |t| trigger_json(t) }
      }
    end

    # @param result [ExternalApps::InvokeTrigger::Result]
    # @param base_url [String] this instance's externally reachable URL
    def invocation_json(result, base_url:)
      {
        outcome: result.outcome.to_s,
        fired: result.fired?,
        message: result.message,
        trigger: result.trigger && { id: result.trigger.id, name: result.trigger.name },
        session: result.session && session_json(result.session, base_url: base_url)
      }
    end

    def session_json(session, base_url:)
      {
        id: session.id,
        status: session.status,
        url: "#{base_url.to_s.chomp('/')}/sessions/#{session.id}"
      }
    end
  end
end

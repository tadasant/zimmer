# frozen_string_literal: true

module ExternalApps
  # A Zimmer plugin invoking one of its allowlisted triggers — the whole of what a
  # plugin credential can do, behind both `invoke_trigger` on `POST /mcp/external_app`
  # and `POST /api/v1/external_app/triggers/:id/invoke`.
  #
  # The fire itself is Triggers::ManualFire, the service behind the Invoke button
  # and `action_trigger`'s `invoke`, so the burst cap, `skip_if_pending_session`,
  # session reuse and the fire counter behave exactly as they do there. The genesis
  # is `api`, and the session the fire creates carries the plugin's id and name in
  # its metadata (ExternalApp#session_metadata).
  #
  # What this class adds is the refusals. A trigger the app is not allowed to
  # invoke is reported exactly as a trigger that does not exist, so a key cannot
  # be used to discover what else is on the deployment. Variables are checked
  # strictly: an unknown name or an oversized value is an error, not a silent drop,
  # because this is a machine contract and a typo should say so.
  class InvokeTrigger
    # Per-variable cap. The vetting use case sends a listing key; this is room for
    # a paragraph of context and not for a leaked key to stuff prompts with.
    MAX_VARIABLE_CHARS = 10_000

    # Outcomes. The first five are Triggers::ManualFire's; the rest never fire.
    #
    #   :fired             a session was created (or a reuse trigger's followed up)
    #   :burst_notice      the trigger blew its per-minute cap; `session` is the
    #                      burst-notice session, not the one asked for
    #   :burst_suppressed  the trigger is inside a burst; nothing was created
    #   :pending_session   `skip_if_pending_session` held the fire; `session` is
    #                      the pending one
    #   :not_reusable      a one-time reuse trigger whose target is gone
    #   :not_found         no such trigger on this app's allowlist
    #   :invalid_variables a variable name it does not know, or a value too long
    #   :not_invokable     the trigger now runs a workflow, which has no template
    Result = Data.define(:outcome, :message, :trigger, :session) do
      def fired? = outcome == :fired
    end

    def self.call(external_app:, trigger_id:, variables: {})
      new(external_app: external_app, trigger_id: trigger_id, variables: variables).call
    end

    def initialize(external_app:, trigger_id:, variables: {})
      @external_app = external_app
      @trigger_id = trigger_id
      @variables = variables
    end

    def call
      trigger = allowlisted_trigger
      if trigger.nil?
        log(:warn, "refused: trigger #{@trigger_id.to_s.truncate(40).inspect} is not on its allowlist")
        return refusal(:not_found, "No trigger with id #{@trigger_id.to_s.truncate(40)} is invokable with this credential. " \
                                   "List the ones that are with list_triggers (GET /api/v1/external_app/triggers).")
      end

      if trigger.workflow_backed?
        log(:warn, "refused: trigger #{trigger.id} runs a workflow")
        return refusal(:not_invokable, "Trigger #{trigger.id} (#{trigger.name}) runs a workflow and cannot be invoked with variables.", trigger)
      end

      variables, problem = checked_variables
      return refusal(:invalid_variables, problem, trigger) if problem

      fire = Triggers::ManualFire.call(
        trigger: trigger,
        genesis: SessionGenesis::API,
        variables: variables,
        session_metadata: @external_app.session_metadata
      )
      @external_app.record_invocation!

      log(fire.fired? ? :info : :warn, "invoked trigger #{trigger.id} (#{trigger.name.inspect}): #{fire.outcome}" \
                                       "#{" → session #{fire.session.id}" if fire.session}")
      Result.new(outcome: fire.outcome, message: fire.message, trigger: trigger, session: fire.session)
    end

    private

    # Enabled-ness is checked by the surfaces before they get here, but the
    # allowlist is the boundary, so it is re-checked in the query itself.
    def allowlisted_trigger
      id = @trigger_id.to_s.strip
      return nil unless id.match?(/\A\d{1,18}\z/) && @external_app.enabled?

      @external_app.triggers.find_by(id: id.to_i)
    end

    # @return [Array(Hash, String|nil)] the variables, or an error message
    def checked_variables
      raw = @variables
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      return [ {}, nil ] if raw.nil? || raw == ""
      return [ nil, "variables must be an object" ] unless raw.is_a?(Hash)

      raw = raw.stringify_keys
      unknown = raw.keys - Trigger::USER_INPUT_VARIABLES
      if unknown.any?
        return [ nil, "Unknown variable(s): #{unknown.map { |k| k.truncate(40) }.join(', ')}. " \
                      "Known: #{Trigger::USER_INPUT_VARIABLES.join(', ')}." ]
      end

      checked = {}
      raw.each do |name, value|
        value = Array(value).map(&:to_s) if name == "labels"
        value = value.to_s unless name == "labels"
        if Array(value).sum(&:length) > MAX_VARIABLE_CHARS
          return [ nil, "Variable #{name} is longer than #{MAX_VARIABLE_CHARS} characters." ]
        end

        checked[name] = value
      end
      [ checked, nil ]
    end

    def refusal(outcome, message, trigger = nil)
      Result.new(outcome: outcome, message: message, trigger: trigger, session: nil)
    end

    # WARN ships to obs: a refusal is a plugin misconfigured or a key being tried
    # against something it does not reach. `inspect` quotes the name.
    def log(level, line)
      Rails.logger.public_send(level, "[external_app] #{@external_app.name.inspect} (external_app_id=#{@external_app.id}) #{line}")
    end
  end
end

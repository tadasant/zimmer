# frozen_string_literal: true

module Triggers
  # Firing a trigger by hand, from all three surfaces: the Invoke button on the
  # trigger page, `POST /api/v1/triggers/:id/invoke`, and `action_trigger`'s
  # `invoke` action.
  #
  # A manual fire is the trigger's own fire path — Trigger#create_session! —
  # with the prompt interpolated from variables the caller supplied instead of
  # from a condition that matched. So it reuses the session, honours the burst
  # cap, heals stale catalog references and increments the fire counter exactly
  # as a poller-driven fire does. Nothing here reimplements any of that.
  #
  # What this class adds is the part all three surfaces were about to duplicate:
  # restricting the variables to the ones the template can name, and turning the
  # five possible outcomes of a fire into something each surface can render.
  # #create_session! reports them as a session-or-nil plus a flag on the trigger,
  # which reads as "nothing came back, ask the trigger why"; `outcome` names them.
  #
  # `genesis` is deliberately a required argument. It is where the work came
  # from, and only the caller knows: `web_ui` for the button a human clicked,
  # `api` for the REST and MCP paths, where the fire is an agent's.
  class ManualFire
    # The five ways a manual fire can land:
    #
    #   :fired            — a session was created (or an existing one followed up)
    #   :burst_notice     — the trigger blew its cap; `session` is the burst-notice
    #                       session it spawned instead of the one asked for
    #   :burst_suppressed — the trigger is inside a burst it has already noticed,
    #                       so nothing at all was created
    #   :pending_session  — the trigger has `skip_if_pending_session` on and a
    #                       session it already spawned is still pending; `session`
    #                       is that pending session, and nothing was created
    #   :not_reusable     — a one-time reuse trigger whose target session is gone
    #                       or is no longer reusable. `session` is that target
    #                       when the row still exists, and nil when it does not;
    #                       either way nothing was fired
    Result = Data.define(:trigger, :session, :outcome, :message) do
      def fired?
        outcome == :fired
      end

      # Whether a session came back at all. Not the same as "a fire happened":
      # :burst_notice and :not_reusable can both carry one.
      def session?
        !session.nil?
      end
    end

    def self.call(trigger:, genesis:, variables: {})
      new(trigger: trigger, genesis: genesis, variables: variables).call
    end

    def initialize(trigger:, genesis:, variables: {})
      @trigger = trigger
      @genesis = genesis
      @variables = variables
    end

    def call
      prompt = @trigger.interpolate_prompt(**permitted_variables)
      fired_at_before = @trigger.last_triggered_at
      session = @trigger.create_session!(prompt: prompt, genesis: @genesis)

      if session.nil?
        return result(nil, :burst_suppressed) if @trigger.last_fire_burst_suppressed?
        # Hand back the session that already covers the work, so the surface can
        # link it rather than reporting a bare "nothing happened".
        return result(@trigger.last_fire_pending_session, :pending_session) if @trigger.last_fire_skipped_for_pending_session?

        return result(nil, :not_reusable)
      end

      return result(session, :burst_notice) if session.metadata["burst_notice"]

      # A one-time reuse trigger whose target session still exists but is no
      # longer reusable gets that stale session handed straight back, unfired
      # (Trigger#create_session!). A session came back, so nil is not the tell —
      # `last_triggered_at` is: every path that actually fires advances it, and
      # this one deliberately does not.
      return result(session, :not_reusable) if @trigger.last_triggered_at == fired_at_before

      result(session, :fired)
    end

    private

    # Only what the template can actually name. Anything else would reach
    # Trigger#interpolate_prompt as an unknown keyword; the web form's
    # `params.permit` had the same job.
    def permitted_variables
      allowed = Trigger::USER_INPUT_VARIABLES.map(&:to_sym)
      @variables.to_h.symbolize_keys.slice(*allowed)
    end

    def result(session, outcome)
      Result.new(trigger: @trigger, session: session, outcome: outcome, message: message_for(outcome))
    end

    def message_for(outcome)
      case outcome
      when :fired
        "Trigger \"#{@trigger.name}\" fired manually. Session created."
      when :burst_notice
        "Trigger \"#{@trigger.name}\" exceeded its cap of #{@trigger.max_sessions_per_minute} " \
        "session(s) per minute. This is the burst-notice session it spawned instead — the " \
        "session you asked for was not created."
      when :burst_suppressed
        "Trigger \"#{@trigger.name}\" is in a burst: it exceeded its cap of " \
        "#{@trigger.max_sessions_per_minute} session(s) per minute, so no session was created. " \
        "See the burst-notice session it already spawned."
      when :pending_session
        pending = @trigger.last_fire_pending_session
        "Trigger \"#{@trigger.name}\" created no session — it skips a fire while a session it already " \
        "spawned is still pending, and session ##{pending&.id} (#{pending&.status}) already carries this intent."
      when :not_reusable
        "Trigger \"#{@trigger.name}\" fired but created no session — its target session is no longer reusable."
      end
    end
  end
end

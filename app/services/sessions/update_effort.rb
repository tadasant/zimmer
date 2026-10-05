# frozen_string_literal: true

module Sessions
  # Sets or clears a session's reasoning-effort level, `config["effort"]`.
  #
  # Every surface that changes it routes through here: the web UI's effort editor
  # (`PATCH /sessions/:id/update_effort`), `PATCH /api/v1/sessions/:id/effort`,
  # and the `change_effort` MCP action. The level reaches the agent as Claude
  # Code's `--effort` flag from the next turn on; the running process keeps the
  # level it was started with.
  #
  # The rules:
  # - A level is stripped and downcased, then must be one the session's model
  #   takes (ModelCatalog#effort_levels_for). Anything else is refused with the
  #   valid levels in the message.
  # - nil, "" or "default" clears the key, so the CLI applies the model's own
  #   default again.
  # - The level the session already has is a no-op: no write, no log.
  # - A value that is not a String (or nil) is refused rather than coerced.
  class UpdateEffort
    class Error < StandardError; end

    ACTOR_LABELS = { web: "", api: " via API", mcp: " via MCP" }.freeze

    # @param session [Session]
    # @param effort [String, nil]
    # @param actor [Symbol] :web, :api or :mcp — named in the log row
    # @return [Session]
    # @raise [Error] on an unsupported level or a non-String value
    def self.call(session:, effort:, actor: :web)
      new(session: session, effort: effort, actor: actor).call
    end

    def initialize(session:, effort:, actor:)
      @session = session
      @effort = effort
      @actor = actor
    end

    attr_reader :session, :effort, :actor

    def call
      raise Error, "effort must be a string" unless effort.nil? || effort.is_a?(String)

      level = effort.to_s.strip.downcase
      level = nil if Session::EFFORT_CLEAR_VALUES.include?(level)

      if level
        message = ModelCatalog.effort_error(session.agent_runtime, session.config&.dig("model"), level)
        raise Error, message if message
      end

      old_level = session.effort_override
      return session if old_level == level

      config = session.config || {}
      session.update!(config: level ? config.merge("effort" => level) : config.except("effort"))
      session.logs.create!(
        content: "Effort updated#{ACTOR_LABELS.fetch(actor, '')} (#{old_level || 'default'} → #{level || 'default'})",
        level: "info"
      )
      session
    end
  end
end

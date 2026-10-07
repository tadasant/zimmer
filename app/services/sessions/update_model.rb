# frozen_string_literal: true

module Sessions
  # Changes a session's model, `config["model"]`.
  #
  # Every surface that changes it routes through here: the web UI's model editor
  # (`PATCH /sessions/:id/update_model`), `PATCH /api/v1/sessions/:id/model`, and
  # the `change_model` MCP action. The model reaches the agent from the next turn
  # on; the running process keeps the model it was started with.
  #
  # The rules:
  # - The model must be a non-empty String. It is stripped and capped at 100
  #   characters.
  # - It must be one the session's runtime offers (ModelCatalog.valid_model?).
  #   Anything else is refused with the valid models in the message.
  # - The model the session already has is a no-op: no write, no log.
  # - The Session's own validation still applies, so a model that cannot keep the
  #   session's effort raises ActiveRecord::RecordInvalid and writes nothing.
  #
  # It touches only `config["model"]` (every other config key is kept) and one
  # log row, written together in one transaction. It does not restart the
  # session or touch its effort.
  class UpdateModel
    class Error < StandardError; end
    # The value is missing or is not a non-empty String.
    class InvalidParameter < Error; end
    # The value is not a model the session's runtime offers.
    class InvalidModel < Error; end

    MAX_LENGTH = 100
    ACTOR_LABELS = { web: "", api: " via API", mcp: " via MCP" }.freeze

    # @param session [Session]
    # @param model [String]
    # @param actor [Symbol] :web, :api or :mcp — named in the log row
    # @return [Session]
    # @raise [InvalidParameter] when the model is not a non-empty String
    # @raise [InvalidModel] when the runtime does not offer the model
    # @raise [ActiveRecord::RecordInvalid] when the session refuses the change
    def self.call(session:, model:, actor: :web)
      new(session: session, model: model, actor: actor).call
    end

    def initialize(session:, model:, actor:)
      @session = session
      @model = model
      @actor = actor
    end

    attr_reader :session, :model, :actor

    def call
      raise InvalidParameter, "model must be a non-empty string" unless model.is_a?(String) && model.present?

      new_model = model.strip.first(MAX_LENGTH)

      unless ModelCatalog.valid_model?(session.agent_runtime, new_model)
        allowed = ModelCatalog.model_ids_for(session.agent_runtime)
        raise InvalidModel, "model #{new_model.inspect} is not valid for runtime #{session.agent_runtime}. Valid models: #{allowed.join(', ')}"
      end

      # Compared against the stored value, not the in-memory one: a write that
      # failed and is being retried (the web door's with_db_retry) leaves the new
      # model on the object, and that retry must still write it.
      old_model = session.attribute_in_database("config")&.dig("model")
      return session if old_model == new_model

      session.transaction do
        session.update!(config: (session.config || {}).merge("model" => new_model))
        session.logs.create!(
          content: "Model updated#{ACTOR_LABELS.fetch(actor, '')} (#{old_model} → #{new_model})",
          level: "info"
        )
      end
      session
    end
  end
end

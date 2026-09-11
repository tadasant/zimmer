# frozen_string_literal: true

module Workflow
  # What a workflow's #plan returns: the two outputs a run starts from, kept apart
  # because they are trusted differently.
  #
  #   * `resolved` — the trusted identifiers for this run: a reply channel id, the
  #     acting principal, a target repo. Recorded on the run's WorkflowRun row,
  #     which nothing downstream can rewrite. The model may be shown them; it may
  #     never assert them.
  #   * `instructions` — the seed prompt. The model is free to interpret it, which
  #     is exactly why nothing that has to be trustworthy lives in it.
  class Plan < Data.define(:resolved, :instructions)
    class InvalidPlanError < ArgumentError; end

    def initialize(resolved:, instructions:)
      raise InvalidPlanError, "resolved must be a Hash, not #{resolved.class}" unless resolved.is_a?(Hash)

      # What a run is bound to has to be exactly what #plan returned, so the values
      # must already be JSON: a Symbol or a Time would come back out of the jsonb
      # column as something else.
      stringified = resolved.deep_stringify_keys
      unless stringified.as_json == stringified
        raise InvalidPlanError, "resolved must hold only JSON values (strings, numbers, booleans, nil, arrays, objects)"
      end
      raise InvalidPlanError, "instructions must be a non-blank String" unless instructions.is_a?(String) && instructions.present?

      super(resolved: stringified, instructions: instructions)
    end
  end
end

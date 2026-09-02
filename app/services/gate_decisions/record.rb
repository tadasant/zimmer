# frozen_string_literal: true

module GateDecisions
  # The ONE way a GateDecision row is created.
  #
  # Every surface funnels through here — the MCP tool, the REST create action and
  # the ledger importer — so the three cannot disagree about what a decision is,
  # and so the two properties that make this ledger worth trusting are stated
  # once rather than three times:
  #
  #   * `human_feedback` never survives a write. Entry strips it; nothing here
  #     puts it back. The only writer of GateDecisionFeedback is a human boundary
  #     (and the importer, on its own honestly-labelled channel).
  #   * `writing_session` is passed in by the CALLER'S BOUNDARY, resolved from the
  #     MCP connection or the API request, and is never read out of the entry. A
  #     row that could name its own author is a row an agent can launder a
  #     decision through.
  class Record
    class InvalidEntry < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors)
        super(@errors.join("; "))
      end
    end

    Result = Struct.new(:decision, :created, keyword_init: true) do
      def created? = created
    end

    class << self
      # @param gate [String] "pr_merge" / "issue_work" (aliases normalized)
      # @param surface [String] the agent root or repo the gate rated on
      # @param entry [Hash] the decision, in whatever shape the gate writes
      # @param recorded_via [String] GateDecision::MCP / API / IMPORT
      # @param writing_session [Session, nil] resolved at the boundary, not from `entry`
      # @param source_key [String, nil] importer idempotency key; nil for live writes
      # @return [Result]
      def call(gate:, surface:, entry:, recorded_via:, writing_session: nil, source_key: nil)
        normalized_gate = GateDecision.normalize_gate(gate)
        unless normalized_gate
          raise InvalidEntry, "gate must be one of #{GateDecision::GATES.join(', ')} (got #{gate.inspect})"
        end

        normalized_surface = GateDecision.normalize_surface(surface)
        raise InvalidEntry, "surface is required" if normalized_surface.blank?
        raise InvalidEntry, "entry must be a JSON object" unless entry.is_a?(Hash)

        parsed = Entry.new(gate: normalized_gate, surface: normalized_surface, raw: entry)

        decision = GateDecision.new(
          **parsed.attributes,
          recorded_via: recorded_via,
          writing_session: writing_session,
          source_key: source_key
        )
        decision.save!

        Result.new(decision: decision, created: true)
      rescue ActiveRecord::RecordNotUnique
        # Only reachable with a source_key, and only from the importer running
        # concurrently with itself. The row the other pass wrote is the answer.
        existing = GateDecision.find_by!(source_key: source_key)
        Result.new(decision: existing, created: false)
      end
    end
  end
end

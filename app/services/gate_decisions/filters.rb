# frozen_string_literal: true

module GateDecisions
  # The filter set the REST index and the `search_gate_decisions` MCP tool share,
  # so the two surfaces cannot answer the same question differently.
  #
  # Built from a plain string-keyed Hash — `params` from a controller, `args` from
  # a tool — and it validates rather than silently ignoring: a gate that filters on
  # `decision: "held"` when the vocabulary says `hold` should be told, not handed
  # an empty ledger it will read as "no precedent for this".
  class Filters
    class InvalidFilter < StandardError; end

    DEFAULT_LIMIT = 10
    MAX_LIMIT = 100

    attr_reader :gate, :surface, :decision, :artifact_url, :artifact_query, :from, :to, :query,
                :limit, :offset, :with_human_feedback

    def initialize(source)
      source = source.to_h.deep_stringify_keys

      @gate = normalize_gate(source["gate"])
      @surface = GateDecision.normalize_surface(source["surface"])
      @decision = source["decision"].presence&.to_s&.strip
      @artifact_url = source["artifact_url"].presence&.to_s&.strip
      # Deliberately a second key rather than a looser reading of `artifact_url`.
      # A gate asking "has THIS pull request been rated before" must keep getting
      # the exact match; the substring search is what a person browsing wants.
      @artifact_query = source["artifact_query"].presence&.to_s&.strip
      @from = parse_date(source["from"], "from")
      @to = parse_date(source["to"], "to")
      @query = source["query"].presence&.to_s
      @with_human_feedback = ActiveModel::Type::Boolean.new.cast(source["with_human_feedback"]) == true
      @limit = clamp(source["limit"], DEFAULT_LIMIT, MAX_LIMIT)
      @offset = [ source["offset"].to_i, 0 ].max
    end

    # The filtered relation, newest decision first. Deliberately does NOT apply
    # `limit`/`offset` — the REST index paginates with its own helper, and the MCP
    # tool slices with these. Applying it here would make one of the two wrong.
    def scope
      scope = GateDecision.all
      scope = scope.for_gate(gate) if gate
      scope = scope.for_surface(surface) if surface
      scope = scope.with_decision(decision) if decision
      scope = scope.for_artifact(artifact_url) if artifact_url
      scope = scope.matching_artifact_url(artifact_query) if artifact_query.present?
      scope = scope.decided_between(from, to) if from || to
      scope = scope.matching_text(query) if query.present?
      scope = scope.with_human_feedback if with_human_feedback
      scope.recent_first
    end

    def describe
      parts = []
      parts << "gate=#{gate}" if gate
      parts << "surface=#{surface}" if surface
      parts << "decision=#{decision}" if decision
      parts << "artifact_url=#{artifact_url}" if artifact_url
      parts << "artifact_url~#{artifact_query}" if artifact_query.present?
      parts << "from=#{from}" if from
      parts << "to=#{to}" if to
      parts << "query=#{query.inspect}" if query.present?
      parts << "with_human_feedback" if with_human_feedback
      parts.empty? ? "no filters" : parts.join(", ")
    end

    private

    def normalize_gate(value)
      return nil if value.blank?

      GateDecision.normalize_gate(value) ||
        raise(InvalidFilter, "Unknown gate #{value.inspect}. Valid gates: #{GateDecision::GATES.join(', ')}.")
    end

    def parse_date(value, name)
      return nil if value.blank?
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s.strip)
    rescue ArgumentError, TypeError
      raise InvalidFilter, "#{name} must be an ISO date like 2026-09-02 (got #{value.inspect})"
    end

    def clamp(value, default, max)
      requested = value.to_i
      return default if requested <= 0

      [ requested, max ].min
    end
  end
end

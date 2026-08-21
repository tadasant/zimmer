# frozen_string_literal: true

module OutcomeAnalyses
  # The filter set shared by the ledger, the stats view, and "Analyze All".
  #
  # It exists as its own object because a batch has to be able to say, months
  # later, which sessions it was created to cover: the same struct that narrows
  # the ledger is serialized onto the batch row and re-read from there.
  #
  # Every field is optional, and an unparseable value is dropped rather than
  # raising — a hand-edited query string should narrow the page or not, never
  # 500 it.
  class LedgerFilters
    ANALYZED_ANY = "any"
    ANALYZED_YES = "yes"
    ANALYZED_NO = "no"
    ANALYZED_VALUES = [ ANALYZED_ANY, ANALYZED_YES, ANALYZED_NO ].freeze

    OUTCOME_ANY = "any"

    attr_reader :from, :to, :agent_root, :agent_runtime, :model, :analyzed, :outcome

    def self.from_params(params)
      new(
        from: params[:from],
        to: params[:to],
        agent_root: params[:agent_root],
        agent_runtime: params[:agent_runtime],
        model: params[:model],
        analyzed: params[:analyzed],
        outcome: params[:outcome]
      )
    end

    def self.from_hash(hash)
      from_params((hash || {}).symbolize_keys)
    end

    def initialize(from: nil, to: nil, agent_root: nil, agent_runtime: nil, model: nil, analyzed: nil, outcome: nil)
      @from = parse_date(from)
      @to = parse_date(to)
      @agent_root = presence(agent_root)
      @agent_runtime = presence(agent_runtime)
      @agent_runtime = nil unless @agent_runtime.nil? || RuntimeRegistry.registered_runtimes.include?(@agent_runtime)
      @model = presence(model)
      @analyzed = ANALYZED_VALUES.include?(analyzed.to_s) ? analyzed.to_s : ANALYZED_ANY
      @outcome = SegmentTree::OUTCOME_KINDS.include?(outcome.to_s) ? outcome.to_s : OUTCOME_ANY
    end

    # The half-open window the date inputs mean. `to` is a date the user typed,
    # so it has to cover the whole of that day rather than midnight at its start.
    def from_time = from&.beginning_of_day
    def to_time = to&.end_of_day

    def any?
      to_h.any?
    end

    # Only the fields that are actually set, so a stored batch filter round-trips
    # without accumulating nulls.
    def to_h
      {
        "from" => from&.to_s,
        "to" => to&.to_s,
        "agent_root" => agent_root,
        "agent_runtime" => agent_runtime,
        "model" => model,
        "analyzed" => (analyzed unless analyzed == ANALYZED_ANY),
        "outcome" => (outcome unless outcome == OUTCOME_ANY)
      }.compact
    end

    def to_query_params = to_h.symbolize_keys

    # Human-readable, for the batch card and the "showing N of M" line.
    def summary
      parts = []
      parts << "#{from || '…'} → #{to || '…'}" if from || to
      parts << "root #{agent_root}" if agent_root
      parts << RuntimeRegistry.label_for(agent_runtime) if agent_runtime
      parts << "model #{model}" if model
      parts << "not yet analyzed" if analyzed == ANALYZED_NO
      parts << "already analyzed" if analyzed == ANALYZED_YES
      parts << "#{outcome} transcripts" unless outcome == OUTCOME_ANY
      parts.empty? ? "all archived sessions" : parts.join(" · ")
    end

    private

    def presence(value) = value.to_s.strip.presence

    def parse_date(value)
      return nil if value.blank?
      return value if value.is_a?(Date)
      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end

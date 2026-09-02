# frozen_string_literal: true

module GateDecisions
  # A ledger file's name, read for the two things the entries inside it do not
  # reliably carry: which gate wrote them, and which surface they rate.
  #
  #   PR_MERGE_GATE_ZIMMER_LEDGER.json          → pr_merge   / zimmer
  #   ISSUE_WORK_GATE_STRAD_PRODUCTION_LEDGER.json → issue_work / strad_production
  #
  # The issue gate also writes a `surface` key inside each entry and the PR gate
  # does not, so the filename is the only source that answers for both.
  class LedgerFile
    PATTERN = /\A(PR_MERGE_GATE|ISSUE_WORK_GATE)_(.+)_LEDGER\.json\z/

    GATE_BY_PREFIX = {
      "PR_MERGE_GATE" => GateDecision::PR_MERGE,
      "ISSUE_WORK_GATE" => GateDecision::ISSUE_WORK
    }.freeze

    attr_reader :name, :gate, :surface

    def self.parse(name)
      match = PATTERN.match(File.basename(name.to_s))
      return nil unless match

      new(name: File.basename(name.to_s), gate: GATE_BY_PREFIX.fetch(match[1]),
          surface: GateDecision.normalize_surface(match[2]))
    end

    def initialize(name:, gate:, surface:)
      @name = name
      @gate = gate
      @surface = surface
    end

    def to_s = name
  end
end

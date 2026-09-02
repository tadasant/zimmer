# frozen_string_literal: true

module GateDecisions
  # Where the historical ledger JSON is read from.
  #
  # The files live in `tadasant/tadasant-internal`, which is a DIFFERENT
  # repository from the one this app is deployed out of — there is no checkout of
  # it on the production box, and there is deliberately no shell there to make one.
  # So the default source fetches over `gh`, which every Zimmer container already
  # has a credential for, and the local-directory source exists for tests and for
  # anyone running the import against a clone they already have.
  #
  # Resolution order:
  #
  #   1. an explicit `dir:` — what the tests pass
  #   2. ENV["GATE_DECISION_LEDGER_DIR"] — an operator pointing at a checkout
  #   3. GitHub, via `gh api`
  module LedgerSource
    DIR_ENV_VAR = "GATE_DECISION_LEDGER_DIR"

    class Unavailable < StandardError; end

    def self.resolve(dir: nil)
      path = dir.presence || ENV[DIR_ENV_VAR].presence
      return Directory.new(path) if path

      Github.new
    end
  end
end

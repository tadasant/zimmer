# frozen_string_literal: true

module Supervisor
  class GateDecisionsController < Supervisor::ApplicationController
    # Every rating the PR-merge and issue-work gates have made, fleet-wide, with
    # the whole entry each one carried. Browsing them answers "how has this gate
    # been deciding" across surfaces, which the per-artifact view cannot.
    #
    # Index and show only. A GateDecision refuses update and destroy, so a rating
    # cannot be rewritten or quietly removed after the fact — that is the whole
    # reason the ledger is worth reading. A correction is a new row, recorded
    # through `record_gate_decision` or POST /api/v1/gate_decisions.
  end
end

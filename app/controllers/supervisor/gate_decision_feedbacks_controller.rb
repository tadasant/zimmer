# frozen_string_literal: true

module Supervisor
  class GateDecisionFeedbacksController < Supervisor::ApplicationController
    # Every note a human has left on a gate's rating — roughly eight across
    # ~1,500 decisions, and the highest-authority signal in the ledger.
    #
    # Index and show only, and deliberately no create. The one thing that makes a
    # feedback row worth anything is that a machine did not write it: the author
    # comes from the authenticated actor at the web-UI boundary
    # (GateDecisionFeedbacksController, outside this namespace), never from a
    # field. A form here would be a way to author one under any name.
  end
end

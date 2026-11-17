# frozen_string_literal: true

module Supervisor
  # Read-only view of operating_cost_subscriptions. Fixed, effective-dated charges, prorated daily by OperatingCosts::Ledger.
  class OperatingCostSubscriptionsController < Supervisor::ApplicationController
  end
end

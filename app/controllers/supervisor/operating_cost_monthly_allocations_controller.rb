# frozen_string_literal: true

module Supervisor
  # Read-only view of operating_cost_monthly_allocations. Each account-month split by agent root and functionality (OperatingCosts::Allocator). Derived.
  class OperatingCostMonthlyAllocationsController < Supervisor::ApplicationController
  end
end

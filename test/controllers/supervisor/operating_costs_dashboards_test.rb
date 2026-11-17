# frozen_string_literal: true

require "test_helper"

# Every operating-cost table renders on /supervisor, index and show.
class Supervisor::OperatingCostsDashboardsTest < ActionDispatch::IntegrationTest
  include OperatingCostFixtures

  MODELS = [
    OperatingCostFunctionality, OperatingCostVendor, OperatingCostAccount, OperatingCostSubscription, OperatingCostObservation,
    OperatingCostCreditSnapshot, OperatingCostDailyEntry, OperatingCostMonthlyAllocation, OperatingCostCollectionRun
  ].freeze

  test "index and show render for every table" do
    seed_operating_costs!
    OperatingCostsCollectionJob.perform_now

    MODELS.each do |model|
      get "/supervisor/#{model.table_name}"
      assert_response :success, "#{model.table_name} index"

      get "/supervisor/#{model.table_name}/#{model.first.id}"
      assert_response :success, "#{model.table_name} show"
    end
  end
end

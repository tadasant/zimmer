# frozen_string_literal: true

# One account's cost for one month, split by agent root and functionality
# (OperatingCosts::Allocator). Every breakdown on the Costs page is a group-by
# over these rows. A month is recomputed when new figures for it arrive and is
# otherwise left as computed, because some of its inputs (which sessions used a
# connector) can change after the fact.
class OperatingCostMonthlyAllocation < ApplicationRecord
  belongs_to :account, class_name: "OperatingCostAccount", inverse_of: :monthly_allocations
  belongs_to :functionality, class_name: "OperatingCostFunctionality", optional: true, inverse_of: :monthly_allocations

  validates :month, :computed_at, presence: true
  validates :allocation_method, inclusion: { in: OperatingCostAccount::ALLOCATION_RULES }

  def as_api_json
    { account: account.key, month: month.strftime("%Y-%m"), agent_root: agent_root, functionality: functionality&.key,
      amount_usd: amount_usd.to_f, share: share.to_f, allocation_method: allocation_method, basis_detail: basis_detail,
      computed_at: computed_at }
  end
end

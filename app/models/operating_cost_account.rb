# frozen_string_literal: true

# A billable thing: one seat, one droplet, one API project, one credit pool.
# Vendors with bills spanning several functionalities are split into one account
# per thing at ingest, so each is a line the operator can see and cut.
#
# - `paid_by` other than "self" marks a cost somebody else pays (CI on another
#   organisation's runner). It is shown and excluded from every all-in total.
# - `zimmer_share` (0..1) is the part of the account that is Zimmer's: a shared
#   cloud account hosting something unrelated is listed at 0.
# - `allocation_rule` says how the account's cost splits across agent roots
#   (OperatingCosts::Allocator); `allocation_config` carries the rule's inputs.
# - `derived_source` marks the account the daily job writes its own estimate to
#   (OperatingCosts::DerivedCollector), so an estimate and the real bill land on
#   the same account and the bill replaces it rather than adding to it.
class OperatingCostAccount < ApplicationRecord
  include OperatingCostKeyed

  SELF_PAYER = "self"
  ALLOCATION_RULES = %w[unallocated direct_root token_spend_share mcp_server_sessions].freeze
  DERIVED_SOURCES = %w[live_voice_metered pi_token_spend].freeze

  belongs_to :vendor, class_name: "OperatingCostVendor", inverse_of: :accounts
  belongs_to :functionality, class_name: "OperatingCostFunctionality", optional: true, inverse_of: :accounts
  has_many :subscriptions, class_name: "OperatingCostSubscription", foreign_key: :account_id, inverse_of: :account,
    dependent: :delete_all
  has_many :observations, class_name: "OperatingCostObservation", foreign_key: :account_id, inverse_of: :account,
    dependent: :delete_all
  has_many :credit_snapshots, class_name: "OperatingCostCreditSnapshot", foreign_key: :account_id, inverse_of: :account,
    dependent: :delete_all
  has_many :daily_entries, class_name: "OperatingCostDailyEntry", foreign_key: :account_id, inverse_of: :account,
    dependent: :delete_all
  has_many :monthly_allocations, class_name: "OperatingCostMonthlyAllocation", foreign_key: :account_id,
    inverse_of: :account, dependent: :delete_all

  validates :label, presence: true
  validates :paid_by, presence: true, format: { with: OperatingCostKeyed::KEY_FORMAT }
  validates :zimmer_share, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :allocation_rule, inclusion: { in: ALLOCATION_RULES }
  validates :derived_source, inclusion: { in: DERIVED_SOURCES }, allow_nil: true
  validates :derived_source, uniqueness: true, allow_nil: true
  validate :allocation_config_is_an_object

  before_validation { self.derived_source = derived_source.presence }

  scope :ordered, -> { order(:label) }
  scope :active, -> { where(active: true) }
  scope :self_paid, -> { where(paid_by: SELF_PAYER) }
  scope :externally_paid, -> { where.not(paid_by: SELF_PAYER) }

  def externally_paid? = paid_by != SELF_PAYER

  def allocation_roots = Array(allocation_config["agent_roots"]).map(&:to_s)
  def allocation_mcp_servers = Array(allocation_config["mcp_servers"]).map(&:to_s)
  def allocation_runtime = allocation_config["runtime"].presence

  def as_api_json
    { key: key, label: label, vendor: vendor.key, functionality: functionality&.key, paid_by: paid_by,
      zimmer_share: zimmer_share.to_f, allocation_rule: allocation_rule, allocation_config: allocation_config,
      derived_source: derived_source, environment: environment, external_ref: external_ref, notes: notes, active: active }
  end

  private

  def allocation_config_is_an_object
    errors.add(:allocation_config, "must be an object") unless allocation_config.is_a?(Hash)
  end
end

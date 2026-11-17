# frozen_string_literal: true

# A company Zimmer pays — or that someone else pays on its behalf. Every cost
# hangs off an account, and every account off a vendor.
class OperatingCostVendor < ApplicationRecord
  include OperatingCostKeyed

  CATEGORIES = %w[inference infrastructure data saas developer_tools other].freeze
  PRICING_MODELS = %w[subscription usage prepaid_credits plan_with_included_usage free].freeze
  # How its figures arrive: `derived` from Zimmer's own ledgers by the daily job;
  # `agent` written by the daily collection session; `billing_api` by a billing
  # MCP server that session calls; `manual` typed in by a person.
  INGEST_METHODS = %w[derived agent billing_api manual].freeze

  has_many :accounts, class_name: "OperatingCostAccount", foreign_key: :vendor_id, inverse_of: :vendor,
    dependent: :restrict_with_error

  validates :name, presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :pricing_model, inclusion: { in: PRICING_MODELS }
  validates :ingest_method, inclusion: { in: INGEST_METHODS }

  scope :ordered, -> { order(:name) }

  def as_api_json
    { key: key, name: name, category: category, pricing_model: pricing_model, ingest_method: ingest_method,
      billing_url: billing_url, notes: notes, active: active }
  end
end

# frozen_string_literal: true

# A capability the operator decides to keep or cut — "housing search", "voice",
# "the MCP gateway's infrastructure" — and the primary way the Costs page breaks
# down what running this deployment costs.
#
# Deployment data, not code: the repository ships no functionality. Rows are
# created from the Costs page, `action_operating_costs`, or the daily collection
# session. A cost whose account names no functionality, and whose agent root no
# functionality claims, is "Unattributed / shared" — a nil, never a row.
#
# `agent_roots` is how a cost allocated across roots (a subscription split by
# token share) finds its functionality: each root's share lands in the
# functionality that lists that root. `mcp_servers` is documentation for the
# collection session — which connectors' vendors belong here — and the default
# server list for a `mcp_server_sessions` allocation.
class OperatingCostFunctionality < ApplicationRecord
  include OperatingCostKeyed

  has_many :accounts, class_name: "OperatingCostAccount", foreign_key: :functionality_id, inverse_of: :functionality,
    dependent: :nullify
  has_many :monthly_allocations, class_name: "OperatingCostMonthlyAllocation", foreign_key: :functionality_id,
    inverse_of: :functionality, dependent: :nullify

  validates :name, presence: true
  validate :lists_are_string_arrays

  scope :ordered, -> { order(:position, :name) }
  scope :active, -> { where(active: true) }

  before_validation do
    self.agent_roots = Array(agent_roots).map { |r| r.to_s.strip }.reject(&:blank?).uniq
    self.mcp_servers = Array(mcp_servers).map { |r| r.to_s.strip }.reject(&:blank?).uniq
  end

  # Which functionality claims each agent root, first by position.
  def self.root_claims
    ordered.active.each_with_object({}) do |functionality, claims|
      functionality.agent_roots.each { |root| claims[root] ||= functionality.id }
    end
  end

  def as_api_json
    { key: key, name: name, description: description, agent_roots: agent_roots, mcp_servers: mcp_servers,
      position: position, active: active }
  end

  private

  def lists_are_string_arrays
    errors.add(:agent_roots, "must be a list of agent root names") unless agent_roots.is_a?(Array)
    errors.add(:mcp_servers, "must be a list of MCP server names") unless mcp_servers.is_a?(Array)
  end
end

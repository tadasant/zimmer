# frozen_string_literal: true

module OperatingCosts
  # Splits each account's month across agent roots and functionalities, into
  # OperatingCostMonthlyAllocation rows.
  #
  # The root split follows the account's `allocation_rule`:
  #
  # - `direct_root`: equally across the roots in `allocation_config["agent_roots"]`.
  # - `token_spend_share`: by each root's share of list-price token spend that
  #   month, optionally narrowed to one runtime (`allocation_config["runtime"]`).
  #   How a flat subscription is attributed to the roots that used it.
  # - `mcp_server_sessions`: by how many sessions created that month each root
  #   ran with any of `allocation_config["mcp_servers"]` attached (falling back
  #   to the account functionality's `mcp_servers`). How a connector's vendor is
  #   attributed: strad sees one Zimmer key, so per-call attribution is not
  #   possible.
  # - `unallocated`: one row with no root.
  #
  # Each root's share then lands in the functionality that claims the root, or
  # the account's own functionality when none does, or nowhere (unattributed).
  # A rule whose basis comes up empty for the month (no token spend, no session
  # used the server) falls back to one unallocated row, so money never vanishes.
  class Allocator
    # Zimmer's own ad hoc inference has no agent root; it is named here.
    INTERNAL_ROOT = "zimmer-internal"

    def self.allocate!(month:, accounts: OperatingCostAccount.all)
      new(month).allocate!(accounts)
    end

    def initialize(month)
      @month = month.to_date.beginning_of_month
      @range = @month..@month.end_of_month
    end

    # @return [Integer] allocation rows written
    def allocate!(accounts)
      claims = OperatingCostFunctionality.root_claims
      totals = OperatingCostDailyEntry.where(date: @range, account_id: accounts.map(&:id)).group(:account_id).sum(:amount_usd)
      now = Time.current

      rows = accounts.flat_map do |account|
        total = totals[account.id].to_d
        next [] if total.zero?

        shares, detail = shares_for(account)
        method = account.allocation_rule
        if shares.blank?
          shares = { nil => 1.to_d }
          method = "unallocated"
          detail = detail.merge(fallback: "no basis for #{account.allocation_rule} this month")
        end

        shares.map do |root, share|
          { account_id: account.id, month: @month, agent_root: root,
            functionality_id: (root && claims[root]) || account.functionality_id,
            amount_usd: (total * share).round(4), share: share.round(6), allocation_method: method,
            basis_detail: detail, computed_at: now, created_at: now, updated_at: now }
        end
      end

      OperatingCostMonthlyAllocation.transaction do
        OperatingCostMonthlyAllocation.where(month: @month, account_id: accounts.map(&:id)).delete_all
        OperatingCostMonthlyAllocation.insert_all!(rows) if rows.any?
      end
      rows.size
    end

    private

    def shares_for(account)
      case account.allocation_rule
      when "direct_root"
        roots = account.allocation_roots
        [ normalize(roots.index_with { 1 }), { agent_roots: roots } ]
      when "token_spend_share"
        weights = token_spend_by_root(account.allocation_runtime)
        [ normalize(weights), { runtime: account.allocation_runtime, basis_usd: weights.transform_values { |v| v.to_f.round(2) } } ]
      when "mcp_server_sessions"
        servers = account.allocation_mcp_servers.presence || account.functionality&.mcp_servers.to_a
        weights = sessions_by_root(servers)
        [ normalize(weights), { mcp_servers: servers, sessions: weights } ]
      else
        [ { nil => 1.to_d }, {} ]
      end
    end

    def normalize(weights)
      weights = weights.transform_values(&:to_d).select { |_, v| v.positive? }
      sum = weights.values.sum
      return {} if sum.zero?

      weights.transform_values { |v| v / sum }
    end

    def window
      @window ||= Time.zone.local(@month.year, @month.month, 1)...Time.zone.local(@month.year, @month.month, 1).next_month
    end

    def token_spend_by_root(runtime)
      relation = SessionTokenUsage.where(called_at: window)
      relation = relation.where(agent_runtime: runtime) if runtime
      CostRollup.new(relation, "session_token_usages.agent_root").fold { |root, _model| root.presence || INTERNAL_ROOT }
        .transform_values { |totals| totals[:cost_usd] }
    end

    def sessions_by_root(servers)
      return {} if servers.empty?

      Session.where(created_at: window)
        .where("sessions.mcp_servers ?| array[:servers]", servers: servers)
        .group(Arel.sql("COALESCE(sessions.metadata->>'agent_root_key', '#{INTERNAL_ROOT}')"))
        .count
    end
  end
end

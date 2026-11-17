# frozen_string_literal: true

require "test_helper"

class OperatingCosts::AllocatorTest < ActiveSupport::TestCase
  setup do
    @month = Date.new(2026, 3, 1)
    @vendor = OperatingCostVendor.create!(key: "modelco", name: "ModelCo")
    @shared = OperatingCostFunctionality.create!(key: "inference", name: "Inference")
    @search = OperatingCostFunctionality.create!(key: "search", name: "Search", agent_roots: [ "search-root" ])
  end

  def account(**attrs)
    OperatingCostAccount.create!({ key: "acct-#{SecureRandom.hex(3)}", label: "Acct", vendor: @vendor, functionality: @shared }.merge(attrs)).tap do |a|
      a.daily_entries.create!(date: @month + 4, amount_usd: 100, basis: "observed", confidence: "metered", source: "agent")
    end
  end

  def allocate(account) = OperatingCosts::Allocator.allocate!(month: @month, accounts: [ account ])

  def rows(account) = account.monthly_allocations.order(:agent_root).pluck(:agent_root, :amount_usd, :functionality_id)

  test "token_spend_share splits by each root's list-price spend, and a claimed root's share moves to its functionality" do
    a = account(allocation_rule: "token_spend_share")
    usage = { model: "claude-opus-5", called_at: Time.zone.local(2026, 3, 3), input_tokens: 0, output_tokens: 1_000_000 }
    SessionTokenUsage.create!(usage.merge(request_id: "r1", agent_root: "search-root"))
    3.times { |i| SessionTokenUsage.create!(usage.merge(request_id: "r#{i + 2}", agent_root: "other-root")) }

    allocate(a)

    assert_equal [ [ "other-root", 75, @shared.id ], [ "search-root", 25, @search.id ] ], rows(a)
  end

  test "mcp_server_sessions splits by the sessions that carried the server" do
    a = account(allocation_rule: "mcp_server_sessions", allocation_config: { "mcp_servers" => [ "acme-scraper" ] })
    travel_to(Time.zone.local(2026, 3, 6)) do
      2.times do
        # Written past validation: the catalog does not know an invented server.
        Session.create!(title: "t", prompt: "x", git_root: "https://github.com/test/repo.git", branch: "main")
          .update_columns(mcp_servers: [ "acme-scraper" ], metadata: { "agent_root_key" => "search-root" })
      end
    end

    allocate(a)

    assert_equal [ [ "search-root", 100, @search.id ] ], rows(a)
  end

  test "direct_root splits evenly across its roots" do
    a = account(allocation_rule: "direct_root", allocation_config: { "agent_roots" => %w[a b] })

    allocate(a)

    assert_equal [ [ "a", 50, @shared.id ], [ "b", 50, @shared.id ] ], rows(a)
  end

  test "a rule with no basis this month falls back to one unallocated row, so no money is lost" do
    a = account(allocation_rule: "token_spend_share")

    allocate(a)

    assert_equal [ [ nil, 100, @shared.id ] ], rows(a)
    assert_equal "unallocated", a.monthly_allocations.sole.allocation_method
  end

  test "re-allocating a month replaces it" do
    a = account
    2.times { allocate(a) }

    assert_equal 1, a.monthly_allocations.count
  end
end

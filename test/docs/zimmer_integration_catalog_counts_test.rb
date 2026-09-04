# frozen_string_literal: true

require "test_helper"

# docs/ is premised on staying true commit-by-commit, and a hardcoded count is the
# kind of fact that goes stale silently: nothing fails when someone adds an MCP
# entry, so the page just drifts. The "What's in it" paragraph on the AIR
# integration page claimed 14 MCP servers and 10 roots while the catalog resolved
# 18 and 12 (tadasant/zimmer#841).
#
# So assert the paragraph against a live resolve. Adding a catalog entry now fails
# here until the sentence is updated with it.
class ZimmerIntegrationCatalogCountsTest < ActiveSupport::TestCase
  PAGE = Rails.root.join("docs/src/content/docs/air/zimmer-integration.md")

  # One pattern per artifact type. Each must match exactly once inside the
  # paragraph -- a reword that drops or duplicates a count would otherwise leave
  # this test vacuously passing.
  COUNT_PATTERNS = {
    skills: /(\d+) skills/,
    mcp: /(\d+) MCP servers/,
    roots: /(\d+) roots/,
    plugins: /(\d+) plugins/,
    hooks: /(\d+) hooks?\b/,
    references: /(\d+) references/
  }.freeze

  # The paragraph the counts live in, from its bold lead-in to the blank line
  # that ends it.
  def paragraph
    match = PAGE.read[/^\*\*What's in it:\*\*.*?(?=\n\n)/m]
    assert match, "docs/air/zimmer-integration.md no longer has a \"**What's in it:**\" paragraph"
    match
  end

  # The single count `pattern` captures in the paragraph.
  def stated(pattern, description)
    found = paragraph.scan(pattern).flatten
    assert_equal 1, found.size,
                 "expected exactly one #{description} in the \"What's in it\" paragraph, found #{found.size}"
    found.first.to_i
  end

  test "the paragraph states the per-type counts a live catalog resolve produces" do
    COUNT_PATTERNS.each do |type, pattern|
      resolved = AirCatalogService.entries_for(type).size

      assert_equal resolved, stated(pattern, "#{type} count"),
                   "docs/air/zimmer-integration.md disagrees with the catalog on #{type}. Update the paragraph."
    end
  end

  test "the paragraph's split of skills by category matches the catalog" do
    by_category = AirCatalogService.entries_for(:skills).values.group_by { |entry| entry["category"] }

    assert_equal by_category.fetch("zimmer", []).size,
                 stated(/(\d+) Zimmer-specific ones/, "Zimmer-specific skill count")
    assert_equal by_category.fetch("workflow", []).size,
                 stated(/(\d+) vendored generic/, "vendored workflow skill count")
  end

  test "the paragraph's default-on claims match what the roots declare" do
    roots = AirCatalogService.entries_for(:roots)
    zimmer = roots.fetch("zimmer")
    fleet = roots.fetch("fleet-maintenance")

    assert_equal zimmer.fetch("default_skills").size,
                 stated(/turns (\d+) of those skills on by default/, "zimmer-root default skill count")

    assert_equal [ "playwright-custom" ], zimmer.fetch("default_mcp_servers"),
                 "the paragraph names playwright-custom as the zimmer root's only default MCP server"
    assert_equal [ "awaken-waiting-sessions" ], fleet.fetch("default_skills"),
                 "the paragraph names awaken-waiting-sessions as defaulting on fleet-maintenance"
    assert_equal [ "zimmer-fleet" ], fleet.fetch("default_mcp_servers"),
                 "the paragraph names zimmer-fleet as defaulting on fleet-maintenance"
  end
end

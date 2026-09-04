# frozen_string_literal: true

require "test_helper"

# The "What's in it" paragraph in docs/air/zimmer-integration.md counts the
# catalog by artifact type. A hardcoded count like that goes stale silently:
# nothing fails when someone adds an MCP entry, so the page just drifts, which
# is how it came to claim 14 MCP servers against a catalog resolving 18
# (tadasant/zimmer#841).
#
# So the paragraph is asserted against a live resolve. A catalog entry that
# lands without the sentence moving with it fails here.
class ZimmerIntegrationCatalogCountsTest < ActiveSupport::TestCase
  PAGE = Rails.root.join("docs/src/content/docs/air/zimmer-integration.md")

  # One pattern per artifact type. Each must match exactly once inside the
  # paragraph -- a reword that drops or duplicates a count would otherwise leave
  # this test vacuously passing. The optional plural keeps the failure honest if
  # a type ever falls to one entry and the prose naturally reads "1 plugin".
  COUNT_PATTERNS = {
    skills: /(\d+) skills?\b/,
    mcp: /(\d+) MCP servers?\b/,
    roots: /(\d+) roots?\b/,
    plugins: /(\d+) plugins?\b/,
    hooks: /(\d+) hooks?\b/,
    references: /(\d+) references?\b/
  }.freeze

  # The paragraph the counts live in, from its bold lead-in to the blank line
  # that ends it -- or to end of file, so a paragraph that lands last does not
  # read as a missing one.
  def paragraph
    @paragraph ||= begin
      match = PAGE.read[/^\*\*What's in it:\*\*.*?(?=\r?\n\r?\n|\z)/m]
      assert match, "docs/air/zimmer-integration.md no longer has a \"**What's in it:**\" paragraph"
      match
    end
  end

  # The single count `pattern` captures in the paragraph.
  def stated(pattern, description)
    found = paragraph.scan(pattern).flatten
    assert_equal 1, found.size,
                 "expected exactly one #{description} in the \"What's in it\" paragraph, found #{found.size}"
    found.first.to_i
  end

  test "every artifact type the catalog carries is counted in the paragraph" do
    # COUNT_PATTERNS is a hand-maintained parallel of the service's type list, so
    # a seventh artifact type would otherwise slip past the counts below entirely.
    assert_equal AirCatalogService::ARTIFACT_TYPES.sort, COUNT_PATTERNS.keys.sort,
                 "AirCatalogService gained or lost an artifact type; count it in the paragraph too"
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
    zimmer_specific = stated(/(\d+) Zimmer-specific ones/, "Zimmer-specific skill count")
    vendored = stated(/(\d+) vendored generic/, "vendored workflow skill count")

    assert_equal by_category.fetch("zimmer", []).size, zimmer_specific
    assert_equal by_category.fetch("workflow", []).size, vendored
    # The paragraph presents the split as the whole of the skills it just
    # counted, so a third category would make the sentence add up wrong while
    # both halves above still passed.
    assert_equal AirCatalogService.entries_for(:skills).size, zimmer_specific + vendored,
                 "skill categories other than zimmer/workflow exist; the paragraph's split no longer adds up"
  end

  test "the paragraph's default-on claims match what the roots declare" do
    roots = AirCatalogService.entries_for(:roots)
    zimmer = roots.fetch("zimmer")
    fleet = roots.fetch("fleet-maintenance")

    assert_equal zimmer.fetch("default_skills").size,
                 stated(/turns (\d+) of those skills on by default/, "zimmer-root default skill count")

    # Each claim is checked in both directions: the catalog declares what the
    # page says, and the page still names it. Without the second half a reword
    # could move an id to the wrong root and leave this test green.
    { "playwright-custom" => zimmer.fetch("default_mcp_servers"),
      "awaken-waiting-sessions" => fleet.fetch("default_skills"),
      "zimmer-fleet" => fleet.fetch("default_mcp_servers") }.each do |id, declared|
      assert_equal [ id ], declared, "the paragraph names #{id} as the sole entry here"
      assert_includes paragraph, "`#{id}`", "the paragraph no longer names #{id}"
    end

    # "instead" claims these two roots are the only ones with defaults at all.
    with_defaults = roots.select { |_id, root| root.values_at("default_skills", "default_mcp_servers").any?(&:present?) }
    assert_equal %w[fleet-maintenance zimmer], with_defaults.keys.sort,
                 "another root declares defaults; the paragraph accounts only for zimmer and fleet-maintenance"
  end
end

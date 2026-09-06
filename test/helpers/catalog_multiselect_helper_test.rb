require "test_helper"

# `catalog_multiselect_items` is where the `name`/`id` split lives now (zimmer#456).
# The Stimulus controller behind all four inline catalog editors knows only about
# `key`, so every artifact type reaching it through the wrong field, or losing a
# flag on the way, is a bug this helper is solely responsible for not having.
class CatalogMultiselectHelperTest < ActionView::TestCase
  test "keys skills and hooks on name, plugins on id" do
    skill = catalog_multiselect_items([ { id: "s1", name: "sync-docs", title: "Sync Docs" } ], key: :name).sole
    assert_equal "sync-docs", skill[:key]

    plugin = catalog_multiselect_items([ { id: "ci-workflow", title: "CI Workflow" } ], key: :id).sole
    assert_equal "ci-workflow", plugin[:key]
  end

  test "reads string-keyed options, which is what a JSON round trip leaves behind" do
    item = catalog_multiselect_items([ { "name" => "context7", "title" => "Context7" } ], key: :name).sole

    assert_equal "context7", item[:key]
    assert_equal "Context7", item[:title]
  end

  # An entry with no title still has to be pickable, and its key is the least
  # surprising thing to show — a blank chip would just look broken.
  test "falls back to the key when a catalog entry carries no title" do
    assert_equal "bare", catalog_multiselect_items([ { name: "bare" } ], key: :name).sole[:title]
    assert_equal "blank", catalog_multiselect_items([ { name: "blank", title: "  " } ], key: :name).sole[:title]
  end

  test "drops an option with no identity rather than emitting a keyless item" do
    options = [ { name: "real", title: "Real" }, { name: nil, title: "Nameless" }, { name: "", title: "Empty" } ]

    assert_equal [ "real" ], catalog_multiselect_items(options, key: :name).map { |i| i[:key] }
  end

  # `unavailable: false` has to survive: the MCP picker's controller test reads it
  # back off the rendered page, and `.compact` removing a false would break that
  # while leaving every other assertion green.
  test "keeps a false availability flag and its reason, drops absent ones" do
    flagged = catalog_multiselect_items(
      [ { name: "strad", title: "Strad", unavailable: true, unavailable_reason: "KEY unresolved" } ], key: :name
    ).sole
    assert_equal true, flagged[:unavailable]
    assert_equal "KEY unresolved", flagged[:unavailable_reason]

    fine = catalog_multiselect_items([ { name: "ok", title: "OK", unavailable: false } ], key: :name).sole
    assert_equal false, fine[:unavailable]
    assert_not fine.key?(:unavailable_reason)
  end

  test "handles a nil option list, which is what a page without the catalog passes" do
    assert_equal [], catalog_multiselect_items(nil, key: :name)
  end

  # Both accent tables exist so that no Tailwind class is ever built by
  # interpolation; an unknown token has to render a usable widget, not a 500.
  test "resolves every accent the views use, and falls back rather than raising" do
    %w[green indigo purple amber].each do |accent|
      assert_equal CatalogMultiselectHelper::ACCENT_CLASSES.fetch(accent),
        catalog_multiselect_accent(accent)
    end

    assert_equal CatalogMultiselectHelper::ACCENT_CLASSES.fetch("green"),
      catalog_multiselect_accent("chartreuse")
  end

  test "the inline and stacked variants get different display chip classes" do
    common = { items: [], selected: [], accent: "green", persist_url: "/x", payload_key: "catalog_skills" }

    inline = catalog_multiselect_attributes(**common, variant: :inline)
    stacked = catalog_multiselect_attributes(**common, variant: :stacked)

    assert_equal "px-1.5 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800",
      inline[:catalog_multiselect_display_chip_class_value]
    assert_includes stacked[:catalog_multiselect_display_chip_class_value], "border-green-200"
  end
end

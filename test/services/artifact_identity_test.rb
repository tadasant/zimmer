# frozen_string_literal: true

require "test_helper"

# The identity model on its own: how a qualified AIR ID reduces to the canonical
# token Zimmer stores, and how a reference written in any of the three accepted
# forms finds its way back. AirCatalogComposedCatalogTest drives the same rules
# through a real `air resolve`.
class ArtifactIdentityTest < ActiveSupport::TestCase
  QUALIFIED = ArtifactIdentity::QUALIFIED_ID_KEY

  test "parses the shape AIR emits" do
    assert ArtifactIdentity.qualified?("@local/slack")
    refute ArtifactIdentity.qualified?("slack")

    assert_equal "slack", ArtifactIdentity.short_id("@reframe-systems/agentic-engineering/slack")
    assert_equal "slack", ArtifactIdentity.short_id("slack")
    assert_equal "reframe-systems/agentic-engineering",
      ArtifactIdentity.scope_of("@reframe-systems/agentic-engineering/slack")
    assert_equal "local", ArtifactIdentity.scope_of("@local/slack")
    assert_nil ArtifactIdentity.scope_of("slack")

    assert ArtifactIdentity.local?("@local/slack")
    refute ArtifactIdentity.local?("@acme/catalog/slack")
  end

  test "an uncontested artifact keeps its bare short id as the canonical token" do
    entries = ArtifactIdentity.canonicalize(
      "@local/slack" => { "title" => "Slack" },
      "@acme/catalog/jira" => { "title" => "Jira" }
    )

    assert_equal %w[slack jira].sort, entries.keys.sort
    assert_equal "@local/slack", entries["slack"][QUALIFIED]
    assert_equal "@acme/catalog/jira", entries["jira"][QUALIFIED]
  end

  test "a contested short id leaves the local side bare and qualifies the other" do
    entries = ArtifactIdentity.canonicalize(
      "@local/slack" => { "title" => "Slack (ours)" },
      "@acme/catalog/slack" => { "title" => "Slack (acme)" }
    )

    assert_equal %w[@acme/catalog/slack slack].sort, entries.keys.sort
    assert_equal "Slack (ours)", entries["slack"]["title"]
    assert_equal "Slack (acme)", entries["@acme/catalog/slack"]["title"]

    # Both sides carry the flag, including the one whose token gives nothing
    # away — that is the side a picker most needs to label.
    assert entries["slack"][ArtifactIdentity::CONTESTED_KEY]
    assert entries["@acme/catalog/slack"][ArtifactIdentity::CONTESTED_KEY]
  end

  test "an uncontested artifact carries no contested flag" do
    entries = ArtifactIdentity.canonicalize("@local/slack" => { "title" => "Slack" })

    refute entries["slack"].key?(ArtifactIdentity::CONTESTED_KEY)
  end

  test "a collision between two non-local scopes qualifies both and leaves no bare token" do
    entries = ArtifactIdentity.canonicalize(
      "@acme/catalog/slack" => { "title" => "A" },
      "@beta/catalog/slack" => { "title" => "B" }
    )

    assert_equal %w[@acme/catalog/slack @beta/catalog/slack].sort, entries.keys.sort
    assert_nil ArtifactIdentity.resolve(entries, "slack"),
      "an ambiguous bare reference must not silently pick a side"
  end

  test "canonicalize passes through a tree that carries no qualification at all" do
    # What a CatalogSnapshot written before this change holds, and what the
    # suite's own stubs hand in.
    entries = ArtifactIdentity.canonicalize("slack" => { "title" => "Slack" })

    assert_equal({ "slack" => { "title" => "Slack" } }, entries)
    assert_equal "slack", ArtifactIdentity.resolve(entries, "slack")
    assert_equal "slack", ArtifactIdentity.qualified_id(entries, "slack")
  end

  test "canonicalize is idempotent" do
    once = ArtifactIdentity.canonicalize(
      "@local/slack" => { "title" => "Ours" },
      "@acme/catalog/slack" => { "title" => "Theirs" }
    )

    assert_equal once, ArtifactIdentity.canonicalize(once)
  end

  test "resolve accepts a token, a qualified id and an unambiguous bare id" do
    entries = ArtifactIdentity.canonicalize(
      "@local/slack" => {},
      "@acme/catalog/slack" => {},
      "@acme/catalog/jira" => {}
    )

    assert_equal "slack", ArtifactIdentity.resolve(entries, "slack")
    assert_equal "slack", ArtifactIdentity.resolve(entries, "@local/slack")
    assert_equal "@acme/catalog/slack", ArtifactIdentity.resolve(entries, "@acme/catalog/slack")
    # `jira` is contributed by one scope only, so the bare form still addresses it
    # even though its token happens to be bare too.
    assert_equal "jira", ArtifactIdentity.resolve(entries, "jira")
    assert_equal "jira", ArtifactIdentity.resolve(entries, "@acme/catalog/jira")

    assert_nil ArtifactIdentity.resolve(entries, "nope")
    assert_nil ArtifactIdentity.resolve(entries, "@acme/catalog/nope")
    assert_nil ArtifactIdentity.resolve(entries, "")
    assert_nil ArtifactIdentity.resolve(entries, nil)
  end

  test "qualified_id expands a token back to what the AIR CLI has to be handed" do
    entries = ArtifactIdentity.canonicalize(
      "@local/slack" => {},
      "@acme/catalog/slack" => {}
    )

    assert_equal "@local/slack", ArtifactIdentity.qualified_id(entries, "slack")
    assert_equal "@acme/catalog/slack", ArtifactIdentity.qualified_id(entries, "@acme/catalog/slack")
    assert_nil ArtifactIdentity.qualified_id(entries, "nope")
  end

  test "contested? is true on both sides of a collision and false everywhere else" do
    entries = ArtifactIdentity.canonicalize(
      "@local/slack" => {},
      "@acme/catalog/slack" => {},
      "@acme/catalog/jira" => {}
    )

    assert ArtifactIdentity.contested?(entries, "slack")
    assert ArtifactIdentity.contested?(entries, "@local/slack")
    assert ArtifactIdentity.contested?(entries, "@acme/catalog/slack")
    refute ArtifactIdentity.contested?(entries, "jira")
    refute ArtifactIdentity.contested?(entries, "nope")
  end

  test "canonicalize_tree rewrites the reference fields AIR qualified" do
    tree = ArtifactIdentity.canonicalize_tree(
      skills: {
        "@local/open-pr" => { "references" => [ "@local/brand" ] },
        "@acme/catalog/open-pr" => { "references" => [ "@local/brand" ] }
      },
      references: { "@local/brand" => { "title" => "Brand" } },
      mcp: { "@local/slack" => { "args" => [ "-y", "@upstash/context7-mcp@latest" ] } },
      hooks: {},
      plugins: {
        "@local/ci" => { "skills" => [ "@acme/catalog/open-pr" ], "hooks" => [] }
      },
      roots: {
        "@local/zimmer" => {
          "default_skills" => [ "@local/open-pr", "@acme/catalog/open-pr" ],
          "default_mcp_servers" => [ "@local/slack" ]
        }
      }
    )

    assert_equal [ "brand" ], tree[:skills]["open-pr"]["references"]
    assert_equal [ "@acme/catalog/open-pr" ], tree[:plugins]["ci"]["skills"]
    assert_equal [ "open-pr", "@acme/catalog/open-pr" ], tree[:roots]["zimmer"]["default_skills"]
    assert_equal [ "slack" ], tree[:roots]["zimmer"]["default_mcp_servers"]
  end

  test "canonicalize_tree leaves a non-reference field that merely looks qualified alone" do
    tree = ArtifactIdentity.canonicalize_tree(
      mcp: { "@local/context7" => { "command" => "npx", "args" => [ "-y", "@upstash/context7-mcp@latest" ] } },
      skills: {}, references: {}, hooks: {}, plugins: {}, roots: {}
    )

    assert_equal [ "-y", "@upstash/context7-mcp@latest" ], tree[:mcp]["context7"]["args"]
  end

  test "non-hash entries are dropped rather than carried into the tree" do
    assert_equal({}, ArtifactIdentity.canonicalize("@local/bogus" => "not a hash"))
    assert_equal({}, ArtifactIdentity.canonicalize("not a hash"))
  end
end

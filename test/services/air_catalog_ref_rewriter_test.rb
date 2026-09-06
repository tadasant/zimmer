# frozen_string_literal: true

require "test_helper"

class AirCatalogRefRewriterTest < ActiveSupport::TestCase
  ZIMMER_CATALOG = "github://tadasant/zimmer-catalog"
  ZIMMER_ARTIFACTS = "github://tadasant/zimmer-artifacts"
  AI_ARTIFACTS = "github://tadasant/ai-artifacts"

  PRODUCTION_AIR_JSON = <<~JSON
    {
      "$schema": "https://pulsemcp.github.io/air/schemas/air.schema.json",
      "name": "zimmer-agents",
      "gitProtocol": "https",
      "extensions": [
        "@pulsemcp/air-adapter-claude",
        "@pulsemcp/air-secrets-env",
        "@pulsemcp/air-provider-github"
      ],
      "catalogs": [
        "github://tadasant/zimmer-catalog/agents",
        "github://tadasant/zimmer-artifacts/artifacts",
        "github://tadasant/ai-artifacts"
      ],
      "exclude": {
        "mcp": [
          "@tadasant/zimmer-catalog/github"
        ],
        "roots": [
          "@tadasant/zimmer-catalog/Acadia"
        ]
      }
    }
  JSON

  test "rewrites tadasant/zimmer-catalog URIs to pin to a simple ref" do
    rewritten = AirCatalogRefRewriter.rewrite(PRODUCTION_AIR_JSON, pins: { ZIMMER_CATALOG => "feat-branch" })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog@feat-branch/agents", parsed["catalogs"][0]
  end

  test "leaves unpinned catalog URIs untouched" do
    rewritten = AirCatalogRefRewriter.rewrite(PRODUCTION_AIR_JSON, pins: { ZIMMER_CATALOG => "feat-branch" })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-artifacts/artifacts", parsed["catalogs"][1]
    assert_equal "github://tadasant/ai-artifacts", parsed["catalogs"][2]
  end

  test "pins multiple catalogs independently in a single pass" do
    rewritten = AirCatalogRefRewriter.rewrite(PRODUCTION_AIR_JSON, pins: {
      ZIMMER_CATALOG => "aaa1111",
      ZIMMER_ARTIFACTS => "bbb2222",
      AI_ARTIFACTS => "ccc3333"
    })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog@aaa1111/agents", parsed["catalogs"][0]
    assert_equal "github://tadasant/zimmer-artifacts@bbb2222/artifacts", parsed["catalogs"][1]
    assert_equal "github://tadasant/ai-artifacts@ccc3333", parsed["catalogs"][2]
  end

  test "pins a catalog URI that has no path component" do
    rewritten = AirCatalogRefRewriter.rewrite(PRODUCTION_AIR_JSON, pins: { AI_ARTIFACTS => "deadbeef" })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/ai-artifacts@deadbeef", parsed["catalogs"][2]
  end

  test "leaves sibling-repo URIs that share a prefix untouched" do
    # `github://tadasant/zimmer-catalog-foo/...` shares a string prefix with
    # `github://tadasant/zimmer-catalog` but is a different repo and must not
    # be rewritten.
    json = JSON.dump("catalogs" => [ "github://tadasant/zimmer-catalog-foo/agents" ])

    rewritten = AirCatalogRefRewriter.rewrite(json, pins: { ZIMMER_CATALOG => "feat-branch" })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog-foo/agents", parsed["catalogs"][0]
  end

  test "matches the longest prefix when one pin is a prefix of another" do
    json = JSON.dump("catalogs" => [
      "github://tadasant/zimmer-catalog/agents",
      "github://tadasant/zimmer-catalog-foo/agents"
    ])

    rewritten = AirCatalogRefRewriter.rewrite(json, pins: {
      ZIMMER_CATALOG => "shortref",
      "github://tadasant/zimmer-catalog-foo" => "longref"
    })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog@shortref/agents", parsed["catalogs"][0]
    assert_equal "github://tadasant/zimmer-catalog-foo@longref/agents", parsed["catalogs"][1]
  end

  test "leaves shortname-style references in exclude untouched" do
    rewritten = AirCatalogRefRewriter.rewrite(PRODUCTION_AIR_JSON, pins: { ZIMMER_ARTIFACTS => "feat-branch" })
    parsed = JSON.parse(rewritten)

    assert_equal "@tadasant/zimmer-catalog/github", parsed["exclude"]["mcp"][0]
    assert_equal "@tadasant/zimmer-catalog/Acadia", parsed["exclude"]["roots"][0]
  end

  test "uses legacy path-suffix syntax for refs containing a slash" do
    rewritten = AirCatalogRefRewriter.rewrite(PRODUCTION_AIR_JSON, pins: { ZIMMER_CATALOG => "user/feature-branch" })
    parsed = JSON.parse(rewritten)

    # The provider docs require the legacy `path@ref` syntax for refs with slashes
    # because the URI is split on `/` for the repo-level form.
    assert_equal "github://tadasant/zimmer-catalog/agents@user/feature-branch", parsed["catalogs"][0]
  end

  test "raises for a slash ref on a catalog URI with no path component" do
    json = JSON.dump("catalogs" => [ "github://tadasant/ai-artifacts" ])

    assert_raises(ArgumentError) do
      AirCatalogRefRewriter.rewrite(json, pins: { AI_ARTIFACTS => "user/branch" })
    end
  end

  test "supports SHA refs" do
    sha = "abc1234567890def1234567890fedcba12345678"
    rewritten = AirCatalogRefRewriter.rewrite(PRODUCTION_AIR_JSON, pins: { ZIMMER_CATALOG => sha })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog@#{sha}/agents", parsed["catalogs"][0]
  end

  test "drops an existing repo-level ref and applies the new one" do
    json = JSON.dump("catalogs" => [ "github://tadasant/zimmer-catalog@v1.0.0/agents" ])

    rewritten = AirCatalogRefRewriter.rewrite(json, pins: { ZIMMER_CATALOG => "feat-branch" })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog@feat-branch/agents", parsed["catalogs"][0]
  end

  test "drops an existing path-suffix ref and applies the new one" do
    json = JSON.dump("catalogs" => [ "github://tadasant/zimmer-catalog/agents@some/old-ref" ])

    rewritten = AirCatalogRefRewriter.rewrite(json, pins: { ZIMMER_CATALOG => "feat-branch" })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog@feat-branch/agents", parsed["catalogs"][0]
  end

  test "returns the document unchanged when no pins are given" do
    rewritten = AirCatalogRefRewriter.rewrite(PRODUCTION_AIR_JSON, pins: {})
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog/agents", parsed["catalogs"][0]
    assert_equal "github://tadasant/zimmer-artifacts/artifacts", parsed["catalogs"][1]
  end

  test "drops blank refs and leaves those catalogs untouched" do
    rewritten = AirCatalogRefRewriter.rewrite(PRODUCTION_AIR_JSON, pins: {
      ZIMMER_CATALOG => "  ",
      ZIMMER_ARTIFACTS => nil,
      AI_ARTIFACTS => ""
    })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog/agents", parsed["catalogs"][0]
    assert_equal "github://tadasant/zimmer-artifacts/artifacts", parsed["catalogs"][1]
    assert_equal "github://tadasant/ai-artifacts", parsed["catalogs"][2]
  end

  test "rewrites URIs nested deeper than top-level keys" do
    json = JSON.dump(
      "skills" => [ "github://tadasant/zimmer-catalog/agents/skills/skills.json" ],
      "nested" => {
        "deep" => {
          "uri" => "github://tadasant/zimmer-catalog/some/other/path.json"
        }
      }
    )

    rewritten = AirCatalogRefRewriter.rewrite(json, pins: { ZIMMER_CATALOG => "feat-branch" })
    parsed = JSON.parse(rewritten)

    assert_equal "github://tadasant/zimmer-catalog@feat-branch/agents/skills/skills.json", parsed["skills"][0]
    assert_equal "github://tadasant/zimmer-catalog@feat-branch/some/other/path.json", parsed.dig("nested", "deep", "uri")
  end

  # The rewriter's contract against the file staging.rb actually feeds it. Every
  # assertion here is written to hold for EITHER shape of catalog, so none of it
  # depends on whether air.production.json declares github:// sources — which is
  # what let the earlier version of this test skip itself permanently (#69).
  #
  # The last two are the load-bearing ones for the catalog as shipped. With no
  # zimmer-catalog URI to pin, the pin/unpin counts are both zero, so a rewriter
  # that dropped `"skills"` or corrupted `"./skills/skills.json"` would satisfy
  # them and still empty staging's catalog. Asserting that the structure and
  # every untouched string survive is what actually catches that.
  test "rewriting the real air.production.json on disk produces a valid JSON document" do
    air_production_path = Rails.root.join("air.production.json")
    assert File.exist?(air_production_path), "air.production.json is shipped in the image; it must exist"

    source = File.read(air_production_path)
    parsed_source = JSON.parse(source)
    rewritten = AirCatalogRefRewriter.rewrite(source, pins: { ZIMMER_CATALOG => "test-ref" })
    parsed = JSON.parse(rewritten)

    unpinned = string_values(parsed).grep(%r{\A#{Regexp.escape(ZIMMER_CATALOG)}/})
    assert_empty unpinned, "Expected no un-rewritten tadasant/zimmer-catalog URIs"

    pinned = string_values(parsed).grep(%r{\A#{Regexp.escape(ZIMMER_CATALOG)}@test-ref})
    assert_equal(
      string_values(parsed_source).grep(%r{\A#{Regexp.escape(ZIMMER_CATALOG)}(?:[/@]|\z)}).size,
      pinned.size,
      "Every tadasant/zimmer-catalog URI in the source must come back pinned"
    )

    assert_equal parsed_source.keys, parsed.keys,
      "The rewrite must not add, drop or reorder top-level catalog keys"

    untouched = ->(doc) { string_values(doc).reject { |s| s.start_with?(ZIMMER_CATALOG) } }
    assert_equal untouched.call(parsed_source), untouched.call(parsed),
      "Every string that is not a tadasant/zimmer-catalog URI must pass through verbatim"
  end

  # The no-op path staging.rb decides on. `rewrite` re-serializes with
  # JSON.pretty_generate whether or not it matched anything, so "did this pin
  # anything" is never a comparison against the source *text* — it is against a
  # zero-pin rewrite, or against the parsed source. Both spellings are pinned
  # here so the boot-time check cannot drift from the rewriter. Synthetic rather
  # than the real file, so it keeps covering the local-only shape even if
  # air.production.json later grows github:// sources.
  test "a catalog with nothing to pin is left unchanged by a pin" do
    source = <<~JSON
      {
        "name": "zimmer-catalog",
        "gitProtocol": "https",
        "skills": ["./skills/skills.json"],
        "mcp": ["./mcp.json"],
        "roots": ["./roots.json"]
      }
    JSON

    rewritten = AirCatalogRefRewriter.rewrite(source, pins: { ZIMMER_CATALOG => "test-ref" })

    assert_equal AirCatalogRefRewriter.rewrite(source, pins: {}), rewritten
    assert_equal JSON.parse(source), JSON.parse(rewritten)
  end

  # --- absolutize_sources -------------------------------------------------
  #
  # AIR resolves a config's local index paths relative to the config file's own
  # directory, so a copy written anywhere else needs absolute ones (#1078).

  test "absolutize_sources anchors every local index path at the base directory" do
    source = <<~JSON
      {
        "name": "zimmer-catalog",
        "skills": ["./skills/skills.json"],
        "mcp": ["./mcp.json"],
        "roots": ["./roots.json"],
        "references": ["./references/references.json"],
        "hooks": ["./hooks/hooks.json"],
        "plugins": ["./plugins/plugins.json"]
      }
    JSON

    parsed = JSON.parse(AirCatalogRefRewriter.absolutize_sources(source, base_dir: "/catalog/root"))

    assert_equal [ "/catalog/root/skills/skills.json" ], parsed["skills"]
    assert_equal [ "/catalog/root/mcp.json" ], parsed["mcp"]
    assert_equal [ "/catalog/root/roots.json" ], parsed["roots"]
    assert_equal [ "/catalog/root/references/references.json" ], parsed["references"]
    assert_equal [ "/catalog/root/hooks/hooks.json" ], parsed["hooks"]
    assert_equal [ "/catalog/root/plugins/plugins.json" ], parsed["plugins"]
  end

  test "absolutize_sources anchors an index path written without a ./ prefix" do
    source = JSON.generate("name" => "c", "skills" => [ "skills/skills.json" ])

    parsed = JSON.parse(AirCatalogRefRewriter.absolutize_sources(source, base_dir: "/catalog/root"))

    assert_equal [ "/catalog/root/skills/skills.json" ], parsed["skills"]
  end

  test "absolutize_sources resolves .. segments against the base directory" do
    source = JSON.generate("name" => "c", "skills" => [ "../shared/skills.json" ])

    parsed = JSON.parse(AirCatalogRefRewriter.absolutize_sources(source, base_dir: "/catalog/root"))

    assert_equal [ "/catalog/shared/skills.json" ], parsed["skills"]
  end

  test "absolutize_sources leaves already-absolute index paths alone" do
    source = JSON.generate("name" => "c", "skills" => [ "/elsewhere/skills.json" ])

    parsed = JSON.parse(AirCatalogRefRewriter.absolutize_sources(source, base_dir: "/catalog/root"))

    assert_equal [ "/elsewhere/skills.json" ], parsed["skills"]
  end

  # A URI, an npm package specifier and a ~-path all mean something other than
  # "a path relative to this config", so anchoring them would change the
  # document rather than relocate it.
  test "absolutize_sources leaves catalog URIs, package specifiers and ~ paths alone" do
    source = <<~JSON
      {
        "name": "zimmer-catalog",
        "extensions": ["@pulsemcp/air-adapter-claude", "./ext/local-adapter.mjs"],
        "catalogs": ["github://tadasant/zimmer-catalog/agents", "https://example.com/c.json", "./sibling-catalog"],
        "skills": ["~/catalogs/skills.json"]
      }
    JSON

    parsed = JSON.parse(AirCatalogRefRewriter.absolutize_sources(source, base_dir: "/catalog/root"))

    assert_equal [ "@pulsemcp/air-adapter-claude", "/catalog/root/ext/local-adapter.mjs" ], parsed["extensions"]
    assert_equal(
      [ "github://tadasant/zimmer-catalog/agents", "https://example.com/c.json", "/catalog/root/sibling-catalog" ],
      parsed["catalogs"]
    )
    assert_equal [ "~/catalogs/skills.json" ], parsed["skills"]
  end

  test "absolutize_sources leaves everything that is not a source path verbatim" do
    parsed_source = JSON.parse(PRODUCTION_AIR_JSON)

    parsed = JSON.parse(AirCatalogRefRewriter.absolutize_sources(PRODUCTION_AIR_JSON, base_dir: "/catalog/root"))

    assert_equal parsed_source.keys, parsed.keys
    assert_equal parsed_source["exclude"], parsed["exclude"]
    assert_equal parsed_source["catalogs"], parsed["catalogs"],
      "github:// catalog URIs are not filesystem paths and must pass through untouched"
    assert_equal parsed_source["extensions"], parsed["extensions"]
  end

  # The end of the fix for #1078, asserted against the file actually shipped:
  # every index path the real catalog declares must come back as a path that
  # exists on disk, because that is the property a copy written to tmp/ needs
  # and the one the relative form silently loses.
  test "absolutizing the real air.json yields index paths that exist on disk" do
    air_json_path = Rails.root.join("air.json")
    base_dir = File.dirname(air_json_path)

    parsed = JSON.parse(
      AirCatalogRefRewriter.absolutize_sources(File.read(air_json_path), base_dir: base_dir)
    )

    declared = AirCatalogRefRewriter::LOCAL_SOURCE_KEYS.flat_map { |key| Array(parsed[key]) }
    assert_operator declared.size, :>=, 6, "air.json declares one index per artifact type"

    declared.each do |path|
      assert File.absolute_path?(path), "#{path} must be absolute so the copy resolves from anywhere"
      assert File.exist?(path), "#{path} must exist — an index AIR cannot find resolves to an empty catalog"
    end
  end

  # The rewriter keeps its own copy of the type list rather than reading
  # AirCatalogService::ARTIFACT_TYPES: staging.rb `require_relative`s this file
  # at boot, before autoloading, so it cannot reach an app service. This test is
  # what keeps the two copies from drifting — a seventh artifact type added to
  # one and not the other would silently stop being absolutized.
  test "the local source keys are exactly the artifact types AirCatalogService resolves" do
    assert_equal AirCatalogService::ARTIFACT_TYPES.map(&:to_s).sort,
      AirCatalogRefRewriter::LOCAL_SOURCE_KEYS.sort
  end

  private

  # Every string the rewriter could reach in a parsed JSON document. It mirrors
  # `deep_rewrite`'s traversal exactly — including that hash *keys* are not
  # visited, since `transform_values` leaves them alone — so a count taken here
  # is directly comparable to what the rewriter produced.
  def string_values(node)
    case node
    when String then [ node ]
    when Array  then node.flat_map { |v| string_values(v) }
    when Hash   then node.values.flat_map { |v| string_values(v) }
    else []
    end
  end
end

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

  test "rewriting the actual air.production.json on disk produces a valid JSON document" do
    air_production_path = Rails.root.join("air.production.json")
    skip "air.production.json not present" unless File.exist?(air_production_path)

    # Zimmer's default air.production.json points at a self-contained local ./catalog
    # (no `catalogs` aggregation of github:// URIs), so there is nothing for the
    # ref-rewriter to pin. The rewriter is exercised on synthetic fixtures above;
    # skip here unless a deployment actually uses github:// catalogs.
    src = JSON.parse(File.read(air_production_path))
    unless src["catalogs"].is_a?(Array) && src["catalogs"].any? { |c| c.to_s.start_with?("github://") }
      skip "air.production.json uses a self-contained local catalog (no github:// catalogs to pin)"
    end

    rewritten = AirCatalogRefRewriter.rewrite(File.read(air_production_path), pins: { ZIMMER_CATALOG => "test-ref" })
    parsed = JSON.parse(rewritten)

    catalogs = parsed["catalogs"]
    assert catalogs.is_a?(Array)
    assert catalogs.any? { |c| c.start_with?("github://tadasant/zimmer-catalog@test-ref/") },
      "Expected at least one catalog to be rewritten with @test-ref, got: #{catalogs.inspect}"
    refute catalogs.any? { |c| c == "github://tadasant/zimmer-catalog/agents" },
      "Expected no un-rewritten tadasant/zimmer-catalog URIs, got: #{catalogs.inspect}"
  end
end

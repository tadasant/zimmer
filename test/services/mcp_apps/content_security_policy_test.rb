# frozen_string_literal: true

require "test_helper"

class McpApps::ContentSecurityPolicyTest < ActiveSupport::TestCase
  def directives(csp)
    McpApps::ContentSecurityPolicy.new(csp).header_value.split("; ").to_h do |directive|
      name, *sources = directive.split(" ")
      [ name, sources ]
    end
  end

  test "a resource that declares nothing gets no network at all" do
    policy = directives(nil)

    assert_equal %w['none'], policy["default-src"]
    assert_equal %w['none'], policy["connect-src"]
    assert_equal %w['none'], policy["frame-src"]
    assert_equal %w['none'], policy["object-src"]
    assert_equal %w['none'], policy["base-uri"]
    assert_equal %w['none'], policy["form-action"]
  end

  test "a fragment can still carry its own inline script and style" do
    policy = directives({})

    assert_includes policy["script-src"], "'unsafe-inline'"
    assert_includes policy["style-src"], "'unsafe-inline'"
  end

  test "eval is never granted" do
    header = McpApps::ContentSecurityPolicy.new({ "resourceDomains" => [ "https://cdn.example.com" ] }).header_value

    refute_includes header, "unsafe-eval"
  end

  test "declared domains widen exactly the directives the spec assigns them" do
    policy = directives({
      "resourceDomains" => [ "https://unpkg.com" ],
      "connectDomains" => [ "https://api.example.com" ],
      "frameDomains" => [ "https://embed.example.com" ],
      "baseUriDomains" => [ "https://base.example.com" ]
    })

    assert_includes policy["script-src"], "https://unpkg.com"
    assert_includes policy["img-src"], "https://unpkg.com"
    assert_equal [ "https://api.example.com" ], policy["connect-src"]
    assert_equal [ "https://embed.example.com" ], policy["frame-src"]
    assert_equal [ "https://base.example.com" ], policy["base-uri"]
    # A resource domain is for loading assets, never for talking to.
    refute_includes policy["connect-src"], "https://unpkg.com"
  end

  test "a wildcard host is a legal CDN spelling and survives" do
    policy = directives({ "resourceDomains" => [ "https://*.example.com" ] })

    assert_includes policy["script-src"], "https://*.example.com"
  end

  test "an entry that is not a plain origin is dropped rather than emitted" do
    policy = directives({
      "connectDomains" => [
        "javascript:alert(1)",
        "data:text/html,x",
        "//evil.example.com",
        "https://ok.example.com/path",
        "https://ok.example.com; script-src *",
        "*"
      ]
    })

    assert_equal %w['none'], policy["connect-src"]
  end

  test "the number of domains one resource can inject is capped" do
    many = (1..100).map { |i| "https://host#{i}.example.com" }
    policy = directives({ "resourceDomains" => many })

    assert_equal McpApps::ContentSecurityPolicy::MAX_DOMAINS_PER_DIRECTIVE, (policy["script-src"] - [ "'unsafe-inline'" ]).size
  end

  test "the sandbox never grants same-origin, in the header or on the element" do
    header = McpApps::ContentSecurityPolicy.new({}).header_value

    assert_includes header, "sandbox allow-scripts"
    refute_includes header, "allow-same-origin"
    refute_includes McpApps::ContentSecurityPolicy.iframe_sandbox, "allow-same-origin"
    assert_equal "allow-scripts", McpApps::ContentSecurityPolicy.iframe_sandbox
  end

  test "only Zimmer may frame a fragment" do
    assert_includes McpApps::ContentSecurityPolicy.new({}).header_value, "frame-ancestors 'self'"
  end
end

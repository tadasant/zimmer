# frozen_string_literal: true

require "test_helper"

# HttpsTokenEndpoint is the single source of truth for #892's rule — five call
# sites read it, and the repair migration freezes a copy of its predicate — so
# its edges are pinned here rather than only through the models that include it.
class HttpsTokenEndpointTest < ActiveSupport::TestCase
  # --- secure? ---

  test "secure? is true only for an https URL with a host" do
    [
      "https://auth.example.com/token",
      "HTTPS://auth.example.com/token", # URI.parse normalises the scheme
      "https://auth.example.com:8443/token",
      "https://cid:secret@auth.example.com/token", # userinfo is permitted here, unlike XOauthCredential
      "https://[2001:db8::1]/token"
    ].each { |value| assert HttpsTokenEndpoint.secure?(value), "#{value.inspect} should be secure" }
  end

  test "secure? is false for everything else, including the values a LIKE filter would keep" do
    [
      "http://auth.example.com/token",
      "http://127.0.0.1:9000/token",
      "http://[::1]:9000/token",
      "http://localhost:9000/token",
      "ftp://auth.example.com/token",
      "auth.example.com/token",
      "https:/auth.example.com/token", # single slash — parses, but has no host
      "https://",                      # scheme is right, host is missing
      "https://auth.example.com/token ", # trailing space
      nil,
      ""
    ].each { |value| assert_not HttpsTokenEndpoint.secure?(value), "#{value.inspect} should not be secure" }
  end

  # The value reaches this from a remote server's discovery document, so "answers
  # false" rather than "raises" is the contract every call site depends on — the
  # validation, can_refresh?, post_form, post_json and the controller all call it
  # without a guard of their own.
  test "secure? answers false rather than raising on input it cannot parse" do
    [ "https://auth.example.com/a path", "https://ex ample.com/token", "http://[/token", " " ].each do |value|
      assert_nothing_raised { HttpsTokenEndpoint.secure?(value) }
      assert_not HttpsTokenEndpoint.secure?(value)
    end
  end

  test "secure? accepts an already-parsed URI as well as a string" do
    assert HttpsTokenEndpoint.secure?(URI("https://auth.example.com/token"))
    assert_not HttpsTokenEndpoint.secure?(URI("http://auth.example.com/token"))
  end

  # --- describe ---

  # describe's output lands in a flash message, a log line and an exception
  # message, so it must never carry the credential embedded in the URL.
  test "describe drops userinfo and the query string" do
    described = HttpsTokenEndpoint.describe("https://client-id:s3cret@auth.example.com/token?state=x")

    assert_equal "https://auth.example.com/token", described
    assert_not_includes described, "s3cret"
    assert_not_includes described, "client-id"
  end

  test "describe keeps a non-default port and omits a default one" do
    assert_equal "https://auth.example.com:8443/token", HttpsTokenEndpoint.describe("https://auth.example.com:8443/token")
    assert_equal "https://auth.example.com/token", HttpsTokenEndpoint.describe("https://auth.example.com:443/token")
    assert_equal "http://auth.example.com/token", HttpsTokenEndpoint.describe("http://auth.example.com:80/token")
  end

  test "describe says so rather than raising when there is no host or no parse" do
    [ nil, "", "https://", "auth.example.com/token" ].each do |value|
      assert_equal "(unusable URL)", HttpsTokenEndpoint.describe(value), "for #{value.inspect}"
    end

    assert_equal "(unparseable URL)", HttpsTokenEndpoint.describe("https://auth.example.com/a path")
  end

  # The only bound on remote-supplied text reaching a flash and a log line. A
  # server can answer discovery with a kilobyte of path; nothing else stops it.
  test "describe truncates a hostile path at DESCRIPTION_LIMIT" do
    described = HttpsTokenEndpoint.describe("https://auth.example.com/#{"x" * 5_000}")

    assert_equal HttpsTokenEndpoint::DESCRIPTION_LIMIT, described.length
    assert described.start_with?("https://auth.example.com/xxx")
  end

  # --- the validation the models share ---

  test "the shared validation reports the shared message, and leaves blank alone" do
    refused = McpOauthCredential.new(
      server_name: "s", server_url: "https://mcp.example.com", credential_key: "s|1",
      client_id: "cid", access_token: "at", token_endpoint: "http://auth.example.com/token"
    )
    refused.valid?
    assert_equal [ HttpsTokenEndpoint::MESSAGE ], refused.errors[:token_endpoint]

    # Same module, same message, on the other includer.
    flow = McpOauthPendingFlow.new(token_endpoint: "http://auth.example.com/token")
    flow.valid?
    assert_equal [ HttpsTokenEndpoint::MESSAGE ], flow.errors[:token_endpoint]
  end
end

# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Zimmer's own calls to a brokered server, and keeping brokered tokens out of
# transcripts.
class TokenBrokerBackendAndRedactionTest < ActiveSupport::TestCase
  include TokenBrokerTestHelpers

  setup do
    @strad = FakeStrad.new
    client = @strad.client
    TokenBroker::Client.stubs(:new).returns(client)
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    @saved = ENV["STRAD_API_KEY"]
    ENV["STRAD_API_KEY"] = "static-strad-key-0123456789abcdef"
    SecretProviders.reset!
    TranscriptRedactor.reset_known_secrets!
  end

  teardown do
    @saved.nil? ? ENV.delete("STRAD_API_KEY") : ENV["STRAD_API_KEY"] = @saved
    SecretProviders.reset!
    TranscriptRedactor.reset_known_secrets!
  end

  test "a backend call to a brokered entry uses Zimmer's own child token, not the static key" do
    with_oauth_client_identity do
      @strad.create_grant!
      headers = McpServerEndpoint.new(ServersConfig.find("image-diff")).headers

      assert_match(/\ABearer strad_oat_child/, headers["Authorization"])
      assert_equal "zimmer:backend", @strad.exchanges.sole.params["label"]
      refute_includes headers.values.join, "static-strad-key"
    end
  end

  test "a backend call to a static entry is unchanged" do
    headers = McpServerEndpoint.new(ServersConfig.find("granola")).headers
    assert_equal "Bearer static-strad-key-0123456789abcdef", headers["Authorization"]
  end

  test "a brokered entry without a grant is unresolvable, with the cause, never the static key" do
    with_oauth_client_identity do
      error = assert_raises(McpServerEndpoint::UnresolvableError) do
        McpServerEndpoint.new(ServersConfig.find("image-diff")).headers
      end
      assert_match(/no token broker grant exists/, error.message)
    end
  end

  test "a strad token is redacted by shape" do
    line = %({"text":"token is strad_oat_AbCdEf0123456789_-xyz and refresh strad_ort_ZYXwvu9876543210abc"})
    redacted = TranscriptRedactor.redact(line)

    refute_includes redacted, "strad_oat_AbCdEf0123456789_-xyz"
    refute_includes redacted, "strad_ort_ZYXwvu9876543210abc"
  end

  test "minted children and the parent grant are in the known-value set" do
    with_oauth_client_identity do
      grant = @strad.create_grant!(refresh_token: "opaque-refresh-value-without-a-prefix-1")
      child = TokenBroker.mint_for_session(sessions(:active_session), %w[image-diff]).tokens["image-diff"]

      redacted = TranscriptRedactor.redact("#{child} and #{grant.refresh_token}")
      refute_includes redacted, child
      refute_includes redacted, "opaque-refresh-value-without-a-prefix-1"
    end
  end
end

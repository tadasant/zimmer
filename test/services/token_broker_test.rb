# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The session token broker against an in-process strad (FakeStrad), which
# verifies every client assertion the way strad does and records each request,
# so these pin both the lifecycle and the wire contract of tadasant/strad#537.
class TokenBrokerTest < ActiveSupport::TestCase
  include TokenBrokerTestHelpers
  include ActiveJob::TestHelper

  setup do
    @strad = FakeStrad.new
    @session = sessions(:active_session)
    client = @strad.client
    TokenBroker::Client.stubs(:new).returns(client)
    stub_mcp_catalog(
      "image-diff" => brokered_strad_entry("image-diff"),
      "svg-tracer" => brokered_strad_entry("svg-tracer"),
      "granola" => static_strad_entry("granola")
    )
  end

  # --- the exchange request: strad#537 (b) -------------------------------

  test "the exchange request carries exactly strad's token-exchange fields" do
    with_oauth_client_identity do
      @strad.create_grant!(access_token: "strad_oat_parentcurrent", access_token_expires_at: 1.hour.from_now)

      TokenBroker.mint_for_session(@session, %w[image-diff])

      request = @strad.exchanges.sole
      assert_equal "/oauth/token", request.path
      assert_equal({
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "client_id" => OauthClientIdentity.client_id,
        "subject_token" => "strad_oat_parentcurrent",
        "subject_token_type" => "urn:ietf:params:oauth:token-type:access_token",
        "requested_token_type" => "urn:ietf:params:oauth:token-type:access_token",
        "scope" => "slug:image-diff",
        "expires_in" => "21600",
        "label" => "session:#{@session.id}",
        "resource" => FakeStrad::RESOURCE
      }, request.params.except("client_assertion", "client_assertion_type"))
      assert_equal "urn:ietf:params:oauth:client-assertion-type:jwt-bearer", request.params["client_assertion_type"]
      claims = request.assertion_claims
      assert_equal OauthClientIdentity.client_id, claims["iss"]
      assert_equal OauthClientIdentity.client_id, claims["sub"]
      assert_equal FakeStrad::TOKEN_ENDPOINT, claims["aud"]
      assert claims["jti"].present?
    end
  end

  test "the label satisfies strad's label grammar" do
    assert_match(/\A[A-Za-z0-9][A-Za-z0-9.:\-]{0,63}\z/, "session:#{@session.id}")
    assert_match(/\A[A-Za-z0-9][A-Za-z0-9.:\-]{0,63}\z/, TokenBroker::BACKEND_LABEL)
  end

  # --- minting -----------------------------------------------------------

  test "one child per session per authorization server, scoped to the union of its brokered entries" do
    with_oauth_client_identity do
      @strad.create_grant!

      result = TokenBroker.mint_for_session(@session, %w[image-diff svg-tracer granola])

      assert_equal 1, @strad.exchanges.size, "two entries on one server are one exchange"
      assert_equal "slug:image-diff slug:svg-tracer", @strad.exchanges.sole.params["scope"]
      assert_equal %w[image-diff svg-tracer], result.tokens.keys.sort
      assert_equal 1, result.tokens.values.uniq.size
      assert_empty result.failures
      refute result.tokens.key?("granola"), "a static entry is not the broker's"

      row = McpBrokeredToken.sole
      assert_equal "live", row.state
      assert_equal "session", row.purpose
      assert_equal @session.id, row.session_id
      assert_equal "slug:image-diff slug:svg-tracer", row.scope
      assert_in_delta 6.hours.from_now, row.expires_at, 5
    end
  end

  test "strad's answered lifetime wins over the one asked for" do
    with_oauth_client_identity do
      @strad.create_grant!
      @strad.child_expires_in = 600

      TokenBroker.mint_for_session(@session, %w[image-diff])

      assert_in_delta 10.minutes.from_now, McpBrokeredToken.sole.expires_at, 5
    end
  end

  test "a new turn supersedes the previous turn's child and revokes it" do
    with_oauth_client_identity do
      @strad.create_grant!
      first = TokenBroker.mint_for_session(@session, %w[image-diff]).tokens["image-diff"]

      perform_enqueued_jobs do
        TokenBroker.mint_for_session(@session, %w[image-diff])
      end

      assert_equal [ first ], @strad.revoked
      assert_equal %w[revoked live], McpBrokeredToken.order(:id).pluck(:state)
    end
  end

  test "a stale parent access token is refreshed with an assertion, and the rotated refresh token is kept" do
    with_oauth_client_identity do
      grant = @strad.create_grant!(access_token_expires_at: 1.minute.from_now, refresh_token: "strad_ort_original")

      TokenBroker.mint_for_session(@session, %w[image-diff])

      refresh = @strad.refreshes.sole
      assert_equal "strad_ort_original", refresh.params["refresh_token"]
      assert_equal OauthClientIdentity.client_id, refresh.params["client_id"]
      assert_equal FakeStrad::RESOURCE, refresh.params["resource"]
      grant.reload
      assert_match(/\Astrad_ort_rotated/, grant.refresh_token)
      assert_equal grant.access_token, @strad.exchanges.sole.params["subject_token"]
    end
  end

  # --- failure: never a broader credential -------------------------------

  test "with no grant the entries fail with a cause a human can act on" do
    with_oauth_client_identity do
      result = TokenBroker.mint_for_session(@session, %w[image-diff svg-tracer])

      assert_empty result.tokens
      assert_equal %w[image-diff svg-tracer], result.failures.keys.sort
      assert_match(/no token broker grant exists for #{Regexp.escape(FakeStrad::ORIGIN)}/, result.failures["image-diff"])
      assert_match(/Token broker page/, result.failures["image-diff"])
      assert_empty @strad.requests
    end
  end

  test "without the client identity nothing is minted and the cause says so" do
    result = TokenBroker.mint_for_session(@session, %w[image-diff])

    assert_empty result.tokens
    assert_match(/client identity is not configured/, result.failures["image-diff"])
  end

  test "a refused refresh marks the grant as needing consent, durably" do
    with_oauth_client_identity do
      grant = @strad.create_grant!(access_token_expires_at: 1.minute.ago)
      @strad.refresh_failure = [ 400, { error: "invalid_grant", error_description: "grant revoked" } ]

      result = TokenBroker.mint_for_session(@session, %w[image-diff])

      assert_match(/not usable.*grant revoked.*Reconnect/, result.failures["image-diff"])
      grant.reload
      assert_equal "needs_consent", grant.status, "the status update must survive the failed refresh"
      assert_match(/grant revoked/, grant.last_error)
      assert_empty @strad.exchanges
    end
  end

  test "a transient refresh failure keeps the grant usable for the next turn" do
    with_oauth_client_identity do
      grant = @strad.create_grant!(access_token_expires_at: 1.minute.ago)
      @strad.refresh_failure = [ 503, { error: "temporarily_unavailable" } ]

      result = TokenBroker.mint_for_session(@session, %w[image-diff])

      assert_match(/could not renew.*503/, result.failures["image-diff"])
      grant.reload
      assert_equal "active", grant.status
      assert_match(/503/, grant.last_error)
    end
  end

  test "an exchange strad refuses names strad's own reason" do
    with_oauth_client_identity do
      @strad.create_grant!
      @strad.exchange_failure = [ 400, { error: "invalid_scope", error_description: "slug:image-diff is outside the subject token" } ]

      result = TokenBroker.mint_for_session(@session, %w[image-diff])

      assert_match(/did not issue a token.*invalid_scope: slug:image-diff is outside the subject token/, result.failures["image-diff"])
      assert_equal 0, McpBrokeredToken.count
    end
  end

  test "an invalid declaration is a visible failure, not a fallback" do
    stub_mcp_catalog("broken" => static_strad_entry("broken").merge("brokered_auth" => { "scopes" => [] }))
    with_oauth_client_identity do
      @strad.create_grant!
      result = TokenBroker.mint_for_session(@session, %w[broken])

      assert_match(/declaration is invalid/, result.failures["broken"])
      assert_empty result.tokens
    end
  end

  test "an entry whose resource is not the grant's is refused" do
    stub_mcp_catalog("elsewhere" => brokered_strad_entry("x").merge("url" => "#{FakeStrad::ORIGIN}/other?servers=x"))
    with_oauth_client_identity do
      @strad.create_grant!
      result = TokenBroker.mint_for_session(@session, %w[elsewhere])

      assert_match(/not served by the grant/, result.failures["elsewhere"])
    end
  end

  test "nothing happens at all for a session with no brokered entry" do
    result = TokenBroker.mint_for_session(@session, %w[granola])

    refute result.any?
    assert_empty @strad.requests
  end

  # --- revocation: strad#537 (c) ------------------------------------------

  test "the revocation request matches strad's contract" do
    with_oauth_client_identity do
      @strad.create_grant!
      token = TokenBroker.mint_for_session(@session, %w[image-diff]).tokens["image-diff"]

      TokenBroker.revoke_session_tokens(@session.id)

      request = @strad.revocations.sole
      assert_equal({ "token" => token, "token_type_hint" => "access_token", "client_id" => OauthClientIdentity.client_id },
        request.params.except("client_assertion", "client_assertion_type"))
      assert_equal FakeStrad::TOKEN_ENDPOINT, request.assertion_claims["aud"]
      assert_equal "revoked", McpBrokeredToken.sole.state
    end
  end

  test "a revocation only takes children minted at or before the rest" do
    with_oauth_client_identity do
      @strad.create_grant!
      TokenBroker.mint_for_session(@session, %w[image-diff])
      rested_at = Time.current
      travel 1.second
      later = McpBrokeredToken.sole.dup.tap { |r| r.token = "strad_oat_newturn000000000000"; r.save! }

      TokenBroker.revoke_session_tokens(@session.id, rested_at: rested_at)

      assert_equal "live", later.reload.state
      assert_equal 1, @strad.revoked.size
    end
  end

  test "a failed revocation is retried on backoff, and closes as expired once the token has" do
    with_oauth_client_identity do
      @strad.create_grant!
      TokenBroker.mint_for_session(@session, %w[image-diff])
      @strad.revoke_failure = [ 503, { error: "temporarily_unavailable" } ]

      TokenBroker.revoke_session_tokens(@session.id)
      row = McpBrokeredToken.sole
      assert_equal "revoke_pending", row.state
      assert_equal 1, row.revoke_attempts
      assert_in_delta 30.seconds.from_now, row.next_revoke_attempt_at, 5

      @strad.revoke_failure = nil
      travel 31.seconds
      TokenBrokerSweepJob.perform_now
      assert_equal "revoked", row.reload.state

      # A second token whose revocation never lands simply expires.
      TokenBroker.mint_for_session(@session, %w[image-diff])
      @strad.revoke_failure = [ 503, { error: "temporarily_unavailable" } ]
      TokenBroker.revoke_session_tokens(@session.id)
      travel 7.hours
      TokenBrokerSweepJob.perform_now
      assert_equal "expired", McpBrokeredToken.order(:id).last.state
    end
  end

  # --- backend tokens -----------------------------------------------------

  test "the backend gets its own child, reused until near expiry, never a session's" do
    with_oauth_client_identity do
      @strad.create_grant!
      session_token = TokenBroker.mint_for_session(@session, %w[image-diff]).tokens["image-diff"]
      server = ServersConfig.find("image-diff")

      first = TokenBroker.backend_token(server)
      second = TokenBroker.backend_token(server)

      refute_equal session_token, first
      assert_equal first, second, "a live backend child is reused"
      backend = @strad.exchanges.last
      assert_equal "zimmer:backend", backend.params["label"]
      assert_equal "slug:image-diff", backend.params["scope"]
      assert_equal "3600", backend.params["expires_in"]

      travel 55.minutes
      third = TokenBroker.backend_token(server)
      refute_equal first, third
      assert_equal "revoke_pending", McpBrokeredToken.find_by(purpose: "backend", state: "revoke_pending")&.state
    end
  end

  # --- at rest --------------------------------------------------------------

  test "secrets are encrypted at rest with no plaintext column" do
    with_oauth_client_identity do
      grant = @strad.create_grant!(refresh_token: "strad_ort_secretvalue1234")
      TokenBroker.mint_for_session(@session, %w[image-diff])
      child = McpBrokeredToken.sole.token

      raw_grant = McpBrokerGrant.connection.select_one("SELECT access_token, refresh_token FROM mcp_broker_grants WHERE id = #{grant.id}")
      raw_child = McpBrokeredToken.connection.select_value("SELECT token FROM mcp_brokered_tokens")
      refute_includes raw_grant.values.join, "strad_ort_secretvalue1234"
      refute_includes raw_child, child
      refute_includes grant.inspect, "strad_ort_secretvalue1234"
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class XOauthPendingFlowTest < ActiveSupport::TestCase
  def start(account_key: "acct", access_token_env_var: "X_OAUTH_ACCESS_TOKEN", **opts)
    XOauthPendingFlow.start!(account_key: account_key, access_token_env_var: access_token_env_var, **opts)
  end

  # --- start! ---

  test "start! persists a fresh state, verifier and expiry for the credential" do
    flow = start

    assert_predicate flow, :persisted?
    assert_equal 22, flow.state.length
    assert_equal 43, flow.code_verifier.length
    assert_equal XOauthBootstrap.default_redirect_uri, flow.redirect_uri
    assert_in_delta XOauthPendingFlow::EXPIRATION_DURATION.from_now, flow.expires_at, 5.seconds
    assert_not_equal flow.state, start(access_token_env_var: "X_OTHER_TOKEN", account_key: "other").state
  end

  test "start! replaces a flow already in progress for the same env var" do
    first = start
    second = start

    assert_not XOauthPendingFlow.exists?(first.id)
    assert XOauthPendingFlow.exists?(second.id)
  end

  test "start! leaves a flow for a different env var alone" do
    other = start(account_key: "other", access_token_env_var: "X_OTHER_TOKEN")
    start

    assert XOauthPendingFlow.exists?(other.id)
  end

  test "start! sweeps expired flows" do
    stale = start(account_key: "other", access_token_env_var: "X_OTHER_TOKEN")
    stale.update_column(:expires_at, 1.minute.ago)

    start

    assert_not XOauthPendingFlow.exists?(stale.id)
  end

  test "start! refuses an env var that is not an environment-variable name" do
    assert_raises(ActiveRecord::RecordInvalid) { start(access_token_env_var: "x-token; rm") }
    assert_raises(ActiveRecord::RecordInvalid) { start(access_token_env_var: "") }
    assert_raises(ActiveRecord::RecordInvalid) { start(account_key: "  ") }
    assert_equal 0, XOauthPendingFlow.count
  end

  test "start! refuses an account another env var already vends" do
    XOauthCredential.create!(account_key: "acct", access_token_env_var: "X_OAUTH_ACCESS_TOKEN")

    error = assert_raises(ActiveRecord::RecordInvalid) { start(access_token_env_var: "X_SECOND_TOKEN") }
    assert_match(/already vended as X_OAUTH_ACCESS_TOKEN/, error.message)
  end

  test "start! refuses an env var that already vends another account" do
    XOauthCredential.create!(account_key: "acct", access_token_env_var: "X_OAUTH_ACCESS_TOKEN")

    error = assert_raises(ActiveRecord::RecordInvalid) { start(account_key: "someone-else") }
    assert_match(/already vends acct/, error.message)
  end

  test "start! accepts the identity of an existing credential, for re-authorizing it" do
    XOauthCredential.create!(account_key: "acct", access_token_env_var: "X_OAUTH_ACCESS_TOKEN")

    assert_predicate start, :persisted?
  end

  # --- claim! ---

  test "claim! returns the flow and deletes it" do
    flow = start

    claimed = XOauthPendingFlow.claim!(flow.state)

    assert_equal flow.code_verifier, claimed.code_verifier
    assert_equal "acct", claimed.account_key
    assert_not XOauthPendingFlow.exists?(flow.id)
  end

  test "claim! works once: a second claim of the same state is refused" do
    flow = start
    XOauthPendingFlow.claim!(flow.state)

    assert_raises(XOauthPendingFlow::ClaimError) { XOauthPendingFlow.claim!(flow.state) }
  end

  # Two callbacks racing on one state both find the row; the one whose DELETE
  # comes second must be refused, not handed the verifier too.
  test "claim! refuses a flow another request deleted between the lookup and the claim" do
    flow = start
    racing_lookup = XOauthPendingFlow.find_by(state: flow.state)
    XOauthPendingFlow.where(id: flow.id).delete_all

    XOauthPendingFlow.stub(:find_by, racing_lookup) do
      assert_raises(XOauthPendingFlow::ClaimError) { XOauthPendingFlow.claim!(flow.state) }
    end
  end

  test "claim! refuses an unknown state and leaves real flows alone" do
    flow = start

    assert_raises(XOauthPendingFlow::ClaimError) { XOauthPendingFlow.claim!("not-the-state") }
    assert XOauthPendingFlow.exists?(flow.id)
  end

  test "claim! refuses a blank state" do
    start

    assert_raises(XOauthPendingFlow::ClaimError) { XOauthPendingFlow.claim!(nil) }
    assert_raises(XOauthPendingFlow::ClaimError) { XOauthPendingFlow.claim!("") }
    assert_equal 1, XOauthPendingFlow.count
  end

  test "claim! refuses an expired flow and deletes it" do
    flow = start
    flow.update_column(:expires_at, 1.second.ago)

    error = assert_raises(XOauthPendingFlow::ClaimError) { XOauthPendingFlow.claim!(flow.state) }
    assert_match(/expired/, error.message)
    assert_not XOauthPendingFlow.exists?(flow.id)
  end

  # --- parse_redirect ---

  test "parse_redirect reads state and code out of a pasted redirect URL" do
    parsed = XOauthPendingFlow.parse_redirect("  http://localhost:8080/callback?state=abc&code=xyz#_  ")

    assert_equal({ state: "abc", code: "xyz", error: nil, error_description: nil }, parsed)
  end

  test "parse_redirect reads an error redirect" do
    parsed = XOauthPendingFlow.parse_redirect("http://localhost:8080/callback?error=access_denied&state=abc")

    assert_equal "abc", parsed[:state]
    assert_equal "access_denied", parsed[:error]
  end

  test "parse_redirect refuses anything without a state, a bare code included" do
    assert_nil XOauthPendingFlow.parse_redirect("just-a-code")
    assert_nil XOauthPendingFlow.parse_redirect("http://localhost:8080/callback?code=xyz")
    assert_nil XOauthPendingFlow.parse_redirect("")
    assert_nil XOauthPendingFlow.parse_redirect(nil)
  end

  # --- consent URL and completion mode ---

  test "authorization_url carries this flow's state, redirect and PKCE challenge" do
    flow = start
    params = URI.decode_www_form(URI(flow.authorization_url(client_id: "CID")).query).to_h

    assert_equal flow.state, params["state"]
    assert_equal flow.redirect_uri, params["redirect_uri"]
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(flow.code_verifier)).delete("="), params["code_challenge"]
  end

  test "manual? is false only for the hosted callback" do
    assert_predicate start(redirect_uri: XOauthBootstrap::DEFAULT_REDIRECT_URI), :manual?
    assert_not_predicate start(redirect_uri: XOauthBootstrap.hosted_redirect_uri), :manual?
  end
end

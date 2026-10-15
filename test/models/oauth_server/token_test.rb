# frozen_string_literal: true

require "test_helper"

class OauthServer::TokenTest < ActiveSupport::TestCase
  setup do
    ENV["OAUTH_SERVER_ISSUER"] = "https://zimmer.example.test"
    @grant = OauthServer::Grant.create!(client: OauthServer::NativeApp.client, user_email: "a@example.com",
      resource: "https://zimmer.example.test/mcp", scope: OauthServer::SCOPE)
    @spent = token_for(@grant.issue_tokens!, OauthServer::Token::REFRESH)
    @spent.rotate!
    @first = @grant.issue_tokens!(rotated_from: @spent)
    travel 1.second
    @second = @grant.issue_tokens!(rotated_from: @spent)
  end

  teardown { ENV.delete("OAUTH_SERVER_ISSUER") }

  def token_for(pair, kind)
    value = kind == OauthServer::Token::ACCESS ? pair.access_token : pair.refresh_token
    OauthServer::Token.find_by!(token_digest: OauthServer.digest(value))
  end

  test "the first pair claimed retires its sibling, both halves, and stamps its own" do
    assert token_for(@first, OauthServer::Token::ACCESS).mark_used!

    first_refresh = token_for(@first, OauthServer::Token::REFRESH)
    assert first_refresh.used_at, "the refresh half carries the evidence too"
    assert_equal @spent.id, first_refresh.rotated_from_id

    [ OauthServer::Token::ACCESS, OauthServer::Token::REFRESH ].each do |kind|
      retired = token_for(@second, kind)
      assert_nil retired.rotated_from_id
      assert retired.expires_at <= Time.current
    end
  end

  test "a pair that lost the claim while loaded reports it and retires nothing" do
    stale = token_for(@second, OauthServer::Token::ACCESS)
    assert token_for(@first, OauthServer::Token::ACCESS).mark_used!

    refute stale.mark_used!, "the stale copy still names the spent token but has been retired"
    winner = token_for(@first, OauthServer::Token::ACCESS)
    assert_equal @spent.id, winner.rotated_from_id
    assert winner.expires_at > Time.current, "the winner stays live"
  end

  test "a retired access token is refused at the door" do
    stale = token_for(@second, OauthServer::Token::ACCESS)
    token_for(@first, OauthServer::Token::ACCESS).mark_used!

    lookup = OauthServer::Token.authenticate_access(@second.access_token, resource: @grant.resource)
    assert_equal :expired, lookup.refusal
    refute stale.reload.used_at
  end
end

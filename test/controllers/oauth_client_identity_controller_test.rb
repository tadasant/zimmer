# frozen_string_literal: true

require "test_helper"

# The two public documents of Zimmer's hosted OAuth client identity: reachable
# without signing in, and carrying nothing but public metadata and public keys.
class OauthClientIdentityControllerTest < ActionDispatch::IntegrationTest
  test "both paths are 404 while the identity is not configured" do
    get "/oauth-client/metadata.json"
    assert_response :not_found
    get "/oauth-client/jwks.json"
    assert_response :not_found
  end

  test "the metadata document is served at its own client_id, from configuration, not the request host" do
    with_oauth_client_identity do
      get "/oauth-client/metadata.json", headers: { "Host" => "attacker.example.net" }

      assert_response :success
      assert_equal "application/json", response.media_type
      doc = response.parsed_body
      assert_equal "https://zimmer.example.com/oauth-client/metadata.json", doc["client_id"]
      assert_equal "private_key_jwt", doc["token_endpoint_auth_method"]
      assert_equal "https://zimmer.example.com/oauth-client/jwks.json", doc["jwks_uri"]
      assert_not_includes response.body, "attacker.example.net"
    end
  end

  test "the JWKS carries public keys only" do
    with_oauth_client_identity(keys: [ generate_ec_key, generate_rsa_key ]) do
      get "/oauth-client/jwks.json"

      assert_response :success
      assert_match(/public/, response.headers["Cache-Control"])
      keys = response.parsed_body["keys"]
      assert_equal 2, keys.size
      keys.each { |jwk| assert_empty jwk.keys & %w[d p q dp dq qi], "a JWK leaked a private parameter" }
    end
  end

  test "a signer that cannot produce its key answers 503 without the reason" do
    with_oauth_client_identity do
      OauthClientIdentity.stub(:jwks, ->(*) { raise OauthClientIdentity::Unavailable, "KMS projects/secret-project answered 403" }) do
        get "/oauth-client/jwks.json"
      end

      assert_response :service_unavailable
      assert_not_includes response.body, "secret-project"
    end
  end
end

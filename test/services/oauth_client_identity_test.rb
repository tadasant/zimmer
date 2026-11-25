# frozen_string_literal: true

require "test_helper"
require "jwt"

class OauthClientIdentityTest < ActiveSupport::TestCase
  test "is off with nothing configured, and off with only one of the two halves" do
    assert_not OauthClientIdentity.enabled?({})
    assert_not OauthClientIdentity.enabled?(OauthClientIdentity::BASE_URL_ENV => "https://zimmer.example.com")
    assert_not OauthClientIdentity.enabled?(OauthClientIdentity::KeySet::LOCAL_KEYS_ENV => "x")
    assert OauthClientIdentity.enabled?(
      OauthClientIdentity::BASE_URL_ENV => "https://zimmer.example.com",
      OauthClientIdentity::KeySet::LOCAL_KEYS_ENV => "x"
    )
  end

  test "the base URL is normalized, must be https (http only for localhost), and is never a path" do
    base = ->(v) { OauthClientIdentity.base_url(OauthClientIdentity::BASE_URL_ENV => v) }

    assert_equal "https://zimmer.example.com", base.call("https://Zimmer.Example.com/")
    assert_equal "https://zimmer.example.com:8443", base.call("https://zimmer.example.com:8443")
    assert_equal "http://localhost:3000", base.call("http://localhost:3000")
    assert_nil base.call("http://zimmer.example.com")
    assert_nil base.call("https://zimmer.example.com/prefix")
    assert_nil base.call("https://zimmer.example.com/?q=1")
    assert_nil base.call("zimmer.example.com")
    assert_nil base.call("")
  end

  test "the metadata document names itself as client_id and carries only public metadata" do
    with_oauth_client_identity do
      doc = OauthClientIdentity.metadata_document

      assert_equal "https://zimmer.example.com/oauth-client/metadata.json", doc[:client_id]
      assert_equal [ "https://zimmer.example.com/mcp_oauth/callback" ], doc[:redirect_uris]
      assert_equal "private_key_jwt", doc[:token_endpoint_auth_method]
      assert_equal "https://zimmer.example.com/oauth-client/jwks.json", doc[:jwks_uri]
      assert_equal %w[authorization_code refresh_token], doc[:grant_types]
      assert_equal %w[code], doc[:response_types]
      assert_equal "Zimmer", doc[:client_name]
      assert_not doc.key?(:jwks), "keys are published at jwks_uri, never inline"
      assert_not doc.key?(:client_secret)
    end
  end

  test "the JWKS publishes every key, active first, with no private parameters" do
    active = generate_ec_key
    previous = generate_rsa_key
    with_oauth_client_identity(keys: [ active, previous ]) do
      keys = OauthClientIdentity.jwks[:keys]

      assert_equal 2, keys.size
      assert_equal [ "ES256", "RS256" ], keys.map { |k| k["alg"] }
      assert_equal 2, keys.map { |k| k["kid"] }.uniq.size
      keys.each do |jwk|
        assert_equal "sig", jwk["use"]
        (%w[d p q dp dq qi]).each { |priv| assert_not jwk.key?(priv), "JWK must not carry #{priv}" }
      end
    end
  end

  test "a client assertion is an RFC 7523 JWT signed by the active key and verifiable from the JWKS" do
    with_oauth_client_identity(keys: [ generate_ec_key, generate_rsa_key ]) do
      token = OauthClientIdentity.client_assertion(audience: "https://as.example.com/oauth/token")
      jwks = JWT::JWK::Set.new(JSON.parse(OauthClientIdentity.jwks.to_json))

      claims, header = JWT.decode(token, nil, true, algorithms: %w[ES256 RS256], jwks: jwks,
        aud: "https://as.example.com/oauth/token", verify_aud: true)

      id = OauthClientIdentity.client_id
      assert_equal "ES256", header["alg"]
      assert_equal OauthClientIdentity.jwks[:keys].first["kid"], header["kid"]
      assert_equal id, claims["iss"]
      assert_equal id, claims["sub"]
      assert_equal OauthClientIdentity::ASSERTION_LIFETIME, claims["exp"] - claims["iat"]
      assert claims["jti"].present?
    end
  end

  test "an RSA active key signs RS256 the JWKS verifies" do
    with_oauth_client_identity(keys: [ generate_rsa_key ]) do
      token = OauthClientIdentity.client_assertion(audience: "https://as.example.com/token")
      jwks = JWT::JWK::Set.new(JSON.parse(OauthClientIdentity.jwks.to_json))

      _claims, header = JWT.decode(token, nil, true, algorithms: %w[RS256], jwks: jwks)
      assert_equal "RS256", header["alg"]
    end
  end

  test "every assertion has a fresh jti" do
    with_oauth_client_identity do
      jtis = 3.times.map do
        JWT.decode(OauthClientIdentity.client_assertion(audience: "https://as.example.com/token"), nil, false).first["jti"]
      end
      assert_equal 3, jtis.uniq.size
    end
  end

  test "asking for an assertion with the identity off raises Unavailable" do
    assert_raises(OauthClientIdentity::Unavailable) do
      OauthClientIdentity.client_assertion(audience: "https://as.example.com/token", env: {})
    end
  end

  test "a malformed local key raises Unavailable without quoting it" do
    error = assert_raises(OauthClientIdentity::Unavailable) { OauthClientIdentity::LocalKeySigner.new("not-a-key-secretbytes") }
    assert_not_includes error.message, "secretbytes"
  end

  test "a small RSA key and a non-P-256 curve are refused" do
    assert_raises(OauthClientIdentity::Unavailable) do
      OauthClientIdentity::LocalKeySigner.new(local_key_value(OpenSSL::PKey::RSA.new(1024)))
    end
    assert_raises(OauthClientIdentity::Unavailable) do
      OauthClientIdentity::LocalKeySigner.new(local_key_value(OpenSSL::PKey::EC.generate("secp384r1")))
    end
  end

  test "owns_client_id? matches only the configured identity; hosted_client_id? matches the shape" do
    with_oauth_client_identity do
      assert OauthClientIdentity.owns_client_id?("https://zimmer.example.com/oauth-client/metadata.json")
      assert_not OauthClientIdentity.owns_client_id?("https://other.example.com/oauth-client/metadata.json")
      assert_not OauthClientIdentity.owns_client_id?("zimmer")
    end
    assert_not OauthClientIdentity.owns_client_id?("https://zimmer.example.com/oauth-client/metadata.json")
    assert OauthClientIdentity.hosted_client_id?("https://zimmer.example.com/oauth-client/metadata.json")
    assert_not OauthClientIdentity.hosted_client_id?("zimmer")
    assert_not OauthClientIdentity.hosted_client_id?("https://example.com/other.json")
  end

  test "use_for? needs both the opt-in and a configured identity" do
    assert_not OauthClientIdentity.use_for?("cimd")
    with_oauth_client_identity do
      assert OauthClientIdentity.use_for?("cimd")
      assert OauthClientIdentity.use_for?("CIMD")
      assert_not OauthClientIdentity.use_for?(nil)
      assert_not OauthClientIdentity.use_for?("dcr")
    end
  end
end

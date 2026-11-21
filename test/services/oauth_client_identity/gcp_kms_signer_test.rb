# frozen_string_literal: true

require "test_helper"
require "jwt"

# The KMS signer over real HTTP against FakeGcpKms: the access token is minted
# through ParameterStore::ServiceAccount exactly as the Parameter Store resolver
# mints its own, the public key is read once, and every signature is KMS's over
# the digest — verified here by an independent JWT library.
class OauthClientIdentity::GcpKmsSignerTest < ActiveSupport::TestCase
  setup do
    @sa_key = OpenSSL::PKey::RSA.new(2048)
  end

  teardown do
    @kms&.stop
    OauthClientIdentity.reset!
  end

  def env_for(kms, versions: [ kms.version_name ])
    {
      OauthClientIdentity::BASE_URL_ENV => "https://zimmer.example.com",
      OauthClientIdentity::KeySet::KMS_KEY_VERSIONS_ENV => versions.join(","),
      OauthClientIdentity::KeySet::KMS_API_BASE_ENV => kms.api_base,
      OauthClientIdentity::KeySet::TOKEN_URL_ENV => kms.token_url,
      OauthClientIdentity::KeySet::KMS_CREDENTIAL_ENV => Base64.strict_encode64(
        { client_email: "zimmer-secrets-resolver@example.iam.gserviceaccount.com", private_key: @sa_key.to_pem }.to_json
      )
    }
  end

  [ [ "EC P-256", -> { OpenSSL::PKey::EC.generate("prime256v1") }, "ES256" ],
    [ "RSA 2048", -> { OpenSSL::PKey::RSA.new(2048) }, "RS256" ] ].each do |label, make_key, alg|
    test "a #{label} KMS key signs #{alg} assertions the published JWKS verifies" do
      @kms = FakeGcpKms.start(key: make_key.call)
      env = env_for(@kms)

      assert OauthClientIdentity.enabled?(env)
      token = OauthClientIdentity.client_assertion(audience: "https://as.example.com/token", env: env)
      jwks = JWT::JWK::Set.new(JSON.parse(OauthClientIdentity.jwks(env).to_json))
      claims, header = JWT.decode(token, nil, true, algorithms: [ alg ], jwks: jwks)

      assert_equal alg, header["alg"]
      assert_equal "https://zimmer.example.com/oauth-client/metadata.json", claims["iss"]
      assert_equal "https://as.example.com/token", claims["aud"]
    end
  end

  test "the public key is read once per process, and each assertion is one sign call" do
    @kms = FakeGcpKms.start(key: OpenSSL::PKey::EC.generate("prime256v1"))
    env = env_for(@kms)

    2.times { OauthClientIdentity.client_assertion(audience: "https://as.example.com/token", env: env) }
    OauthClientIdentity.jwks(env)

    kms_calls = @kms.paths.reject { |p| p == "POST /token" }
    assert_equal 1, kms_calls.count { |p| p.end_with?("/publicKey") }
    assert_equal 2, kms_calls.count { |p| p.end_with?(":asymmetricSign") }
    assert_equal 1, @kms.paths.count("POST /token"), "the GCP access token is cached"
  end

  test "a refused sign raises Unavailable" do
    @kms = FakeGcpKms.start(key: OpenSSL::PKey::EC.generate("prime256v1"))
    @kms.refuse_sign = true

    error = assert_raises(OauthClientIdentity::Unavailable) do
      OauthClientIdentity.client_assertion(audience: "https://as.example.com/token", env: env_for(@kms))
    end
    assert_match(/answered 403/, error.message)
  end

  test "a signature that does not verify against the key is refused before it is used" do
    @kms = FakeGcpKms.start(key: OpenSSL::PKey::RSA.new(2048))
    @kms.corrupt_signature = true

    error = assert_raises(OauthClientIdentity::Unavailable) do
      OauthClientIdentity.client_assertion(audience: "https://as.example.com/token", env: env_for(@kms))
    end
    assert_match(/does not verify/, error.message)
  end

  test "a service-account credential that is set but unreadable says so" do
    @kms = FakeGcpKms.start(key: OpenSSL::PKey::EC.generate("prime256v1"))
    env = env_for(@kms).merge(OauthClientIdentity::KeySet::KMS_CREDENTIAL_ENV => "not-json")

    error = assert_raises(OauthClientIdentity::Unavailable) do
      OauthClientIdentity.client_assertion(audience: "https://as.example.com/token", env: env)
    end
    assert_match(/is not valid JSON/, error.message)
  end

  test "a key algorithm that is not RS256 or ES256 is refused" do
    @kms = FakeGcpKms.start(key: OpenSSL::PKey::RSA.new(2048), algorithm: "RSA_SIGN_PSS_2048_SHA256")

    assert_raises(OauthClientIdentity::Unavailable) { OauthClientIdentity.jwks(env_for(@kms)) }
  end

  test "with no service account configured it cannot sign, and says which variable is missing" do
    @kms = FakeGcpKms.start(key: OpenSSL::PKey::EC.generate("prime256v1"))
    env = env_for(@kms).except(OauthClientIdentity::KeySet::KMS_CREDENTIAL_ENV)

    error = assert_raises(OauthClientIdentity::Unavailable) do
      OauthClientIdentity.client_assertion(audience: "https://as.example.com/token", env: env)
    end
    assert_includes error.message, OauthClientIdentity::KeySet::KMS_CREDENTIAL_ENV
  end

  test "a version name that is not a cryptoKeyVersion resource is refused up front" do
    assert_raises(OauthClientIdentity::Unavailable) do
      OauthClientIdentity::GcpKmsSigner.new("projects/p/cryptoKeys/k", account: nil)
    end
  end
end

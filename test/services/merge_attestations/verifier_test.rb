# frozen_string_literal: true

require "test_helper"

# What a receiving Zimmer refuses before it believes anything a token says.
class MergeAttestations::VerifierTest < ActiveSupport::TestCase
  PR = "https://github.com/example-org/example-repo/pull/42"

  setup { setup_merge_attestation_env }
  teardown { teardown_merge_attestation_env }

  def verify(token, now: Time.current) = MergeAttestations::Verifier.new(now: now).verify!(token)

  def assert_rejected(code, token, now: Time.current)
    error = assert_raises(MergeAttestations::Rejected) { verify(token, now: now) }
    assert_equal code, error.code, error.message
    error
  end

  test "a token signed by a pinned key, for this audience, verifies and maps the approver" do
    claims = verify(sign_attestation(attestation_claims(PR)))

    assert_equal PR, claims.pr_url
    assert_equal "example-org/example-repo", claims.repo
    assert_equal 42, claims.pr_number
    assert_equal HEAD, claims.head_sha
    assert_equal "tadasant", claims.local_approver
    assert_equal ISSUER, claims.iss
    assert_equal signing_key.kid, claims.kid
  end

  test "the published JWK's kid is its RFC 7638 thumbprint" do
    jwk = signing_key.public_jwk
    assert_equal %w[alg crv kid kty use x], jwk.keys.sort
    assert_equal MergeAttestations::Jws.thumbprint(jwk), jwk["kid"]
    assert_not jwk.key?("d"), "never the private part"
  end

  test "a token signed by any other key is refused, even with the pinned kid" do
    impostor = OpenSSL::PKey.generate_key("ED25519")
    header = { "alg" => "EdDSA", "typ" => MergeAttestations::TYP, "kid" => signing_key.kid }
    assert_rejected "bad_signature", sign_attestation(attestation_claims(PR), header: header, key: impostor)
  end

  test "a payload edited after signing is refused" do
    token = sign_attestation(attestation_claims(PR))
    header, _payload, signature = token.split(".")
    edited = Base64.urlsafe_encode64(attestation_claims(PR, pr_number: 43, sub: PR.sub("42", "43")).to_json, padding: false)
    assert_rejected "bad_signature", [ header, edited, signature ].join(".")
  end

  test "alg none, another alg, and headers that point at keys are refused" do
    claims = attestation_claims(PR)
    b64 = ->(v) { Base64.urlsafe_encode64(v, padding: false) }
    assert_rejected "bad_header", "#{b64.call({ alg: 'none', typ: MergeAttestations::TYP }.to_json)}.#{b64.call(claims.to_json)}."
    assert_rejected "bad_header", sign_attestation(claims, header: { "alg" => "HS256", "typ" => MergeAttestations::TYP, "kid" => signing_key.kid })
    assert_rejected "bad_header", sign_attestation(claims, header: { "alg" => "EdDSA", "typ" => "JWT", "kid" => signing_key.kid })
    %w[jku jwk x5u crit].each do |field|
      header = { "alg" => "EdDSA", "typ" => MergeAttestations::TYP, "kid" => signing_key.kid, field => "https://attacker.example/keys" }
      assert_rejected "bad_header", sign_attestation(claims, header: header)
    end
  end

  test "an issuer or a key this Zimmer did not pin is refused" do
    assert_rejected "untrusted_issuer", sign_attestation(attestation_claims(PR, iss: "https://other.test"))

    trust_issuer(keys: [ MergeAttestations::Jws.jwk(OpenSSL::PKey.generate_key("ED25519")) ])
    assert_rejected "unknown_key", sign_attestation(attestation_claims(PR))

    ENV.delete(MergeAttestations::TRUSTED_ISSUERS_ENV)
    assert_rejected "untrusted_issuer", sign_attestation(attestation_claims(PR))
  end

  test "a token addressed to another Zimmer is refused" do
    assert_rejected "wrong_audience", sign_attestation(attestation_claims(PR, aud: "https://elsewhere.test"))
  end

  test "expired, issued in the future, and over-long tokens are refused" do
    now = Time.current
    assert_rejected "expired", sign_attestation(attestation_claims(PR, now: now - 10.minutes, exp: (now - 1.minute).to_i))
    assert_rejected "not_yet_valid", sign_attestation(attestation_claims(PR, now: now + 5.minutes))
    assert_rejected "lifetime_too_long", sign_attestation(attestation_claims(PR, now: now, exp: (now + 1.hour).to_i))
  end

  test "claims that disagree with the subject, or a SHA that is not one, are refused" do
    assert_rejected "bad_subject", sign_attestation(attestation_claims(PR, pr_number: 7))
    assert_rejected "bad_subject", sign_attestation(attestation_claims(PR, sub: "https://example.com/pull/42"))
    assert_rejected "bad_head_sha", sign_attestation(attestation_claims(PR, head_sha: "main"))
    assert_rejected "missing_claims", sign_attestation(attestation_claims(PR).except("jti"))
    assert_rejected "bad_version", sign_attestation(attestation_claims(PR, ver: 2))
    assert_rejected "bad_channel", sign_attestation(attestation_claims(PR, channel: "follow_up"))
  end

  test "an approver the receiver does not map, or a repo outside its allowlist, is refused" do
    assert_rejected "unknown_approver", sign_attestation(attestation_claims(PR, approver: "someone-else"))

    trust_issuer(approvers: { "tadasant" => "no-such-local-user" })
    assert_rejected "unknown_approver", sign_attestation(attestation_claims(PR))

    trust_issuer(repos: [ "example-org/other" ])
    assert_rejected "repo_not_allowed", sign_attestation(attestation_claims(PR))
  end

  test "garbage is refused as malformed" do
    assert_rejected "malformed", "not-a-token"
    assert_rejected "malformed", "a.b.c"
    assert_rejected "malformed", "x" * (MergeAttestations::MAX_TOKEN_BYTES + 1)
  end
end

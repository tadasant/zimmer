# frozen_string_literal: true

require "openssl"
require "base64"

module OauthClientIdentity
  # One signing key behind the client identity. Subclasses supply the public key,
  # the JWS algorithm and a raw signature over a signing input; this class turns
  # those into a JWK and a compact JWS.
  #
  # Only two algorithms, both universally supported for `private_key_jwt`:
  # RS256 (RSA PKCS#1 v1.5, SHA-256) and ES256 (ECDSA P-256, SHA-256). The header
  # carries `alg`, `typ` and `kid` and nothing else — no `jwk`, `jku` or `x5u` that
  # a verifier might be tempted to honour.
  class Signer
    RS256 = "RS256"
    ES256 = "ES256"
    ALGORITHMS = [ RS256, ES256 ].freeze

    # @return [String] RS256 or ES256
    def alg = raise(NotImplementedError)

    # @return [OpenSSL::PKey::RSA, OpenSSL::PKey::EC] the public key
    def public_key = raise(NotImplementedError)

    # @param signing_input [String] "base64url(header).base64url(claims)"
    # @return [String] the JWS signature bytes (raw R||S for ES256)
    def sign(signing_input) = raise(NotImplementedError)

    # RFC 7638 thumbprint: the key id is derived from the key, so it cannot name
    # a different one and two signers over the same key agree on it.
    def kid
      @kid ||= begin
        jwk = base_jwk
        canonical =
          if jwk["kty"] == "RSA"
            { "e" => jwk["e"], "kty" => "RSA", "n" => jwk["n"] }
          else
            { "crv" => jwk["crv"], "kty" => "EC", "x" => jwk["x"], "y" => jwk["y"] }
          end
        Signer.b64(OpenSSL::Digest::SHA256.digest(canonical.to_json))
      end
    end

    def public_jwk
      base_jwk.merge("kid" => kid, "alg" => alg, "use" => "sig")
    end

    def sign_jwt(claims)
      header = { "alg" => alg, "typ" => "JWT", "kid" => kid }
      input = "#{Signer.b64(header.to_json)}.#{Signer.b64(claims.to_json)}"
      "#{input}.#{Signer.b64(sign(input))}"
    end

    def self.b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

    # An ECDSA signature arrives DER-encoded (from OpenSSL and from KMS); JWS
    # wants the two 32-byte integers concatenated (RFC 7518 §3.4).
    def self.der_to_raw_ecdsa(der, size: 32)
      seq = OpenSSL::ASN1.decode(der)
      seq.value.map { |int| int.value.to_s(2).rjust(size, "\x00".b)[-size, size] }.join
    end

    private

    def base_jwk
      @base_jwk ||=
        case (key = public_key)
        when OpenSSL::PKey::RSA
          { "kty" => "RSA", "n" => Signer.b64(key.n.to_s(2)), "e" => Signer.b64(key.e.to_s(2)) }
        when OpenSSL::PKey::EC
          point = key.public_key.to_octet_string(:uncompressed)
          { "kty" => "EC", "crv" => "P-256", "x" => Signer.b64(point[1, 32]), "y" => Signer.b64(point[33, 32]) }
        else
          raise Unavailable, "unsupported public key type #{key.class}"
        end
    end
  end
end

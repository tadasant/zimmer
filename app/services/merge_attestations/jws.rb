# frozen_string_literal: true

require "openssl"
require "base64"

module MergeAttestations
  # Compact JWS with Ed25519, written out rather than taken from a JWT library,
  # because the whole of what is needed is one algorithm and one shape, and the
  # classic JWT failures are a library honouring something a token asked for:
  # `alg: none`, an HMAC keyed with a public key, a `jku`/`x5u`/`jwk` header
  # pointing at the attacker's own key. Here the header is read for exactly
  # three fields, `alg` must be `EdDSA`, and the key comes from configuration,
  # never from the token.
  module Jws
    module_function

    def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

    def unb64(text)
      raise Rejected.new("malformed", "not base64url") unless text.is_a?(String) && text.match?(/\A[A-Za-z0-9_-]*\z/)

      Base64.urlsafe_decode64(text + ("=" * ((4 - (text.length % 4)) % 4)))
    rescue ArgumentError
      raise Rejected.new("malformed", "not base64url")
    end

    # @param key [OpenSSL::PKey::PKey] an Ed25519 private key
    # @return [String] header.payload.signature
    def sign(claims, key:, kid:)
      header = { "alg" => ALG, "typ" => TYP, "kid" => kid }
      input = "#{b64(header.to_json)}.#{b64(claims.to_json)}"
      "#{input}.#{b64(key.sign(nil, input))}"
    end

    # Split and parse, without verifying. Raises Rejected on any shape problem.
    #
    # @return [Array(Hash, Hash, String, String)] header, claims, signing input, signature bytes
    def decode(token)
      raise Rejected.new("malformed", "the attestation is empty") unless token.is_a?(String) && token.present?
      raise Rejected.new("malformed", "the attestation is too large") if token.bytesize > MAX_TOKEN_BYTES

      parts = token.strip.split(".", -1)
      raise Rejected.new("malformed", "not a compact JWS (three dot-separated parts)") unless parts.size == 3

      header = parse_object(unb64(parts[0]))
      claims = parse_object(unb64(parts[1]))
      [ header, claims, "#{parts[0]}.#{parts[1]}", unb64(parts[2]) ]
    end

    # Whether `signature` is `key`'s Ed25519 signature over `input`.
    def valid_signature?(public_key, signature, input)
      public_key.verify(nil, signature, input)
    rescue OpenSSL::PKey::PKeyError
      false
    end

    # The JWK (RFC 8037) for an Ed25519 public key.
    def jwk(public_key)
      { "kty" => "OKP", "crv" => "Ed25519", "x" => b64(public_key.raw_public_key) }
    end

    # RFC 7638 thumbprint, used as `kid` so a key's id is derived from the key
    # and cannot be pointed at another one.
    def thumbprint(jwk)
      canonical = { "crv" => jwk["crv"], "kty" => jwk["kty"], "x" => jwk["x"] }.to_json
      b64(OpenSSL::Digest::SHA256.digest(canonical))
    end

    # A public key from a configured JWK, or nil when it is not an Ed25519 one.
    def public_key_from_jwk(jwk)
      return nil unless jwk.is_a?(Hash) && jwk["kty"] == "OKP" && jwk["crv"] == "Ed25519"

      raw = unb64(jwk["x"].to_s)
      return nil unless raw.bytesize == 32

      OpenSSL::PKey.new_raw_public_key("ED25519", raw)
    rescue Rejected, OpenSSL::PKey::PKeyError
      nil
    end

    def parse_object(json)
      value = JSON.parse(json)
      raise Rejected.new("malformed", "a JWS part is not a JSON object") unless value.is_a?(Hash)

      value
    rescue JSON::ParserError
      raise Rejected.new("malformed", "a JWS part is not JSON")
    end
  end
end

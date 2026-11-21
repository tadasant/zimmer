# frozen_string_literal: true

module MergeAttestations
  # This Zimmer's Ed25519 signing key, read from MERGE_ATTESTATION_SIGNING_KEY.
  #
  # Two spellings are accepted: a PKCS#8 PEM (`openssl genpkey -algorithm
  # ed25519`), or the 32-byte private seed in base64url. The key is for the
  # Rails process only. Agent CLIs inherit Zimmer's environment minus a
  # denylist, and this variable is on it (CliSpawnEnv#clear_inherited_env_vars),
  # so it is not one `env` away in a session's shell. That is the same boundary
  # that keeps the database password out of a session, and no stronger: agents
  # run in the same container as the same Unix user. See "Threat model" in
  # docs/src/content/docs/auth/merge-attestations.md.
  #
  # Unset means this Zimmer does not issue approvals, and authorize_merge says
  # so instead of failing in some less legible way.
  class SigningKey
    NotConfigured = Class.new(StandardError)

    def self.current
      new(ENV[SIGNING_KEY_ENV])
    end

    def self.configured? = ENV[SIGNING_KEY_ENV].present?

    def initialize(value)
      raise NotConfigured, "#{SIGNING_KEY_ENV} is not set, so this Zimmer cannot sign merge approvals" if value.blank?

      @key = load(value.to_s.strip)
    end

    def private_key = @key

    def public_jwk
      @public_jwk ||= begin
        jwk = Jws.jwk(OpenSSL::PKey.new_raw_public_key("ED25519", @key.raw_public_key))
        jwk.merge("kid" => Jws.thumbprint(jwk), "alg" => ALG, "use" => "sig")
      end
    end

    def kid = public_jwk["kid"]

    def sign(claims) = Jws.sign(claims, key: @key, kid: kid)

    private

    def load(value)
      key =
        if value.include?("BEGIN")
          OpenSSL::PKey.read(value)
        else
          seed = Jws.unb64(value)
          raise NotConfigured, "#{SIGNING_KEY_ENV} must be a PEM or a 32-byte base64url seed" unless seed.bytesize == 32

          OpenSSL::PKey.new_raw_private_key("ED25519", seed)
        end
      raise NotConfigured, "#{SIGNING_KEY_ENV} is not an Ed25519 key" unless key.oid == "ED25519"

      key
    rescue OpenSSL::PKey::PKeyError, Rejected
      raise NotConfigured, "#{SIGNING_KEY_ENV} could not be read as an Ed25519 private key"
    end
  end
end

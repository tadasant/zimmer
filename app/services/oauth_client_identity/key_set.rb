# frozen_string_literal: true

module OauthClientIdentity
  # The keys behind the client identity: the one that signs (`active`, the first
  # listed) and every one that is published in the JWKS (`published`, all of
  # them). Listing two is how a rotation works:
  #
  #   1. add the new key version AFTER the current one — both are published,
  #      the old one still signs;
  #   2. once verifiers have re-read the JWKS, move the new one first — it signs;
  #   3. once no assertion signed by the old key can still be in flight (a
  #      minute; see ASSERTION_LIFETIME), drop it.
  #
  # Two sources, chosen by which variable is set (KMS wins if both are):
  #
  # - ZIMMER_OAUTH_CLIENT_KMS_KEY_VERSIONS — comma-separated KMS cryptoKeyVersion
  #   resource names. Called with the Parameter Store resolver's service account
  #   (KMS_CREDENTIAL_ENV), the one GCP identity a deployed Zimmer already holds.
  # - ZIMMER_OAUTH_CLIENT_SIGNING_KEYS — comma-separated private keys, each PEM or
  #   base64 of PEM. For development, tests and the open-source build.
  class KeySet
    KMS_KEY_VERSIONS_ENV = "ZIMMER_OAUTH_CLIENT_KMS_KEY_VERSIONS"
    LOCAL_KEYS_ENV = "ZIMMER_OAUTH_CLIENT_SIGNING_KEYS"
    KMS_CREDENTIAL_ENV = ParameterStore::Resolver::ENV_KEYS[:key_json]
    KMS_API_BASE_ENV = "ZIMMER_OAUTH_CLIENT_KMS_API_BASE"
    TOKEN_URL_ENV = ParameterStore::Resolver::ENV_KEYS[:token_url]

    MEMO_KEYS = [ KMS_KEY_VERSIONS_ENV, LOCAL_KEYS_ENV, KMS_CREDENTIAL_ENV, KMS_API_BASE_ENV, TOKEN_URL_ENV ].freeze

    @mutex = Mutex.new

    class << self
      def configured?(env = ENV)
        env[KMS_KEY_VERSIONS_ENV].present? || env[LOCAL_KEYS_ENV].present?
      end

      # Memoized per configuration, so a KMS public key and a GCP access token are
      # fetched once per process rather than once per request.
      def from_env(env = ENV)
        fingerprint = MEMO_KEYS.map { |k| env[k].to_s }
        @mutex.synchronize do
          @memo = nil unless @memo && @memo[0] == fingerprint
          @memo ||= [ fingerprint, build(env) ]
          @memo[1]
        end
      end

      def reset!
        @mutex.synchronize { @memo = nil }
      end

      private

      def build(env)
        kms = split(env[KMS_KEY_VERSIONS_ENV])
        if kms.any?
          # A credential that is set but unreadable is reported as exactly that,
          # not as "none configured", which would send someone to the wrong place.
          account, reason = ParameterStore::ServiceAccount.parse(env[KMS_CREDENTIAL_ENV], token_url: env[TOKEN_URL_ENV])
          if account.nil? && env[KMS_CREDENTIAL_ENV].present?
            raise Unavailable, "#{KMS_CREDENTIAL_ENV} #{reason}, so Zimmer cannot call KMS"
          end
          return new(kms.map { |name| GcpKmsSigner.new(name, account: account, api_base: env[KMS_API_BASE_ENV]) })
        end

        new(split(env[LOCAL_KEYS_ENV]).map { |value| LocalKeySigner.new(value) })
      end

      def split(value)
        value.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end

    attr_reader :published

    def initialize(signers)
      @published = signers.freeze
    end

    # @raise [Unavailable] when no key is configured
    def active
      @published.first || raise(Unavailable, "no signing key is configured for Zimmer's OAuth client identity")
    end
  end
end

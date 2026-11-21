# frozen_string_literal: true

module MergeAttestations
  # Which issuers a receiving Zimmer trusts, read from
  # MERGE_ATTESTATION_TRUSTED_ISSUERS: a JSON object keyed by issuer (`iss`).
  #
  #   {
  #     "https://zimmer.example.com": {
  #       "keys": [ { "kty": "OKP", "crv": "Ed25519", "x": "…", "kid": "…" } ],
  #       "approvers": { "alex": "alex" },
  #       "repos": [ "example-org/example-repo" ]
  #     }
  #   }
  #
  # * `keys` — the issuer's public JWKs, pinned. Copied from the issuer's JWKS
  #   (`GET /.well-known/merge-attestation-jwks.json`) by whoever configures the
  #   receiver, and never fetched at verify time: a receiver that fetched keys
  #   would trust whoever answers that URL. Rotation is adding the new key,
  #   then removing the old.
  # * `approvers` — the issuer's user key for a person, mapped to THIS Zimmer's
  #   user key for the same person. An approval from anyone not listed is
  #   refused, so an issuer can vouch only for people the receiver already
  #   knows, and the `attested` HumanMessage is written as the local user.
  # * `repos` — optional allowlist of "owner/repo". Absent means any repo.
  #
  # Unset or empty means this Zimmer trusts nobody and refuses every token.
  class Trust
    Issuer = Data.define(:iss, :keys, :approvers, :repos) do
      def key_for(kid) = keys[kid]
      def local_approver(remote_key) = approvers[remote_key.to_s]
      def repo_allowed?(repo) = repos.nil? || repos.include?(repo)
    end

    def self.current = new(ENV[TRUSTED_ISSUERS_ENV])

    def initialize(json)
      @issuers = parse(json)
    end

    def any? = @issuers.any?

    def issuer(iss) = @issuers[iss.to_s]

    private

    def parse(json)
      return {} if json.blank?

      config = JSON.parse(json)
      return {} unless config.is_a?(Hash)

      config.each_with_object({}) do |(iss, entry), issuers|
        next unless entry.is_a?(Hash)

        keys = Array(entry["keys"]).each_with_object({}) do |jwk, by_kid|
          public_key = Jws.public_key_from_jwk(jwk)
          next unless public_key

          # The kid is the key's own thumbprint, whatever the config says, so a
          # mislabelled entry cannot make one key answer for another.
          by_kid[Jws.thumbprint(jwk)] = public_key
        end
        approvers = entry["approvers"].is_a?(Hash) ? entry["approvers"].transform_keys(&:to_s).transform_values(&:to_s) : {}
        repos = entry.key?("repos") ? Array(entry["repos"]).map(&:to_s) : nil
        issuers[iss.to_s] = Issuer.new(iss: iss.to_s, keys: keys, approvers: approvers, repos: repos)
      end
    rescue JSON::ParserError => e
      Rails.logger.error("[MergeAttestations::Trust] #{TRUSTED_ISSUERS_ENV} is not valid JSON: #{e.message}")
      {}
    end
  end
end

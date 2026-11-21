# frozen_string_literal: true

module MergeAttestations
  # Checks a signed merge approval, and nothing about the world outside it.
  # The Acceptor does the rest (the PR's live head, single use, the holding
  # session). Every refusal is a Rejected with a stable code.
  #
  # The order matters in one place: the signature is checked before any claim
  # is believed. `iss` and `kid` are read unverified only to pick the pinned
  # key to check against, and a token naming an issuer or key that is not
  # pinned is refused there.
  class Verifier
    Claims = Data.define(:raw, :iss, :aud, :jti, :kid, :pr_url, :repo, :pr_number, :head_sha, :approver, :approver_name,
                         :local_approver, :channel, :surface, :read_back, :answer, :approved_at, :issued_at, :expires_at)

    REQUIRED = %w[iss aud sub jti iat exp ver repo pr_number head_sha approver channel read_back answer approved_at].freeze

    def initialize(trust: Trust.current, audience: MergeAttestations.audience, now: Time.current)
      @trust = trust
      @audience = audience
      @now = now
    end

    # @return [Claims]
    # @raise [Rejected]
    def verify!(token)
      header, claims, input, signature = Jws.decode(token)

      reject!("bad_header", "the header must say alg #{ALG} and typ #{TYP}") unless header["alg"] == ALG && header["typ"] == TYP
      # Nothing a token asks for about where its key lives is honoured, and a
      # header naming extensions this verifier does not implement is refused
      # rather than ignored (RFC 7515 4.1.11).
      reject!("bad_header", "the header carries #{(header.keys & %w[crit jku jwk x5u x5c]).join(', ')}") if header.keys.intersect?(%w[crit jku jwk x5u x5c])

      issuer = @trust.issuer(claims["iss"])
      reject!("untrusted_issuer", "this Zimmer does not trust attestations from #{claims['iss'].to_s.truncate(120).inspect}") unless issuer

      public_key = issuer.key_for(header["kid"].to_s)
      reject!("unknown_key", "key #{header['kid'].to_s.truncate(60).inspect} is not one this Zimmer pinned for #{issuer.iss}") unless public_key
      reject!("bad_signature", "the signature does not verify") unless Jws.valid_signature?(public_key, signature, input)

      # From here on the claims are the issuer's.
      missing = REQUIRED.reject { |name| claims[name].present? }
      reject!("missing_claims", "missing #{missing.join(', ')}") if missing.any?
      reject!("bad_version", "version #{claims['ver'].inspect} is not #{VERSION}") unless claims["ver"] == VERSION
      reject!("wrong_audience", "it is addressed to #{claims['aud'].to_s.truncate(120).inspect}, not #{@audience}") unless claims["aud"] == @audience

      issued_at = timestamp!(claims["iat"], "iat")
      expires_at = timestamp!(claims["exp"], "exp")
      reject!("not_yet_valid", "it was issued in the future") if issued_at > @now + CLOCK_SKEW
      reject!("expired", "it expired at #{expires_at.utc.iso8601}") if expires_at <= @now - CLOCK_SKEW
      reject!("lifetime_too_long", "it is valid for longer than #{MAX_LIFETIME.inspect}") if expires_at - issued_at > MAX_LIFETIME

      repo, number = MergeAttestations.parse_pr_url(claims["sub"])
      reject!("bad_subject", "sub is not a GitHub pull request URL") unless repo
      reject!("bad_subject", "repo and pr_number do not match sub") unless claims["repo"] == repo && claims["pr_number"] == number
      reject!("bad_head_sha", "head_sha is not a 40-character commit SHA") unless claims["head_sha"].to_s.match?(SHA)
      reject!("repo_not_allowed", "#{repo} is not a repository #{issuer.iss} may approve merges in here") unless issuer.repo_allowed?(repo)
      reject!("bad_channel", "channel #{claims['channel'].inspect} is not one that mints approvals") unless CHANNELS.include?(claims["channel"])

      local = issuer.local_approver(claims["approver"])
      reject!("unknown_approver", "#{claims['approver'].to_s.truncate(60).inspect} is not a person this Zimmer accepts approvals from via #{issuer.iss}") if local.blank?
      reject!("unknown_approver", "#{local.inspect} is not a user on this Zimmer") unless User.for_key(local)

      Claims.new(
        raw: claims, iss: issuer.iss, aud: claims["aud"], jti: claims["jti"].to_s, kid: header["kid"].to_s,
        pr_url: claims["sub"], repo: repo, pr_number: number, head_sha: claims["head_sha"],
        approver: claims["approver"].to_s, approver_name: claims["approver_name"].to_s.presence, local_approver: local,
        channel: claims["channel"], surface: claims["surface"].to_s.presence, read_back: claims["read_back"].to_s,
        answer: claims["answer"].to_s, approved_at: time_or!(claims["approved_at"]), issued_at: issued_at, expires_at: expires_at
      )
    end

    private

    def reject!(code, message) = raise(Rejected.new(code, "Refused: #{message}."))

    def timestamp!(value, name)
      reject!("malformed", "#{name} is not a number of seconds") unless value.is_a?(Integer)

      Time.zone.at(value)
    end

    def time_or!(value)
      Time.zone.parse(value.to_s) || reject!("malformed", "approved_at is not a time")
    rescue ArgumentError
      reject!("malformed", "approved_at is not a time")
    end
  end
end

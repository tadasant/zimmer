# frozen_string_literal: true

require "net/http"

# Checks the Cloudflare Access assertion in front of Zimmer's iOS app host.
#
# The app reaches Zimmer's machine endpoints through a separate hostname guarded
# by its own Access application (`zimmer/infra/edge/` in the private companion
# repo). Access wants a credential the phone carries on every call: the JWT it
# mints after its own Google login. The app gets one by opening
# `GET /native/access-handoff` in the system sign-in sheet; Access runs its login,
# forwards the request with `Cf-Access-Jwt-Assertion`, and NativeAccessHandoffsController
# hands that assertion back to the app. This class decides whether the assertion
# is one Access minted, before the controller returns it to anyone.
#
# It checks what a relying party checks: an RS256 signature from a key in the
# team's published JWKS, `iss` equal to the team domain, an unexpired `exp`,
# and an `aud` that includes the native app's Access application audience tag
# (Terraform's `native_app_access_aud` output). The audience is required: with
# ZIMMER_NATIVE_ACCESS_AUD unset every assertion is refused, because without it
# a JWT minted for any other Access application of the team would pass.
#
#   ZIMMER_NATIVE_ACCESS_TEAM_DOMAIN  default tadasant.cloudflareaccess.com
#   ZIMMER_NATIVE_ACCESS_AUD          required; not a secret
#
# Both are read through SecretProviders.chain on every call. The JWKS is cached
# for an hour and re-fetched when a token names a key the cache lacks, which is
# how a key rotation is picked up — at most once a minute per process, because
# the route is unauthenticated and any caller can name a key that does not exist.
class NativeAccessAssertion
  TEAM_DOMAIN_KEY = "ZIMMER_NATIVE_ACCESS_TEAM_DOMAIN"
  AUD_KEY = "ZIMMER_NATIVE_ACCESS_AUD"
  DEFAULT_TEAM_DOMAIN = "tadasant.cloudflareaccess.com"
  JWKS_CACHE_TTL = 1.hour
  FORCED_REFETCH_INTERVAL = 1.minute
  FETCH_TIMEOUT = 5

  Result = Data.define(:claims, :refusal) do
    def ok? = refusal.nil?
  end

  class << self
    # Replaced in tests; returns the parsed JWKS document for a team domain.
    attr_writer :jwks_fetcher

    def jwks_fetcher
      @jwks_fetcher ||= ->(team_domain) { fetch_jwks(team_domain) }
    end

    def verify(token)
      new.verify(token)
    end

    # Whether an unknown `kid` may force a fresh fetch now. Process-local on
    # purpose: it bounds the outbound fetches one Puma worker can be made to do,
    # with no shared state to fail open when a cache is down.
    def forced_refetch_allowed?(team, now: Time.current)
      @forced_refetch_mutex ||= Mutex.new
      @forced_refetch_mutex.synchronize do
        @last_forced_refetch ||= {}
        last = @last_forced_refetch[team]
        next false if last && now - last < FORCED_REFETCH_INTERVAL

        @last_forced_refetch[team] = now
        true
      end
    end

    def reset_forced_refetch!
      @last_forced_refetch = {}
    end

    def fetch_jwks(team_domain)
      uri = URI("https://#{team_domain}/cdn-cgi/access/certs")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: FETCH_TIMEOUT, read_timeout: FETCH_TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      raise "JWKS fetch from #{uri} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end

  def verify(token)
    return Result.new(claims: nil, refusal: :missing) if token.blank?

    audience = read(AUD_KEY)
    return Result.new(claims: nil, refusal: :audience_not_configured) if audience.nil?

    team = team_domain
    claims, _header = JWT.decode(token, nil, true, decode_options(team, audience))
    Result.new(claims: claims, refusal: nil)
  rescue JWT::ExpiredSignature
    Result.new(claims: nil, refusal: :expired)
  rescue JWT::InvalidIssuerError
    Result.new(claims: nil, refusal: :wrong_issuer)
  rescue JWT::InvalidAudError
    Result.new(claims: nil, refusal: :wrong_audience)
  rescue JWT::DecodeError => e
    Result.new(claims: nil, refusal: :"invalid (#{e.class.name.demodulize})")
  rescue StandardError => e
    Rails.logger.warn("[native_access] could not verify an assertion: #{e.class}: #{e.message}")
    Result.new(claims: nil, refusal: :unverifiable)
  end

  def team_domain
    read(TEAM_DOMAIN_KEY) || DEFAULT_TEAM_DOMAIN
  end

  private

  def decode_options(team, audience)
    {
      algorithms: [ "RS256" ],
      jwks: jwks_loader(team),
      iss: "https://#{team}",
      verify_iss: true,
      verify_expiration: true,
      # `iat` and `nbf` from Access are its own clock; a few seconds of skew must
      # not refuse a phone that just signed in.
      leeway: 30,
      aud: audience,
      verify_aud: true
    }
  end

  # jwt's loader contract: called with `kid_not_found: true` when the cached set
  # has no key for the token's `kid`, which is when to fetch again.
  def jwks_loader(team)
    cache_key = "native_access:jwks:#{team}"
    lambda do |options|
      Rails.cache.delete(cache_key) if options[:kid_not_found] && self.class.forced_refetch_allowed?(team)
      doc = Rails.cache.fetch(cache_key, expires_in: JWKS_CACHE_TTL) { self.class.jwks_fetcher.call(team) }
      JWT::JWK::Set.new(doc)
    end
  end

  def read(key)
    SecretProviders.chain.get(key).presence
  rescue StandardError => e
    Rails.logger.warn("[native_access] reading #{key} from the secret store failed (#{e.class}); using the process environment")
    ENV[key].presence
  end
end

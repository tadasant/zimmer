# frozen_string_literal: true

require "net/http"

# One line on the CLIs page about the GitHub token map: which tokens are
# published, whose account each belongs to, and when each expires.
#
# Fine-grained personal access tokens expire — at most a year out, often sooner —
# and nothing else in Zimmer would say so before the day it happens. On that day the
# pollers' `gh` calls start failing one owner at a time, which reads as GitHub being
# flaky rather than as a credential that ran out. GitHub answers every API request
# made with a fine-grained token with a `github-authentication-token-expiration`
# header, so one `GET /user` per token says who it is and when it ends.
#
# The line is CliStatusService's `check_details` for `gh`, so it reaches the CLIs
# page, `GET /api/v1/clis` and `get_system_health` without a surface of its own. A
# token within WARN_WITHIN of its expiry is flagged in the line and logged at WARN.
#
# Each token's answer is cached for CACHE_TTL under a digest of the token — never
# the token — so the two-minute refresh job is not two-minute GitHub traffic, and a
# rotation is seen on the next refresh.
module GithubTokenStatus
  WARN_WITHIN = 30.days
  CACHE_TTL = 1.hour
  FAILURE_CACHE_TTL = 10.minutes
  REQUEST_TIMEOUT = 5
  EXPIRATION_HEADER = "github-authentication-token-expiration"
  USER_URI = URI("https://api.github.com/user")

  Probe = Struct.new(:login, :expires_at, :error, keyword_init: true)

  module_function

  # @return [String] one operator-facing line; never contains a token
  def summary(env: ENV, now: Time.current)
    unless GithubTokens.routing?(env: env)
      return "No GitHub token map is seeded: git and gh authenticate with the stored `gh auth login` credential."
    end

    entries = tokens(env).map { |variable, owner| describe(variable, owner, env[variable], now: now) }
    default_owner = GithubTokens.default_owner(env: env)
    prefix = default_owner ? "Default owner #{default_owner}. " : "No default owner set: GH_TOKEN serves every owner without its own token. "
    prefix + entries.join("; ")
  end

  # [[variable, owner label]] for every token published, default first.
  def tokens(env)
    list = []
    list << [ GithubTokens::DEFAULT_VARIABLE, GithubTokens.default_owner(env: env) || "default" ] if env[GithubTokens::DEFAULT_VARIABLE].present?
    GithubTokens.owner_variables(env: env).sort.each { |owner, variable| list << [ variable, owner ] }
    list
  end

  def describe(variable, owner, token, now:)
    probe = probe(token)
    label = "#{variable} (#{owner})"
    return "#{label}: could not verify — #{probe.error}" if probe.error

    parts = [ "#{label}: #{probe.login}" ]
    if probe.expires_at.nil?
      parts << "no expiry reported"
    else
      days = ((probe.expires_at - now) / 1.day).floor
      if probe.expires_at - now < WARN_WITHIN
        Rails.logger.warn "[GithubTokenStatus] #{variable} (#{owner}) expires #{probe.expires_at.to_date} — renew it"
        parts << "EXPIRES IN #{[ days, 0 ].max} DAYS (#{probe.expires_at.to_date}) — renew it"
      else
        parts << "expires #{probe.expires_at.to_date}"
      end
    end
    parts.join(", ")
  end

  def probe(token)
    key = "github_token_status/#{Digest::SHA256.hexdigest(token.to_s)}"
    cached = Rails.cache.read(key)
    return cached if cached

    result = fetch(token)
    Rails.cache.write(key, result, expires_in: result.error ? FAILURE_CACHE_TTL : CACHE_TTL)
    result
  end

  # `GET /user` with the token in the Authorization header — never in an argv.
  def fetch(token)
    request = Net::HTTP::Get.new(USER_URI)
    request["Authorization"] = "Bearer #{token}"
    request["Accept"] = "application/vnd.github+json"
    response = Net::HTTP.start(USER_URI.host, USER_URI.port, use_ssl: true,
                               open_timeout: REQUEST_TIMEOUT, read_timeout: REQUEST_TIMEOUT) do |http|
      http.request(request)
    end
    return Probe.new(error: "GitHub answered HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)

    Probe.new(login: JSON.parse(response.body)["login"], expires_at: parse_expiry(response[EXPIRATION_HEADER]))
  rescue StandardError => e
    Probe.new(error: e.class.name)
  end

  def parse_expiry(value)
    value.present? ? Time.zone.parse(value) : nil
  rescue ArgumentError
    nil
  end
end

# frozen_string_literal: true

# Monitors the TLS certificates of our public, Caddy-managed hosts and alerts as
# expiry approaches — a renewal-health canary.
#
# Background: on 2026-06-11 zimmer.example.com's Let's Encrypt cert expired and took
# the site down because Caddy's DNS-01 auto-renewal had been failing silently for
# ~30 days (it targeted DNSimple after the zone moved to Cloudflare). Nothing
# noticed until the cert actually lapsed. This job is the canary that would have
# caught it weeks earlier: it dials each host, reads the served leaf cert, and
# escalates as the expiry date nears.
#
# Thresholds (a healthy Caddy/Let's Encrypt cert renews with ~30 days of its
# 90-day life remaining, so a correctly-renewing cert's days-remaining never drops
# below ~30 in steady state):
#   <= 14 days  -> .error  (renewal is broken; pages via GlitchTip)
#   <= 21 days  -> .warn   (renewal window has passed without renewing; heads-up)
#   otherwise   -> .info
#
# A host we cannot reach/inspect is logged at .warn (could be transient, or the
# site is genuinely down) without paging — the signal we page on is a cert we can
# read whose expiry is imminent, per the logging philosophy (reserve .error for a
# condition that won't self-resolve and needs a human).
class CertExpiryMonitorJob < ApplicationJob
  queue_as :default

  ERROR_THRESHOLD_DAYS = 14
  WARN_THRESHOLD_DAYS = 21

  # Public hosts whose certs live on an origin we manage with Caddy.
  # zimmer.example.com and staging.zimmer.example.com are the AO UIs (origin Caddy,
  # Cloudflare DNS-01). The obs hosts are the observability droplet that also backs
  # our alerting (GlitchTip) — if its cert lapses we lose the very channel this job
  # alerts through, so it is worth watching too. Override with
  # CERT_EXPIRY_MONITOR_HOSTS (comma-separated) — note reject_own_host still drops
  # this environment's own APP_HOST even from an explicit override list, since the
  # hairpin constraint holds however the list was built.
  #
  # Cross-environment monitoring (see #monitored_hosts): the AO origins are
  # Tailscale-only, and a worker container cannot reach its OWN host's tailscale0
  # address (no NAT hairpin) — but it CAN reach the *other* environment's AO host
  # over the tailnet and the public obs hosts. So each environment drops its own
  # APP_HOST and watches the peer's: staging watches zimmer.example.com, prod watches
  # staging.zimmer.example.com. Both AO certs end up covered, neither self-monitored.
  DEFAULT_HOSTS = %w[
    zimmer.example.com
    staging.zimmer.example.com
    obs.tadasant.com
    glitchtip.obs.tadasant.com
  ].freeze

  # @param hosts [Array<String>, nil] hosts to check; defaults to monitored_hosts
  # @param checker [#check, nil] injectable CertExpiryChecker (for tests)
  def perform(hosts: nil, checker: nil)
    hosts ||= monitored_hosts
    checker ||= CertExpiryChecker.new

    hosts.each { |host| evaluate(checker.check(host)) }
  end

  private

  def evaluate(result)
    logger = StructuredLogger.new({ service: "CertExpiryMonitorJob", host: result.host })

    unless result.ok?
      logger.warn("Could not inspect TLS certificate", error: result.error)
      return
    end

    context = { not_after: result.not_after.utc.iso8601, days_remaining: result.days_remaining }

    if result.days_remaining <= ERROR_THRESHOLD_DAYS
      logger.error(
        "TLS certificate expires in #{result.days_remaining} day(s) (<= #{ERROR_THRESHOLD_DAYS}); auto-renewal appears broken",
        context
      )
    elsif result.days_remaining <= WARN_THRESHOLD_DAYS
      logger.warn(
        "TLS certificate expires in #{result.days_remaining} day(s) (<= #{WARN_THRESHOLD_DAYS}); renewal should have happened by now",
        context
      )
    else
      logger.info("TLS certificate healthy (#{result.days_remaining} days remaining)", context)
    end
  end

  def monitored_hosts
    configured = ENV["CERT_EXPIRY_MONITOR_HOSTS"].to_s.split(",").map(&:strip).reject(&:empty?)
    hosts = configured.presence || DEFAULT_HOSTS
    reject_own_host(hosts)
  end

  # Drop this environment's own AO host: its cert is served by the local Caddy on a
  # Tailscale-only origin, and the worker container cannot reach its own host's
  # tailscale0 address (no NAT hairpin), so a self-check would only ever produce a
  # daily, never-self-resolving "Could not inspect" warn. The peer environment
  # monitors it instead (see DEFAULT_HOSTS comment).
  #
  # APP_HOST may carry a port elsewhere (e.g. "localhost:3000"), and hostnames are
  # case-insensitive, so compare on a normalized host (port stripped, lowercased)
  # rather than raw string equality — otherwise a ported/mixed-case APP_HOST would
  # slip past the filter and self-monitor.
  def reject_own_host(hosts)
    own = normalize_host(ENV["APP_HOST"])
    return hosts if own.empty?

    hosts.reject { |host| normalize_host(host) == own }
  end

  def normalize_host(value)
    value.to_s.strip.split(":", 2).first.to_s.downcase
  end
end

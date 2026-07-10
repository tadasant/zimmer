# frozen_string_literal: true

require "resolv"

# Probes whether the worker's PRIMARY DNS resolver can still resolve public
# hostnames, and drives the "network egress degraded" banner in the UI.
#
# Why probe the primary resolver directly instead of just calling
# Resolv.getaddress? Because Ruby's default resolution (glibc getaddrinfo) falls
# through to the fallback nameservers in resolv.conf when the first one SERVFAILs
# — so a broken primary resolver is invisible to normal resolution. That is
# exactly the failure this exists to catch: when the container's pinned resolver
# (Tailscale MagicDNS via Docker's embedded 127.0.0.11) lost its upstream and
# began SERVFAILing every public domain, serving survived via fallthrough but the
# `claude` login CLI — which does NOT fall through — could no longer reach
# platform.claude.com, and every login silently failed. By querying the first
# nameserver in resolv.conf directly, this reproduces the CLI's real resolution
# path and lights the banner on the same condition, instead of a human noticing
# hours later. See PR #4714 / issue #4712.
#
# The probe result is run through hysteresis and persisted to the shared Redis
# cache by EgressHealthCheckJob; the layout banner reads it via `.status`.
class EgressHealthCheck
  # Shared (Redis) cache key holding the displayed status hash. Read by the web
  # process for the banner, written by the worker's cron job.
  CACHE_KEY = "network_egress_health"
  # TTL far longer than the 1-minute cron so the banner (and the failure streak it
  # rides on) survives a long tick gap mid-incident — a deploy that recreates the
  # worker, or the shared :pollers scheduler being briefly starved — without
  # silently clearing and re-arming hysteresis. A status left behind by a fully
  # stopped worker still ages out within the hour. Matches SystemHealthMonitorJob's
  # streak TTL.
  CACHE_TTL = 1.hour

  # Public hostnames AO's agents must reach: the OAuth login-exchange host that
  # broke, plus the serving API host. Only ALL of them failing marks egress
  # degraded, so a genuine single-domain upstream blip never trips the banner —
  # a broken resolver fails every public lookup at once.
  CHECK_HOSTS = %w[api.anthropic.com platform.claude.com].freeze
  # Retries per host within one probe, to absorb a dropped UDP packet.
  ATTEMPTS_PER_HOST = 2
  # Per-attempt DNS timeout. Short: the resolver is local (the embedded forwarder),
  # so a healthy answer returns in milliseconds and a SERVFAIL comes back fast.
  DNS_TIMEOUT_SECONDS = 2
  # Consecutive degraded probes required before the banner shows. One bad tick
  # must not flash a scary banner; a real egress/DNS outage persists for minutes.
  DISPLAY_THRESHOLD = 2

  Result = Data.define(:healthy, :detail, :resolver)

  # @param resolver [String, :auto, nil] nameserver IP to probe; :auto reads the
  #   first `nameserver` from /etc/resolv.conf (the container's primary resolver).
  # @param hosts [Array<String>] public hostnames to resolve.
  # @param probe [#call, nil] injectable resolver for tests: `->(host, resolver) { bool }`.
  def initialize(resolver: :auto, hosts: CHECK_HOSTS, probe: nil)
    @resolver = resolver == :auto ? primary_nameserver : resolver
    @hosts = hosts
    @probe = probe
  end

  # Resolve each host through the primary resolver. Healthy when at least one
  # resolves (a broken resolver fails them all); degraded when none do.
  # @return [Result]
  def probe
    if @resolver.blank?
      return Result.new(healthy: true, detail: "no resolver configured; probe skipped", resolver: nil)
    end

    resolved = @hosts.select { |host| resolves?(host) }
    if resolved.any?
      Result.new(healthy: true, detail: "resolved #{resolved.join(", ")} via #{@resolver}", resolver: @resolver)
    else
      Result.new(
        healthy: false,
        detail: "primary resolver #{@resolver} could not resolve #{@hosts.join(", ")}",
        resolver: @resolver
      )
    end
  end

  class << self
    # The persisted, hysteresis-applied status hash (string keys), or nil when no
    # probe has run yet or the cache can't be read. Never raises — a Redis hiccup
    # must not break page rendering.
    def status
      Rails.cache.read(CACHE_KEY)
    rescue StandardError
      nil
    end

    def degraded?
      status&.dig("status") == "degraded"
    end

    # Apply hysteresis to a raw probe Result and persist the displayed status.
    # A degraded probe only flips the displayed status to "degraded" once it has
    # been seen on DISPLAY_THRESHOLD consecutive runs; any healthy probe clears
    # the streak immediately. Returns the stored hash.
    def record(result, previous: status, now: Time.current)
      prev = previous || {}

      stored =
        if result.healthy
          build(status: "ok", result: result, consecutive_failures: 0, degraded_since: nil, now: now)
        else
          failures = prev.fetch("consecutive_failures", 0).to_i + 1
          degraded = failures >= DISPLAY_THRESHOLD
          build(
            status: degraded ? "degraded" : "ok",
            result: result,
            consecutive_failures: failures,
            degraded_since: degraded ? (prev["degraded_since"] || now.iso8601) : nil,
            now: now
          )
        end

      Rails.cache.write(CACHE_KEY, stored, expires_in: CACHE_TTL)
      stored
    end

    private

    def build(status:, result:, consecutive_failures:, degraded_since:, now:)
      {
        "status" => status,
        "healthy" => result.healthy,
        "detail" => result.detail,
        "resolver" => result.resolver,
        "consecutive_failures" => consecutive_failures,
        "degraded_since" => degraded_since,
        "checked_at" => now.iso8601
      }
    end
  end

  private

  def resolves?(host)
    ATTEMPTS_PER_HOST.times do
      return true if run_probe(host)
    end
    false
  end

  def run_probe(host)
    return @probe.call(host, @resolver) if @probe

    dns = Resolv::DNS.new(nameserver: [ @resolver ])
    dns.timeouts = DNS_TIMEOUT_SECONDS
    dns.getaddress(host)
    true
  rescue Resolv::ResolvError, Resolv::ResolvTimeout, Timeout::Error, SystemCallError, SocketError, IOError
    false
  ensure
    dns&.close
  end

  # First `nameserver` line in resolv.conf — the container's primary resolver,
  # which is the one pinned via the deploy config's `dns:` and the one whose
  # health the login CLI actually depends on. nil when the file is missing or
  # lists no nameserver (e.g. some local dev setups), which the probe treats as
  # "nothing to check" rather than a failure.
  def primary_nameserver
    File.foreach("/etc/resolv.conf") do |line|
      return Regexp.last_match(1) if line =~ /\A\s*nameserver\s+(\S+)/
    end
    nil
  rescue SystemCallError
    nil
  end
end

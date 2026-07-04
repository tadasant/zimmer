# frozen_string_literal: true

require "socket"
require "openssl"
require "timeout"

# Inspects the TLS certificate served by a host:port and reports how many days
# remain until it expires.
#
# This is the I/O half of the cert-renewal canary (CertExpiryMonitorJob holds the
# alerting policy). It exists because of the 2026-06-11 zimmer.example.com outage:
# Caddy's DNS-01 auto-renewal had been failing silently for ~30 days (it targeted
# DNSimple after the zone moved to Cloudflare), and nothing noticed until the cert
# actually expired and took the site down.
#
# The check connects with SNI and deliberately does NOT verify the chain — an
# expired or otherwise untrusted cert still completes enough of the handshake for
# us to read its notAfter and surface a small/negative days-remaining, which is
# precisely the condition we most want to alert on.
class CertExpiryChecker
  DEFAULT_PORT = 443
  DEFAULT_TIMEOUT = 10 # seconds

  Result = Struct.new(:host, :port, :not_after, :days_remaining, :error, keyword_init: true) do
    # True when the certificate was read successfully (regardless of how close to
    # expiry it is). False means the host could not be reached/inspected.
    def ok?
      error.nil?
    end
  end

  def initialize(timeout: DEFAULT_TIMEOUT, clock: -> { Time.now.utc })
    @timeout = timeout
    @clock = clock
  end

  # Connect to host:port, read the served leaf certificate, and compute how many
  # whole days remain until it expires. Network/TLS failures are captured in the
  # returned Result#error rather than raised, so a single unreachable host does
  # not abort a multi-host sweep.
  #
  # @return [Result]
  def check(host, port: DEFAULT_PORT)
    not_after = fetch_not_after(host, port)
    seconds_left = not_after - @clock.call
    days_remaining = (seconds_left / 86_400.0).floor
    Result.new(host: host, port: port, not_after: not_after, days_remaining: days_remaining, error: nil)
  rescue => e
    Result.new(host: host, port: port, not_after: nil, days_remaining: nil, error: "#{e.class}: #{e.message}")
  end

  private

  def fetch_not_after(host, port)
    socket = Socket.tcp(host, port, connect_timeout: @timeout)
    begin
      ssl = OpenSSL::SSL::SSLSocket.new(socket, ssl_context)
      ssl.hostname = host # SNI — required for hosts that serve multiple certs
      Timeout.timeout(@timeout) { ssl.connect }
      ssl.peer_cert.not_after
    ensure
      # Close in its own rescue so a failure closing the SSL wrapper still lets us
      # release the underlying socket — the begin starts at Socket.tcp so the
      # socket is closed even if SSLSocket setup raises.
      begin
        ssl&.close
      ensure
        socket.close
      end
    end
  end

  def ssl_context
    ctx = OpenSSL::SSL::SSLContext.new
    # Read the served cert even when it is expired/untrusted — the expiry we are
    # reporting on is exactly what would otherwise fail verification.
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ctx
  end
end

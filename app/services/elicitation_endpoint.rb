# frozen_string_literal: true

require "net/http"

# Where an MCP server sends an approval request, and whether it can get there.
#
# MCP servers that gate a sensitive action (a 1Password reveal, a destructive
# write) behind human approval use the pulsemcp fallback-elicitation protocol:
# POST the request to an HTTP endpoint, then poll it for the answer. The
# @pulsemcp/mcp-elicitation client reads that endpoint from the environment.
#
# Zimmer used to set only ELICITATION_SESSION_ID, leaving the client on its own
# default — `http://zimmer/api/v1/elicitations`, a Tailscale MagicDNS name that
# resolves on the host but not inside the container agents run in. Every POST got
# connection-refused, the client fell back to "no approval", and the server
# returned `[REDACTED]`. From the agent's side that is indistinguishable from a
# denial: a silent, fail-closed gate that invites working around it. Naming the
# endpoint explicitly, from the same AppUrl the session URLs come from, is the fix.
#
# The probe is the second half. A gate that breaks again must say so instead of
# reverting to silent redaction, so ElicitationEndpointHealthCheckJob checks
# reachability on a cron and OrchestratorSystemPromptBuilder tells the agent when
# the answer is "no" — before the agent ever sees a redacted value.
class ElicitationEndpoint
  PATH = "/api/v1/elicitations"

  # Shared (Redis) cache key holding the last probe result.
  CACHE_KEY = "elicitation_endpoint_health"
  # Comfortably longer than the 5-minute cron, so one skipped tick doesn't drop the
  # status back to "unknown" (which suppresses the warning) mid-incident.
  CACHE_TTL = 30.minutes

  # A request_id no elicitation will ever have. The probe wants a routable 404 —
  # proof the request reached Rails — not a side effect, so it reads rather than
  # creates.
  PROBE_REQUEST_ID = "zimmer-reachability-probe"
  PROBE_TIMEOUT_SECONDS = 5

  Result = Data.define(:reachable, :detail, :url)

  class << self
    # The collection URL MCP servers POST an approval request to.
    def url
      "#{AppUrl.base_url.to_s.chomp('/')}#{PATH}"
    end

    # Environment for a spawned agent process, inherited by the stdio MCP servers
    # it starts. Session-less callers get the URL but no session tag; the API logs
    # a warning when a request arrives without one.
    #
    # Two variables it deliberately does NOT set:
    #
    # ELICITATION_POLL_URL — the create response carries
    # `_meta["com.pulsemcp/poll-url"]`, built by Rails from the request it just
    # received, so the poll URL follows the request URL automatically.
    #
    # ELICITATION_ENABLED — whether a server gates a given action stays that server's
    # decision. Session #867's server was already attempting the POST without it, so
    # the defect was the address, not the enablement; forcing it on would newly block
    # sessions on approvals across every server at once, which is a rollout, not a fix.
    #
    # @param session_id [Integer, String, nil]
    # @return [Hash{String=>String}]
    def spawn_env(session_id: nil)
      env = { "ELICITATION_REQUEST_URL" => url }
      env["ELICITATION_SESSION_ID"] = session_id.to_s if session_id.present?
      env
    end

    # Can this host reach the endpoint it just told MCP servers to use?
    #
    # Any HTTP response counts as reachable — a 404 for the probe id is the
    # expected answer and proves the request was routed to Rails. Only a transport
    # failure (DNS, refused connection, TLS, timeout) is a broken gate.
    #
    # @return [Result]
    def probe
      probe_url = "#{url}/#{PROBE_REQUEST_ID}"
      uri = URI.parse(probe_url)
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: PROBE_TIMEOUT_SECONDS,
        read_timeout: PROBE_TIMEOUT_SECONDS
      ) { |http| http.request(Net::HTTP::Get.new(uri)) }

      Result.new(reachable: true, detail: "HTTP #{response.code} from #{probe_url}", url: url)
    rescue StandardError => e
      Result.new(reachable: false, detail: "#{e.class}: #{e.message}", url: url)
    end

    # Persist a probe result. Never raises — a Redis hiccup must not fail the job.
    # Always returns a hash, so a caller reading stored["reachable"] cannot trip over
    # a nil from a failure that happened before the hash was even built.
    def record(result, now: Time.current)
      stored = {
        "reachable" => result.reachable,
        "detail" => result.detail,
        "url" => result.url,
        "checked_at" => now.iso8601
      }
      Rails.cache.write(CACHE_KEY, stored, expires_in: CACHE_TTL)
      stored
    rescue StandardError => e
      Rails.logger.warn "[ElicitationEndpoint] Failed to cache probe result: #{e.message}"
      stored || { "reachable" => result.reachable, "detail" => result.detail, "url" => result.url }
    end

    # The last recorded probe result, or nil when none has run.
    def status
      Rails.cache.read(CACHE_KEY)
    rescue StandardError
      nil
    end

    # True only when a probe has actually observed the endpoint to be unreachable.
    # "Never probed" is not "broken" — it must not produce a warning that would
    # teach agents to distrust a working gate.
    def unreachable?
      status&.dig("reachable") == false
    end
  end
end

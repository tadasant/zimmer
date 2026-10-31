# frozen_string_literal: true

# Holds a recurring schedule back until the catalog MCP servers it names in `require_reachable`
# can be reached, so a schedule whose work needs a machine that is often off — a laptop serving
# an MCP server through strad — fires when that machine is up instead of spawning a session to
# discover that it is not.
#
# ScheduleTriggerJob asks #check only for a condition that is already due. A closed gate leaves
# the condition due and spawns nothing, so a slot the machine slept through is not lost: it
# fires the first time the gate opens, and a second slot arriving in the meantime is the same one
# pending fire, not two (ScheduleTriggerJob coalesces gated siblings when one of them fires).
#
# The check is deterministic and needs no session: one `tools/list` per server through the same
# endpoint and credentials a session gets. That is deliberately the cheapest call there is — it
# runs no tool, so a server behind a consent gate (strad-hostd's `request_control`) shows nothing
# on the machine it probes.
#
# A server counts as reachable when it lists a real tool. Strad answers `tools/list` for a slug
# whose host is offline with a single placeholder, `<slug>__troubleshoot_host`, instead of an
# error — so "the list came back" is not the test, "the list holds something other than that
# placeholder" is.
#
# The gate opens only after every server has been reachable for the condition's
# `reachable_dwell_minutes` in a row. A lid opened for a minute, or a brief dark wake, should not
# start a session that finds the machine asleep again by the time it runs.
class ScheduleReachabilityGate
  Result = Data.define(:open, :reason)

  # strad's stand-in tool for a slug whose host it cannot reach.
  PLACEHOLDER_TOOL = "troubleshoot_host"

  # One probe per server serves every gated condition in a tick. Shorter than the job's
  # one-minute cadence, so each tick sees a fresh answer.
  PROBE_CACHE_TTL = 50.seconds

  # ScheduleTriggerJob fires every schedule in the deployment, wakes included, one condition at a
  # time. A probe is bounded well under the client's defaults so an unreachable host cannot hold
  # the rest of the tick for long.
  OPEN_TIMEOUT_SECONDS = 3
  READ_TIMEOUT_SECONDS = 8

  # The gate only looks while a condition is due. A record older than this was written during an
  # earlier due period, and says nothing about whether the server has been up since.
  STALE_AFTER = 3.minutes

  MAX_REASON_CHARS = 300

  class << self
    # @param condition [TriggerCondition] a due, gated schedule condition
    # @return [Result]
    def check(condition, now: Time.current)
      servers = condition.schedule_require_reachable
      return Result.new(open: true, reason: nil) if servers.empty?

      unreachable = servers.filter_map do |name|
        probe = probe(name)
        "#{name}: #{probe['reason']}" unless probe["reachable"]
      end

      previous = condition.schedule_reachability_state
      fresh = fresh?(previous, now)

      result, state = if unreachable.any?
        reason = unreachable.join("; ").truncate(MAX_REASON_CHARS)
        [
          Result.new(open: false, reason: "unreachable — #{reason}"),
          {
            "reachable_since" => nil,
            "unreachable_since" => (fresh && previous["unreachable_since"]) || now.iso8601,
            "last_checked_at" => now.iso8601,
            "last_error" => reason
          }
        ]
      else
        since = (fresh && parse_time(previous["reachable_since"])) || now
        dwell = condition.schedule_reachable_dwell_minutes.minutes
        open = now - since >= dwell
        [
          Result.new(open: open, reason: open ? nil : "reachable since #{since.iso8601}; waiting out the #{condition.schedule_reachable_dwell_minutes} min dwell"),
          {
            "reachable_since" => since.iso8601,
            "unreachable_since" => nil,
            "last_checked_at" => now.iso8601,
            "last_error" => nil
          }
        ]
      end

      record!(condition, state)
      result
    end

    # @return [Hash] `{"reachable" => Boolean, "reason" => String or nil}`
    def probe(name)
      Rails.cache.fetch(cache_key(name), expires_in: PROBE_CACHE_TTL) { probe_now(name) }
    end

    private

    def probe_now(name)
      server = ServersConfig.find(name.to_s)
      return unreachable("not in the MCP server catalog") if server.nil?
      return unreachable("a #{server.type} server cannot be probed") unless server.remote?

      endpoint = McpServerEndpoint.new(server)
      client = McpApps::Client.new(
        url: endpoint.url, headers: endpoint.headers,
        open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS
      )
      names = client.tools_list.filter_map { |tool| tool["name"].to_s if tool.is_a?(Hash) }
      real = names.reject { |tool| tool == PLACEHOLDER_TOOL || tool.end_with?("__#{PLACEHOLDER_TOOL}") }

      return { "reachable" => true, "reason" => nil } if real.any?

      unreachable(names.any? ? "only strad's #{PLACEHOLDER_TOOL} is listed, so its host is offline" : "it lists no tools")
    rescue McpApps::Client::Error, McpServerEndpoint::UnresolvableError => e
      unreachable(e.message)
    end

    def unreachable(reason)
      { "reachable" => false, "reason" => reason }
    end

    def fresh?(state, now)
      checked = parse_time(state["last_checked_at"])
      checked.present? && now - checked <= STALE_AFTER
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    # Written without validations or callbacks: this is the gate's own bookkeeping, it runs every
    # minute while a slot is pending, and the user-facing keys beside it are untouched.
    def record!(condition, state)
      configuration = condition.configuration.merge("reachability" => state)
      condition.update_column(:configuration, configuration)
    end

    def cache_key(name)
      "schedule_reachability_gate:probe:#{name}"
    end
  end
end

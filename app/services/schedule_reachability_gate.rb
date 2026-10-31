# frozen_string_literal: true

# Holds a recurring schedule back until the catalog MCP servers it names in `require_reachable`
# can be reached, so a schedule whose work needs a machine that is often off — a laptop serving
# an MCP server through strad — fires when that machine is up instead of spawning a session to
# discover that it is not.
#
# The work is split in two so that a slow or hung host can never delay anything else:
#
# - #observe! is called by ScheduleReachabilityProbeJob, once a minute, for every gated condition
#   on an enabled trigger. It probes the servers and records what it saw under
#   `configuration["reachability"]`.
# - #check is called by ScheduleTriggerJob for a condition that is due. It only reads that record
#   — no network — so the job that also delivers session wakes never waits on a probe.
#
# A closed gate leaves the condition due and spawns nothing. TriggerCondition#schedule_due? keeps a
# gated daily or weekly slot due until it is fired for, so a slot the machine slept through fires
# the first time the gate opens; ScheduleTriggerJob coalesces gated siblings due at the same time.
#
# The probe is deterministic and needs no session: one `tools/list` per server through the same
# endpoint and credentials a session gets. It runs no tool, so a server behind a consent gate
# (strad-hostd's `request_control`) shows nothing on the machine it probes.
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

  # One probe per server serves every gated condition naming it in a pass. Shorter than the probe
  # job's one-minute cadence, so each pass sees a fresh answer.
  PROBE_CACHE_TTL = 50.seconds

  OPEN_TIMEOUT_SECONDS = 3
  READ_TIMEOUT_SECONDS = 8

  # A record older than this means the probe job has not been running, and says nothing about the
  # server since. #check treats it as closed; #observe! restarts the dwell from it.
  STALE_AFTER = 3.minutes

  MAX_REASON_CHARS = 300

  class << self
    # Read-only: whether a due, gated condition may fire now, from the last observation.
    #
    # @param condition [TriggerCondition]
    # @return [Result]
    def check(condition, now: Time.current)
      return Result.new(open: true, reason: nil) unless condition.reachability_gated?

      state = condition.schedule_reachability_state
      checked = parse_time(state["last_checked_at"])
      return Result.new(open: false, reason: "not probed yet") if checked.nil?
      return Result.new(open: false, reason: "last probed at #{checked.iso8601}, which is stale") if now - checked > STALE_AFTER

      since = parse_time(state["reachable_since"])
      return Result.new(open: false, reason: "unreachable since #{state['unreachable_since']} — #{state['last_error']}") if since.nil?

      dwell = condition.schedule_reachable_dwell_minutes
      return Result.new(open: true, reason: nil) if now - since >= dwell.minutes

      Result.new(open: false, reason: "reachable since #{since.iso8601}; waiting out the #{dwell} min dwell")
    end

    # Probe the condition's servers and record what was seen.
    #
    # @param condition [TriggerCondition] a gated schedule condition
    # @return [Hash] the record written
    def observe!(condition, now: Time.current)
      unreachable = condition.schedule_require_reachable.filter_map do |name|
        probe = probe(name)
        "#{name}: #{probe['reason']}" unless probe["reachable"]
      end

      previous = condition.schedule_reachability_state
      checked = parse_time(previous["last_checked_at"])
      fresh = checked.present? && now - checked <= STALE_AFTER

      state = if unreachable.any?
        {
          "reachable_since" => nil,
          "unreachable_since" => (fresh && previous["unreachable_since"]) || now.iso8601,
          "last_checked_at" => now.iso8601,
          "last_error" => unreachable.join("; ").truncate(MAX_REASON_CHARS)
        }
      else
        {
          "reachable_since" => ((fresh && parse_time(previous["reachable_since"])) || now).iso8601,
          "unreachable_since" => nil,
          "last_checked_at" => now.iso8601,
          "last_error" => nil
        }
      end

      record!(condition, state)
      state
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

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    # Only the gate's own key is written, in place, so an edit to the condition that lands while
    # a probe is in flight is not reverted. No validations or callbacks: this is bookkeeping.
    def record!(condition, state)
      TriggerCondition.where(id: condition.id).update_all(
        [ "configuration = jsonb_set(configuration, '{reachability}', ?::jsonb)", state.to_json ]
      )
      condition.configuration = condition.configuration.merge("reachability" => state)
      condition.clear_changes_information
    end

    def cache_key(name)
      "schedule_reachability_gate:probe:#{name}"
    end
  end
end

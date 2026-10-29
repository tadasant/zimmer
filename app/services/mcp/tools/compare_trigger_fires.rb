# frozen_string_literal: true

module Mcp
  module Tools
    # Lines up the external events two triggers fired on, by the event's identity. Built for a
    # parity test — an `mcp_event` trigger shadowing a Slack trigger — but it compares any two
    # triggers whose conditions record TriggerEventClaim rows.
    class CompareTriggerFires < Tool
      tool_name "compare_trigger_fires"

      # Claims are deleted after TriggerEventClaim::RETENTION, so nothing older can be compared.
      DEFAULT_WINDOW = TriggerEventClaim::RETENTION

      # How long an event one trigger fired on may wait for the other before it counts as missed.
      # Both pollers run once a minute and a strad deploy can hold one back a few more.
      DEFAULT_GRACE_MINUTES = 15

      MAX_RECENT = 200

      description <<~DESC
        Compare which external events two triggers fired on — for a parity test, where a new trigger
        (say an `mcp_event` condition on strad's Slack server) shadows an existing one (a Slack
        trigger) and should fire on exactly the same messages.

        Every fire of a Slack or MCP event condition records a claim per event (a GitHub condition
        records one only while its webhook is on). A Slack message burst control or a pending
        session stopped records nothing, while an MCP event condition retries such an event, so a
        few `only_b` rows can be by design: read the sessions before calling one a miss. This tool
        joins the two triggers' claims on the event's identity — an MCP event's
        `mcp:<server>:<eventId>` with the server prefix stripped, so strad's
        `slack:<channel>:<ts>` lines up with the Slack poller's — and reports, since `since`:

        - `matched`: events both triggers fired on, with the time between the two fires;
        - `only_a` / `only_b`: events one fired on and the other did not, once older than
          `grace_minutes` (younger ones are `pending` — the other poller may not have run yet).

        `recent` lists the newest events either trigger fired on (`limit`, default 30), each with
        its status, the sessions both fires produced, and when. Claims are kept 30 days, so that is
        the furthest back this can see.

        Read-only. It decides nothing; whether a miss matters is for the reader to judge from the
        sessions it names.
      DESC

      input_schema({
        type: "object",
        properties: {
          trigger_a_id: { type: "integer", description: "The first trigger (e.g. the original)." },
          trigger_b_id: { type: "integer", description: "The second trigger (e.g. the shadow)." },
          since: { type: "string", description: "ISO 8601 time to compare from. Default: 30 days ago. A shadow's parity starts when the shadow was created, so pass that." },
          grace_minutes: { type: "integer", description: "How long an event may wait for the other trigger before it counts as missed. Default: 15." },
          limit: { type: "integer", description: "How many of the newest events to list in `recent`. Default 30, at most 200." }
        },
        required: %w[trigger_a_id trigger_b_id]
      })

      def call(args)
        trigger_a = find_trigger(args["trigger_a_id"])
        trigger_b = find_trigger(args["trigger_b_id"])
        since = parse_since(args["since"])
        grace = (args["grace_minutes"].presence || DEFAULT_GRACE_MINUTES).to_i.clamp(0, 24 * 60).minutes
        limit = (args["limit"].presence || 30).to_i.clamp(1, MAX_RECENT)

        a = fires_by_event(trigger_a, since)
        b = fires_by_event(trigger_b, since)
        horizon = Time.current - grace

        rows = (a.keys | b.keys).map do |key|
          fire_a = a[key]
          fire_b = b[key]
          first = [ fire_a&.dig(:at), fire_b&.dig(:at) ].compact.min
          status = if fire_a && fire_b then "matched"
          elsif first > horizon then "pending"
          elsif fire_a then "only_a"
          else "only_b"
          end
          { event: key, status: status, first_fired_at: first, a: fire_a, b: fire_b }
        end

        counts = rows.group_by { |row| row[:status] }.transform_values(&:size)
        {
          trigger_a: { id: trigger_a.id, name: trigger_a.name },
          trigger_b: { id: trigger_b.id, name: trigger_b.name },
          since: since.iso8601,
          grace_minutes: grace.in_minutes.to_i,
          counts: { matched: counts.fetch("matched", 0), only_a: counts.fetch("only_a", 0),
                    only_b: counts.fetch("only_b", 0), pending: counts.fetch("pending", 0) },
          recent: rows.sort_by { |row| row[:first_fired_at] }.last(limit).reverse.map { |row| present(row) }
        }
      end

      private

      def find_trigger(id)
        raise ToolError, "Missing required parameter: trigger ids" if id.blank?

        trigger = Trigger.find_by(id: id.to_i)
        # A restricted connection compares only triggers on the roots it may act on, as
        # search_triggers shows it only those; "not found" avoids confirming the rest exist.
        if trigger.nil? || (context.restricted? && !context.allowed_agent_roots.include?(trigger.agent_root_name))
          raise ToolError, "Trigger not found: #{id}"
        end

        trigger
      end

      def parse_since(value)
        return DEFAULT_WINDOW.ago if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        raise ToolError, "since must be an ISO 8601 time, e.g. 2026-10-29T15:00:00Z"
      end

      # natural event key => { at:, session_id:, via: } for the trigger's earliest claim on it.
      def fires_by_event(trigger, since)
        TriggerEventClaim
          .where(trigger_condition_id: trigger.trigger_conditions.select(:id), created_at: since..)
          .order(:created_at)
          .pluck(:event_key, :created_at, :session_id, :claimed_via)
          .each_with_object({}) do |(key, at, session_id, via), fires|
            fires[TriggerEventClaim.natural_key(key)] ||= { at: at, session_id: session_id, via: via }
          end
      end

      def present(row)
        a = row[:a]
        b = row[:b]
        {
          event: row[:event],
          status: row[:status],
          a: a && { fired_at: a[:at].iso8601, session_id: a[:session_id] },
          b: b && { fired_at: b[:at].iso8601, session_id: b[:session_id] },
          seconds_apart: a && b ? (b[:at] - a[:at]).round : nil
        }
      end
    end
  end
end

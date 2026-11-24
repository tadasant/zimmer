# frozen_string_literal: true

module SessionEvents
  # `events/poll` over the SessionEvent log.
  #
  # A cursor is a position in (txid, id) order plus when it was issued. Only rows
  # whose transaction is older than every transaction still open are served, so a
  # position that has been passed can never gain a row behind it, and an answer
  # with nothing in it still moves the cursor up to that line.
  #
  # `truncated` is set when the cursor is older than the log keeps (RETENTION):
  # what is still kept is served from there. It is also set when the cursor names a
  # position past the database's newest transaction — a database restored elsewhere
  # counts transactions again from a lower number — which restarts it from now, and
  # when `maxAgeMs` starts later than the cursor does.
  class Feed
    DEFAULT_MAX = 50
    LIMIT_MAX = 200
    MAX_AGE_MS = 366.days.in_milliseconds
    NEXT_POLL_MS = 5_000
    CURSOR = /\A1\.(\d{1,19})\.(\d{1,19})\.(\d{1,12})\z/

    # @attr code [Symbol] the extension's error name (McpEvents::ERROR_CODES)
    class Refused < StandardError
      attr_reader :code, :data

      def initialize(code, message, data = {})
        super(message)
        @code = code
        @data = data
      end
    end

    # @param readable [Proc] given an agent root, whether this caller may read its sessions
    def self.poll(params, readable:, now: Time.current) = new(params, readable: readable, now: now).poll

    def initialize(params, readable:, now:)
      @params = params.is_a?(Hash) ? params.deep_stringify_keys : {}
      @readable = readable
      @now = now
    end

    # @return [Hash] the SEP's poll result
    def poll
      name = @params["name"]
      descriptor = SessionEvents.descriptors.find { |entry| entry[:name] == name }
      raise Refused.new(:not_found, "No event type named #{name.to_s.truncate(100).inspect}", { kind: "event" }) unless descriptor

      arguments = arguments_for(descriptor)
      limit = max_events
      horizon = visible_horizon
      return result([], horizon) if @params["cursor"].nil?

      position, issued_at = read_cursor
      unknown = position.first > horizon.first
      truncated = unknown || issued_at < @now - SessionEvent::RETENTION
      position = horizon if unknown

      floor = age_floor
      scope = filtered(descriptor[:name], arguments)
        .where("session_events.txid < ?", horizon.first)
        .where("(session_events.txid, session_events.id) > (?, ?)", *position)
      if floor
        truncated ||= scope.where(occurred_at: ...floor).exists?
        scope = scope.where(occurred_at: floor..)
      end

      rows = scope.order(:txid, :id).limit(limit + 1).to_a
      has_more = rows.size > limit
      rows = rows.first(limit)
      reached = has_more ? [ rows.last.txid, rows.last.id ] : horizon
      visible = rows.select { |row| @readable.call(row.agent_root) }
      # A cursor in the middle of a backlog is as old as where it stands.
      result(visible, reached, truncated: truncated, has_more: has_more, issued_at: has_more ? rows.last.created_at : @now)
    end

    private

    def result(rows, reached, truncated: false, has_more: false, issued_at: @now)
      {
        resultType: "complete",
        events: rows.map(&:as_occurrence),
        cursor: "1.#{reached.first}.#{reached.last}.#{issued_at.to_i}",
        truncated: truncated,
        hasMore: has_more,
        nextPollMs: NEXT_POLL_MS
      }
    end

    # Everything in a transaction below this is settled: committed for good, or
    # never happened.
    def visible_horizon
      [ SessionEvent.connection.select_value("SELECT pg_snapshot_xmin(pg_current_snapshot())::text::bigint").to_i, 0 ]
    end

    def read_cursor
      match = CURSOR.match(@params["cursor"].to_s)
      raise Refused.new(:invalid_params, "cursor is not one this server issued") unless match

      [ [ match[1].to_i, match[2].to_i ], Time.zone.at(match[3].to_i) ]
    end

    def age_floor
      ms = @params["maxAgeMs"]
      return nil if ms.nil?
      raise Refused.new(:invalid_params, "maxAgeMs must be an integer from 0 to #{MAX_AGE_MS}") unless ms.is_a?(Integer) && ms.between?(0, MAX_AGE_MS)

      @now - (ms / 1000.0)
    end

    def max_events
      value = @params["maxEvents"]
      return DEFAULT_MAX if value.nil?
      raise Refused.new(:invalid_params, "maxEvents must be a positive integer") unless value.is_a?(Integer) && value.positive?

      [ value, LIMIT_MAX ].min
    end

    def arguments_for(descriptor)
      arguments = @params["arguments"] || {}
      raise Refused.new(:invalid_params, "arguments must be an object") unless arguments.is_a?(Hash)

      properties = descriptor.dig(:inputSchema, :properties)
      arguments.each do |key, value|
        schema = properties[key.to_sym]
        raise Refused.new(:invalid_params, "#{key.to_s.truncate(60).inspect} is not an argument of #{descriptor[:name]}") unless schema

        valid = schema[:type] == "integer" ? (value.is_a?(Integer) && value.positive? && value < 2**63) : schema[:enum].include?(value)
        raise Refused.new(:invalid_params, "#{key} is not valid: expected #{schema[:enum]&.join(', ') || 'a positive integer'}") unless valid
      end
      arguments
    end

    def filtered(name, arguments)
      scope = SessionEvent.where(name: name)
      scope = scope.where(session_id: arguments["session_id"]) if arguments.key?("session_id")
      scope = scope.where(parent_session_id: arguments["parent_session_id"]) if arguments.key?("parent_session_id")
      scope = scope.where("data->>'reason' = ?", arguments["reason"]) if arguments.key?("reason")
      scope = scope.where("data->>'state' = ?", arguments["state"]) if arguments.key?("state")
      scope
    end
  end
end

# frozen_string_literal: true

module McpEvents
  # The two requests of the events extension's poll mode, over the same bounded Streamable HTTP
  # client MCP Apps uses (timeouts, a response byte cap, no redirects).
  #
  # Everything a server returns is checked for shape before it leaves this class: an occurrence
  # without a string `eventId` or an object `data` is dropped, and a poll result without a cursor is
  # an error. The payload itself is the server's — and on a gateway like strad, ultimately whoever
  # wrote the Slack message or the mail — so nothing here trusts what it says.
  #
  # The SEP defines the extension for protocol 2026-07-28, whose `server/discover` replaces
  # `initialize`. This client still initializes at McpApps::Client's 2025-06-18 and reads the
  # extension off the `initialize` result, which is what strad answers today. The pin page records
  # that deviation.
  class Client < McpApps::Client
    # One event type, as `events/list` described it.
    Descriptor = Data.define(:name, :description, :delivery, :input_schema, :payload_schema) do
      def pollable?
        delivery.include?("poll")
      end

      def to_h
        { "name" => name, "description" => description, "delivery" => delivery,
          "inputSchema" => input_schema, "payloadSchema" => payload_schema }
      end
    end

    # One event, as `events/poll` returned it. `data` is the server's payload, untrusted.
    Occurrence = Data.define(:event_id, :name, :timestamp, :data)

    # One `events/poll` result.
    PollResult = Data.define(:events, :cursor, :truncated, :has_more, :next_poll_ms)

    # What an event id may look like: a dedupe key stored per fire, never prose. The same shape
    # Trigger::TRUSTED_IDENTIFIER_FORMATS lets {{event_id}} render.
    EVENT_ID_FORMAT = /\A[A-Za-z0-9._:\/-]{1,512}\z/

    # The most events one poll asks for. The server may return fewer; `hasMore` says there is more.
    MAX_EVENTS_PER_POLL = 50

    # Whether the server declared the events extension.
    #
    # @return [Boolean]
    def events_supported?
      declared = server_capabilities.dig("extensions", EXTENSION_ID)
      declared.is_a?(Hash) || declared == true
    end

    # Every event type the server publishes.
    #
    # @return [Array<Descriptor>]
    def list_events
      descriptors = []
      cursor = nil

      # A server that returns a cursor forever would otherwise spin here.
      10.times do
        params = cursor ? { "cursor" => cursor } : {}
        result = request("events/list", params, headers: { "Mcp-Method" => "events/list" })
        Array(result["events"]).each do |raw|
          descriptor = descriptor_from(raw)
          descriptors << descriptor if descriptor
        end
        cursor = result["nextCursor"]
        break if cursor.blank?
      end

      descriptors
    end

    # One `events/poll`. A nil +cursor+ asks for "from now": by the SEP the server answers with no
    # events and a cursor to poll from next.
    #
    # @return [PollResult]
    def poll(name:, arguments:, cursor:, max_events: MAX_EVENTS_PER_POLL)
      raise Error, "event name #{name.inspect} is not one Zimmer polls" unless name.to_s.match?(NAME_FORMAT)

      params = {
        "name" => name,
        "arguments" => arguments || {},
        "cursor" => cursor.presence,
        "maxEvents" => max_events,
        "_meta" => { "io.modelcontextprotocol/clientCapabilities" => { "extensions" => { EXTENSION_ID => {} } } }
      }
      result = request("events/poll", params, headers: { "Mcp-Method" => "events/poll", "Mcp-Name" => name })

      next_cursor = result["cursor"]
      raise Error, "events/poll answered without a cursor" unless next_cursor.is_a?(String) && next_cursor.present?

      PollResult.new(
        events: Array(result["events"]).filter_map { |raw| occurrence_from(raw) },
        cursor: next_cursor,
        truncated: result["truncated"] == true,
        has_more: result["hasMore"] == true,
        next_poll_ms: result["nextPollMs"].is_a?(Integer) ? result["nextPollMs"] : nil
      )
    end

    private

    def descriptor_from(raw)
      return nil unless raw.is_a?(Hash)

      name = raw["name"].to_s
      return nil unless name.match?(NAME_FORMAT)

      delivery = Array(raw["delivery"]).map(&:to_s)
      Descriptor.new(
        name: name,
        description: raw["description"].to_s,
        delivery: delivery,
        input_schema: raw["inputSchema"].is_a?(Hash) ? raw["inputSchema"] : {},
        payload_schema: raw["payloadSchema"].is_a?(Hash) ? raw["payloadSchema"] : {}
      )
    end

    def occurrence_from(raw)
      return nil unless raw.is_a?(Hash)

      # The id is the dedupe key, goes into log lines and session metadata, and renders bare as
      # {{event_id}}, so it must have an identifier's shape; an event without one is dropped.
      event_id = raw["eventId"]
      return nil unless event_id.is_a?(String) && event_id.match?(EVENT_ID_FORMAT)
      return nil unless raw["data"].is_a?(Hash)

      Occurrence.new(
        event_id: event_id,
        name: raw["name"].to_s,
        timestamp: parse_time(raw["timestamp"]),
        data: raw["data"]
      )
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end

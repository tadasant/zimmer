# frozen_string_literal: true

module McpEvents
  # Which catalog MCP servers publish events, and what each one publishes.
  #
  # A server is reached exactly as a session would reach it: McpServerEndpoint resolves its catalog
  # URL and headers — `${VAR}` through the secrets chain, a stored OAuth bearer refreshed when due —
  # so an `mcp_event` trigger needs no credential of its own. For a strad-served server that is
  # `https://strad.tadasant.com/mcp?servers=<slug>` with `Bearer ${STRAD_API_KEY}`.
  #
  # Two reads, at two costs:
  #
  #   .probe(name)  asks ONE server, now: `initialize`, then `events/list` if it declared the
  #                 extension. Cached PROBE_TTL, so a form that re-renders does not re-ask.
  #   .roster       the event-publishing servers as of the last McpEventSourcesRefreshJob sweep,
  #                 read from the cache and never from the network. It is what the trigger form's
  #                 server dropdown and list_mcp_event_sources offer.
  class Sources
    class Unavailable < StandardError; end

    # One server that publishes events.
    Source = Data.define(:server_name, :title, :events) do
      def find_event(name)
        events.find { |descriptor| descriptor.name == name }
      end

      def to_h
        { "server" => server_name, "title" => title, "events" => events.map(&:to_h) }
      end
    end

    PROBE_TTL = 10.minutes
    ROSTER_KEY = "mcp_events:sources:roster"
    ROSTER_TTL = 1.day

    class << self
      # The catalog servers a probe may ask: remote, and not declared unusable.
      #
      # @return [Array<ServersConfig::Server>]
      def candidates
        ServersConfig.all.select { |server| server.remote? && !server.declared_unavailable? }
      rescue StandardError => e
        Rails.logger.warn("[McpEvents::Sources] could not read the catalog: #{e.class}: #{e.message}")
        []
      end

      # @param name [String] catalog server name
      # @return [Source, nil] nil when the server answered and declared no events extension
      # @raise [Unavailable] when it is not a remote catalog server, or could not be asked
      def probe(name, cache: true)
        return fetch(name) unless cache

        cached = Rails.cache.read(probe_key(name))
        return cached.presence && from_cache(cached) unless cached.nil?

        source = fetch(name)
        Rails.cache.write(probe_key(name), source ? source.to_h : {}, expires_in: PROBE_TTL)
        source
      end

      # @return [Array<Source>] as of the last sweep; empty before the first
      def roster
        Array(Rails.cache.read(ROSTER_KEY)&.fetch("sources", nil)).map { |hash| from_cache(hash) }
      end

      # @return [Time, nil] when the roster was last swept
      def roster_swept_at
        stamp = Rails.cache.read(ROSTER_KEY)&.fetch("swept_at", nil)
        stamp && Time.zone.parse(stamp)
      end

      # What the trigger form, GET /api/v1/triggers/mcp_event_sources and list_mcp_event_sources
      # answer: the swept roster, or — given +server+ — that one server, asked now.
      #
      # @raise [Unavailable] when +server+ is named and cannot be asked
      # @return [Hash]
      def listing(server: nil)
        if server.present?
          source = probe(server)
          return { "server" => server, "publishes_events" => !source.nil?, "sources" => [ source ].compact.map(&:to_h) }
        end

        { "swept_at" => roster_swept_at&.iso8601, "sources" => roster.map(&:to_h) }
      end

      # Called by McpEventSourcesRefreshJob.
      def write_roster!(sources, swept_at: Time.current)
        Rails.cache.write(ROSTER_KEY, { "swept_at" => swept_at.iso8601, "sources" => sources.map(&:to_h) }, expires_in: ROSTER_TTL)
      end

      # A client for +name+, with that server's resolved credentials.
      #
      # @raise [Unavailable]
      # @return [McpEvents::Client]
      def client_for(name)
        server = ServersConfig.find(name.to_s)
        raise Unavailable, "no catalog MCP server named #{name}" if server.nil?
        raise Unavailable, "#{name} is a #{server.type} server; MCP events need a remote one" unless server.remote?

        endpoint = McpServerEndpoint.new(server)
        Client.new(url: endpoint.url, headers: endpoint.headers)
      rescue McpServerEndpoint::UnresolvableError => e
        raise Unavailable, "#{name} #{e.message}"
      end

      private

      def fetch(name)
        server = ServersConfig.find(name.to_s)
        client = client_for(name)
        return nil unless client.events_supported?

        Source.new(server_name: server.name, title: server.title.to_s, events: client.list_events)
      rescue McpApps::Client::Error => e
        raise Unavailable, "#{name} could not be asked for its events: #{e.message}"
      end

      def probe_key(name)
        "mcp_events:sources:probe:#{name}"
      end

      def from_cache(hash)
        Source.new(
          server_name: hash["server"],
          title: hash["title"],
          events: Array(hash["events"]).map do |event|
            Client::Descriptor.new(
              name: event["name"], description: event["description"], delivery: Array(event["delivery"]),
              input_schema: event["inputSchema"] || {}, payload_schema: event["payloadSchema"] || {}
            )
          end
        )
      end
    end
  end
end

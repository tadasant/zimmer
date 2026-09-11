# frozen_string_literal: true

module McpApps
  # The trust boundary: which MCP servers may put HTML into an operator's browser.
  #
  # An MCP App fragment is a document written by whoever runs the MCP server, and
  # rendering it means executing their JavaScript in a tab that is logged into
  # Zimmer. The sandbox (see ContentSecurityPolicy) is what contains that code; this
  # is what decides whose code gets containment applied to it in the first place.
  #
  # Two switches, both closed on a fresh deployment, and both have to be open:
  #
  #   * `mcp_apps_enabled` — the deployment renders MCP Apps at all.
  #   * `mcp_apps_allowed_servers` — the named servers it renders them for.
  #
  # The second is the one that matters. A blanket "on" would mean that attaching
  # any MCP server to any session also grants that server's operator a script
  # execution primitive in the browser of whoever reads the session — an
  # escalation nobody asked for when they attached a server for the *agent* to
  # use. So the answer for a server nobody has named is no, and stays no.
  #
  # Only remote servers are eligible. A stdio server would have to be spawned by
  # the web process to be read from, which is a process-spawning primitive in the
  # request path; the transcript trigger simply never fires for one. See
  # docs/src/content/docs/limitations.md.
  class Policy
    # Remote transports ServersConfig understands, and the only ones a fragment
    # can be read over.
    REMOTE_TYPES = %w[streamable-http sse].freeze

    # Both switches read at one instant, for a caller that has to ask about many
    # servers without a settings query per question — the timeline, which asks
    # once per rendered tool call.
    Snapshot = Data.define(:enabled, :servers) do
      def enabled? = enabled

      def allows?(server_name)
        return false if server_name.blank?

        enabled && servers.include?(server_name.to_s)
      end
    end

    class << self
      # @return [Snapshot] both switches, from one read of the settings row
      def snapshot
        row = setting
        value = row.mcp_apps_allowed_servers
        Snapshot.new(
          enabled: row.mcp_apps_enabled?,
          servers: value.is_a?(Array) ? value.map(&:to_s) : []
        )
      end

      # @return [Boolean] the deployment-wide master switch
      def enabled?
        snapshot.enabled?
      end

      # @return [Array<String>] catalog server names opted in, always an Array
      def allowed_servers
        snapshot.servers
      end

      # Whether fragments from `server_name` may be rendered at all.
      #
      # @param server_name [String, nil]
      # @return [Boolean]
      def allows?(server_name)
        snapshot.allows?(server_name)
      end

      # The servers an operator may opt in: the remote ones in the catalog. A
      # catalog that cannot be resolved yields an empty roster rather than
      # raising — the settings page renders either way.
      #
      # @return [Array<ServersConfig::Server>]
      def eligible_servers
        ServersConfig.all
          .select { |server| REMOTE_TYPES.include?(server.type) }
          .sort_by { |server| server.title.to_s.downcase }
      rescue StandardError => e
        Rails.logger.warn("[mcp-apps] could not list eligible servers: #{e.class}: #{e.message}")
        []
      end

      # Normalize a submitted allowlist: known, remote, unique, sorted. Anything
      # the catalog does not offer as a remote server is dropped rather than
      # stored, so a stale or crafted submit cannot accumulate names that the
      # rest of this namespace would then have to defend against.
      #
      # @param names [Array<String>, nil]
      # @return [Array<String>]
      def sanitize_allowlist(names)
        return [] unless names.is_a?(Array)

        eligible = eligible_servers.map(&:name)
        names.map(&:to_s).select { |name| eligible.include?(name) }.uniq.sort
      end

      private

      def setting
        AppSetting.current(context: "McpApps::Policy")
      end
    end
  end
end

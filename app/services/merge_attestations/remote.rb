# frozen_string_literal: true

module MergeAttestations
  # Another Zimmer, reached through a catalog MCP server this one can call from
  # Rails (LiveConversations::CatalogServer): the server the local session
  # drives the remote session with. Only servers named in
  # MERGE_ATTESTATION_REMOTE_SERVERS are ever spoken to.
  #
  # Two calls, both served by the receiver's `merge_attestations` tool group:
  # TARGET_TOOL to learn which remote session holds a PR and its head commit,
  # SUBMIT_TOOL to hand over a signed approval. Both answer JSON.
  #
  # The name a tool is called by comes from the server's own listing, not from
  # the constant. A gateway in front of the remote may namespace every tool as
  # `<server>__<tool>` and refuse the bare name, so the listing is matched on
  # the exact name or a `__<tool>` suffix. No match, or more than one, is
  # refused rather than guessed: calling the wrong tool with a signed approval
  # is the one mistake here worth stopping for.
  class Remote
    Unreachable = Class.new(StandardError)

    # What TARGET_TOOL answered, read defensively: it is another deployment's text.
    Target = Data.define(:pr_url, :repo, :pr_number, :head_sha, :session_url, :title, :blocked_reason, :gate_hold_reason,
                         :audience, :trusts_issuer, :merge_authorized_at) do
      def ok? = blocked_reason.nil?
    end

    # The configured remotes among `server_names`, in configuration order.
    def self.among(server_names)
      MergeAttestations.remote_servers.filter_map do |name, audience|
        new(name, audience: audience) if Array(server_names).include?(name)
      end
    end

    # The audience this Zimmer pinned for the remote; tokens are addressed to it.
    attr_reader :server_name, :audience

    def initialize(server_name, audience:, catalog_server: nil)
      @server_name = server_name
      @audience = audience
      @catalog_server = catalog_server
    end

    # @return [Target]
    # @raise [Unreachable]
    def target(pr_url)
      arguments = { "pr_url" => pr_url, "issuer" => MergeAttestations.issuer }
      arguments["kid"] = SigningKey.current.kid if SigningKey.configured?
      data = call(TARGET_TOOL, arguments)
      Target.new(
        pr_url: data["pr_url"].to_s, repo: data["repo"].to_s.presence, pr_number: data["pr_number"],
        head_sha: data["head_sha"].to_s.presence, session_url: data["session_url"].to_s.presence,
        title: data["title"].to_s.presence, blocked_reason: data["blocked_reason"].to_s.presence,
        gate_hold_reason: data["gate_hold_reason"].to_s.presence, audience: data["audience"].to_s.presence,
        trusts_issuer: data["trusts_issuer"] == true,
        merge_authorized_at: data["merge_authorized_at"].to_s.presence
      )
    end

    # @return [Hash] the receiver's answer: "accepted" (bool), "message", "code"
    # @raise [Unreachable]
    def submit(token)
      call(SUBMIT_TOOL, { "attestation" => token })
    end

    private

    def call(tool, arguments)
      text, error = catalog_server.call_tool(resolved_name(tool), arguments)
      data = begin
        JSON.parse(text.to_s)
      rescue JSON::ParserError
        nil
      end
      raise Unreachable, "#{server_name} answered #{tool} with #{error ? 'an error' : 'something that is not JSON'}: #{text.to_s.truncate(200)}" unless data.is_a?(Hash)

      data
    rescue LiveConversations::CatalogServer::Unavailable, McpApps::Client::Error => e
      raise Unreachable, "#{server_name} could not be reached: #{e.message.to_s.truncate(200)}"
    end

    # The name `tool` is listed under on this server.
    def resolved_name(tool)
      names = listed_names
      return tool if names.include?(tool)

      matches = names.select { |name| name.end_with?("__#{tool}") }
      return matches.first if matches.one?

      raise Unreachable, "#{server_name} lists #{matches.empty? ? "no #{tool} tool" : "more than one #{tool} tool (#{matches.first(5).join(', ')})"}; " \
                         "it must expose the merge_attestations tool group"
    end

    def listed_names
      @listed_names ||= catalog_server.list_tools.map { |listed| listed.name.to_s }
    end

    def catalog_server = (@catalog_server ||= LiveConversations::CatalogServer.find!(server_name))
  end
end

# frozen_string_literal: true

module TokenBroker
  # A catalog entry's opt-in to brokered auth, read from the entry's top-level
  # `brokered_auth` object:
  #
  #   "image-diff": {
  #     "type": "streamable-http",
  #     "url": "https://strad.tadasant.com/mcp?servers=image-diff",
  #     "brokered_auth": { "scopes": ["slug:image-diff"] }
  #   }
  #
  # - `scopes` (required): the scope tokens this entry needs. For strad, its
  #   `slug:<name>`. A session's child token carries the union of the scopes of
  #   every brokered entry it has on the same authorization server.
  # - `authorization_server` (optional): the origin whose parent grant serves
  #   this entry. Defaults to the origin of the entry's `url`.
  #
  # It is a top-level key on purpose, not part of the `oauth` block: AIR's
  # Claude adapter copies `oauth` into the runtime's `.mcp.json`, which would
  # hand Claude Code an OAuth configuration for a server Zimmer is
  # authenticating itself. A top-level key the adapters do not know stops at
  # the catalog, the way `unavailable` and `startup_timeout_sec` do.
  #
  # The presence of the key is the opt-in. A malformed declaration is still an
  # opt-in — it makes the entry fail visibly (#error) rather than quietly fall
  # back to whatever static credential the entry also carries.
  class Declaration
    CATALOG_KEY = "brokered_auth"

    # RFC 6749 §3.3 scope-token: printable ASCII except space, `"` and `\`.
    SCOPE_TOKEN = /\A[\x21\x23-\x5B\x5D-\x7E]+\z/

    attr_reader :server_name, :url, :scopes, :authorization_server, :error

    # @param server [ServersConfig::Server]
    # @return [Declaration, nil] nil when the entry does not opt in
    def self.for(server)
      return nil if server.nil? || !server.declares_brokered_auth?

      new(server_name: server.name, url: server.url, raw: server.brokered_auth, remote: server.remote?, headers: server.headers.to_h)
    end

    def initialize(server_name:, url:, raw:, remote: true, headers: {})
      @server_name = server_name
      @url = url
      @remote = remote
      @headers = headers
      @scopes = []
      @error = nil
      parse!(raw)
    end

    def valid? = error.nil?

    # The entry's resource: its URL without query or fragment, which is how
    # strad normalizes `resource` too. A grant serves the entry only when this
    # is the grant's resource.
    def resource
      TokenBroker.normalize_resource(url)
    end

    private

    def parse!(raw)
      unless raw.is_a?(Hash)
        @error = "`#{CATALOG_KEY}` must be an object"
        return
      end

      scopes = raw["scopes"]
      unless scopes.is_a?(Array) && scopes.any? && scopes.all? { |s| s.is_a?(String) && s.match?(SCOPE_TOKEN) }
        @error = "`#{CATALOG_KEY}.scopes` must be a non-empty list of scope tokens (for strad, `slug:<name>`)"
        return
      end
      @scopes = scopes.uniq.sort

      declared = raw["authorization_server"]
      @authorization_server = TokenBroker.normalize_origin(declared.presence || url)
      if @authorization_server
        @error = unservable_reason
        return
      end

      @error = declared.present? ? "`#{CATALOG_KEY}.authorization_server` is not an https origin" : "the entry has no https `url` to take an authorization server from"
    end

    # Why a well-formed declaration still cannot be served. The broker replaces
    # exactly one thing, a remote entry's `Authorization` header, so an entry that
    # carries a credential anywhere else would keep it beside the child token.
    def unservable_reason
      return "the entry is not a remote server, so there is no Authorization header to broker" unless @remote
      return "the entry's `url` cannot be used as a resource" if resource.nil?

      extra = @headers.keys.map(&:to_s).reject { |key| key.casecmp?("Authorization") }
        .grep(McpOauthCredentialInjector::CREDENTIAL_HEADER_PATTERN)
      return if extra.empty?

      "the entry carries a credential in #{extra.to_sentence}, which the broker does not replace; only `Authorization` may carry one"
    end
  end
end

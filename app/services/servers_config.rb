# frozen_string_literal: true

# Service class for managing MCP server configurations.
# Reads server entries from AirCatalogService, which discovers them via air.json.
class ServersConfig
  class ServerNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  # Environment variable interpolation pattern: ${VAR} or ${VAR:-default}
  ENV_VAR_PATTERN = /\$\{([A-Z_][A-Z0-9_]*)(?::-([^}]*))?\}/

  # Server configuration object
  class Server
    include ArtifactIdentity::Entry

    # How much of an `unavailable` declaration is reported. A reason is one line
    # in a roster, not a second description; anything longer is a story the
    # catalog should be telling somewhere else.
    UNAVAILABLE_REASON_LIMIT = 200
    attr_reader :name, :title, :description, :type, :command, :args, :env, :url, :headers, :oauth

    def initialize(name, config)
      identify!(name, config)
      @name = name
      @title = config["title"] || name
      @description = config["description"]
      @type = config["type"]
      @command = config["command"]
      @args = config["args"] || []
      @env = config["env"] || {}
      @url = config["url"]
      @headers = config["headers"] || {}
      @oauth = config["oauth"] || {}
      @brokered_auth = config[TokenBroker::Declaration::CATALOG_KEY]
      @declares_brokered_auth = config.key?(TokenBroker::Declaration::CATALOG_KEY)
      @unavailable = config["unavailable"]
      @startup_timeout_sec = config[McpStartupTimeout::CATALOG_KEY]
    end

    def remote?
      %w[sse streamable-http].include?(type)
    end

    # The catalog's standing declaration that this entry cannot work here, and
    # why — the escape hatch for the class of breakage no local check can infer.
    #
    # Zimmer's readiness check reads what is configured and stored: unresolved
    # `${VAR}`s, missing or dead OAuth credentials. A server whose every variable
    # resolves but whose endpoint simply cannot serve Zimmer — one that accepts
    # only static bearer tokens while the entry is written for OAuth, say —
    # passes every one of those checks and is still unusable. That fact lives
    # with whoever curates the catalog; nothing here can derive it.
    #
    # The field is `"unavailable": "<reason>"` on the server entry. A non-empty
    # string means unavailable and IS the reason, reported wherever the state is.
    # Absent, null, or blank means nothing is declared — which is not a claim that
    # the server works, only that the catalog is silent, so the ordinary readiness
    # checks decide. There is no `"unavailable": true`: requiring the reason by
    # construction is what keeps this from becoming the prose-warning-in-the-
    # description hack it replaces.
    #
    # Normalized rather than passed through, because this string is written in a
    # different repository and lands in a markdown list that an agent reads as
    # part of a tool response. Whitespace is squished to single spaces so a
    # newline cannot split the roster line it sits on, and a `### `, `---` or
    # leading `- ` cannot forge structure around it; length is capped so one
    # entry cannot crowd out the roster. AIR's schema constrains `description`
    # to 500 characters and says nothing at all about this field, so the limit
    # has to be here.
    #
    # @return [String, nil]
    def unavailable_reason
      return nil unless @unavailable.is_a?(String)

      reason = @unavailable.gsub(/\s+/, " ").strip
      return nil if reason.empty?

      reason.truncate(UNAVAILABLE_REASON_LIMIT)
    end

    def declared_unavailable? = !unavailable_reason.nil?

    # The entry's raw `brokered_auth` declaration. nil when it does not opt into
    # the session token broker, and also for a declaration written as `null`, which
    # is malformed rather than absent (#declares_brokered_auth?). Parsed and validated by
    # TokenBroker::Declaration, which is what every caller should go through.
    attr_reader :brokered_auth

    # Whether the catalog entry asks to be brokered. Says nothing about this
    # deployment: a catalog is shared, and a declaration is inert where the
    # broker is off. For the pages that show a declaration; anything that decides
    # how the entry is authenticated asks #brokered?.
    def declares_brokered_auth? = @declares_brokered_auth

    # Whether the token broker authenticates this entry HERE: it declares
    # `brokered_auth` and this deployment turned the broker on
    # (TokenBroker.enabled?). The one predicate every consumer decides through,
    # so they all flip together. Deliberately not "and a token can be minted":
    # with the broker on, an entry that cannot get a token is left out, never
    # handed its static header.
    def brokered? = declares_brokered_auth? && TokenBroker.enabled?

    # The `${VAR}`s a session's clone needs for this entry (SessionSecretScope).
    #
    # For most entries that is every variable the entry names. A brokered entry's
    # `Authorization` header is replaced by a child token when the session is
    # prepared, so the static credential it names — `${STRAD_API_KEY}`, while
    # the catalog still carries it — is not the session's to hold, and is left
    # out here.
    #
    # @return [Array<String>]
    def session_variables
      return required_variables + optional_variables unless brokered?
      # A malformed declaration leaves the entry out of every session, so nothing
      # it names is the session's to hold, wherever in the entry it is named.
      return [] unless TokenBroker::Declaration.for(self).valid?

      kept_headers = headers.reject { |key, _| key.to_s.casecmp?("Authorization") }
      (env.values + kept_headers.values + args + [ url ]).flat_map do |value|
        extract_interpolations(value, with_defaults: false) + extract_interpolations(value, with_defaults: true)
      end.uniq
    end

    # How long a runtime should wait for THIS server to start and answer
    # `initialize`, in seconds, when the catalog entry says so — nil when it does
    # not, which is when McpStartupTimeout's flat default applies.
    #
    # The field is `"startup_timeout_sec": <int>` on the server entry
    # ([#113](https://github.com/tadasant/zimmer/issues/113)). A fast local server
    # can ask to fail fast instead of holding a session for three minutes; a big
    # npx cold start or a remote server doing OAuth can ask for more room.
    #
    # Validated rather than passed through, for the same reason
    # #unavailable_reason is normalized: the value is written in another
    # repository, and this one is a number Zimmer hands to a runtime. Bounds and
    # the ignore-and-log rule live in McpStartupTimeout, which is also where the
    # default it falls back to is stated.
    #
    # @return [Integer, nil] seconds
    def startup_timeout_seconds
      return @startup_timeout_seconds if defined?(@startup_timeout_seconds)

      @startup_timeout_seconds = McpStartupTimeout.normalize(@startup_timeout_sec, server_name: name)
    end

    # Statically-configured OAuth client id for this server, taken from the
    # catalog `oauth` block. Present for servers that require a pre-registered
    # OAuth client and expose no usable Dynamic Client Registration endpoint
    # (e.g. Slack). The catalog schema uses camelCase (`clientId`); snake_case is
    # accepted as a tolerant fallback.
    def oauth_client_id
      @oauth["clientId"] || @oauth["client_id"]
    end

    # Statically-configured OAuth client secret, when the pre-registered client
    # is confidential. Public clients (like Slack's) configure only a client id.
    def oauth_client_secret
      @oauth["clientSecret"] || @oauth["client_secret"]
    end

    # Statically-configured OAuth redirect URI for this server, taken from the
    # catalog `oauth` block. Present for pre-registered clients that only permit a
    # redirect Zimmer does not host — the official Slack MCP client, for instance,
    # is a public client registered against `http://localhost:3118/callback` and
    # rejects Zimmer's hosted callback with `redirect_uri did not match any
    # configured URIs`. When set it wins over `McpOauthService#build_redirect_uri`
    # and the flow completes by paste-back instead of the hosted callback.
    def oauth_redirect_uri
      @oauth["redirectUri"] || @oauth["redirect_uri"]
    end

    # Which client identity this server's OAuth flow presents, from the catalog
    # `oauth` block: `"clientIdentity": "cimd"` opts into Zimmer's own hosted
    # identity (OauthClientIdentity — a Client ID Metadata Document URL as the
    # client_id, and private_key_jwt at the token endpoint). Absent means the
    # identity Zimmer has always used for the server.
    def oauth_client_identity
      @oauth["clientIdentity"] || @oauth["client_identity"]
    end

    # The client the OAuth flow for this server should present, as the keyword
    # arguments McpOauthService#check_oauth_requirement takes. With the hosted
    # identity opted into AND configured on this deployment, it is that identity:
    # its URL as the client id, no secret, and the redirect its document lists.
    # Otherwise it is exactly the static `oauth` block (each value nil when unset).
    def oauth_client_options
      if OauthClientIdentity.use_for?(oauth_client_identity, server_name: name)
        return {
          configured_client_id: OauthClientIdentity.client_id,
          configured_client_secret: nil,
          configured_redirect_uri: OauthClientIdentity.redirect_uri
        }
      end

      {
        configured_client_id: oauth_client_id,
        configured_client_secret: oauth_client_secret,
        configured_redirect_uri: oauth_redirect_uri
      }
    end

    def stdio?
      type == "stdio"
    end

    def required_env_vars
      env_vars_from_interpolation(with_defaults: false)
    end

    def optional_env_vars
      env_vars_from_interpolation(with_defaults: true)
    end

    def all_env_vars
      required_env_vars + optional_env_vars
    end

    def required_headers
      headers_from_interpolation(with_defaults: false)
    end

    def optional_headers
      headers_from_interpolation(with_defaults: true)
    end

    # Every `${VAR}` without a default across the whole entry — env, headers,
    # url and args. These are the variables that must resolve for this server to
    # start at all; SecretsInterpolator raises MissingVariableError on any one of
    # them that has no value. `required_env_vars` / `required_headers` cover only
    # their own slice, so anything asking "is this server configured?" wants this.
    #
    # @return [Array<String>]
    def required_variables
      interpolated_variables(with_defaults: false)
    end

    # Every `${VAR:-default}` across the whole entry. These fall back to their
    # default rather than failing, so an unset one is not a misconfiguration.
    #
    # @return [Array<String>]
    def optional_variables
      interpolated_variables(with_defaults: true)
    end

    def to_h
      result = {
        name: name,
        # The fully-qualified AIR ID this entry resolved from. Reported
        # alongside `name` rather than instead of it: `name` is what a session
        # stores and what every existing caller matches on, while this is what
        # tells two same-short-id servers from different catalogs apart.
        qualified_name: qualified_name,
        title: title,
        description: description,
        type: type,
        remote?: remote?,
        # The catalog's own declaration, verbatim and normalized — nil when the
        # catalog is silent. This is NOT the whole availability answer: an entry
        # the catalog says nothing about can still be unstartable because a
        # `${VAR}` does not resolve or its OAuth flow was never completed, and
        # only ConnectorStatusProbe can tell you that. Anything serializing "can
        # Zimmer use this?" wants McpServerOptions, not this field.
        #
        # Named for the accessor rather than for the catalog key (`unavailable`),
        # because McpServerOptions already publishes an `unavailable` that is a
        # boolean. Two hashes describing one server must not use one key for two
        # types.
        unavailable_reason: unavailable_reason,
        # The catalog's own declared startup budget, or nil when it declares
        # nothing and McpStartupTimeout::SECONDS applies. Reported rather than
        # resolved to an effective number: nil here is "the catalog is silent",
        # which is a different fact from "the catalog asked for 180".
        startup_timeout_sec: startup_timeout_seconds
      }

      if stdio?
        result.merge!(command: command, args: args, env: env)
      else
        result.merge!(url: url, headers: headers)
      end

      result
    end

    def to_json(*args)
      to_h.to_json(*args)
    end

    private

    # Scan every string the entry carries — env values, header values, url, args
    # — for interpolations of the requested kind.
    def interpolated_variables(with_defaults:)
      strings = env.values + headers.values + args + [ url ]

      strings.flat_map { |value| extract_interpolations(value, with_defaults: with_defaults) }.uniq
    end

    def env_vars_from_interpolation(with_defaults:)
      vars = []
      env.each_value do |value|
        extract_interpolations(value, with_defaults: with_defaults).each do |var|
          vars << var
        end
      end
      vars.uniq
    end

    def headers_from_interpolation(with_defaults:)
      vars = []
      headers.each_value do |value|
        extract_interpolations(value, with_defaults: with_defaults).each do |var|
          vars << var
        end
      end
      vars.uniq
    end

    def extract_interpolations(str, with_defaults:)
      return [] unless str.is_a?(String)

      vars = []
      str.scan(ENV_VAR_PATTERN) do |var_name, default_value|
        has_default = !default_value.nil?
        if with_defaults == has_default
          vars << var_name
        end
      end
      vars
    end
  end

  class << self
    def all
      build_servers
    end

    # Accepts a canonical token, a fully-qualified `@scope/id`, or a bare short
    # id that exactly one catalog contributes. See ArtifactIdentity.find.
    # #all, without its degrade-to-empty. For a caller to whom "the catalog could
    # not be read" and "nothing is in it" must not look the same: the token broker
    # reading an empty list would conclude that nothing is brokered.
    #
    # @raise [AirCatalogService::CatalogError]
    def all!
      AirCatalogService.entries_for(:mcp).map { |name, entry| Server.new(name, entry) }
    end

    def find(name)
      ArtifactIdentity.find(all, name)
    end

    def find!(name)
      find(name) || raise(ServerNotFoundError, "Server '#{name}' not found in catalog")
    end

    def names
      all.map(&:name)
    end

    def titles
      all.map(&:title)
    end

    def exists?(name)
      find(name).present?
    end

    # Canonical MCP server config hash used for OAuth credential-key computation.
    # Mirrors the shape Claude Code uses when deriving the credential key
    # (type, url, headers), so every caller hashes the same structure.
    #
    # @param name [String] the MCP server name
    # @return [Hash, nil] { type:, url?, headers? } or nil when the server is unknown
    def credential_config(name)
      server = find(name)
      return nil unless server

      config = { type: server.type }
      config[:url] = server.url if server.url
      config[:headers] = server.headers if server.headers&.any?
      config
    end

    def reload!
      AirCatalogService.reload!
      all
    end

    # Degrades the same way `all` does. This is the settings page's read
    # (DeploymentInfoService), and /settings is where an operator goes to clear
    # a bad catalog pin — so a resolve failure with no last-known-good fallback
    # must render an empty catalog there, not a 500 on the page holding the fix.
    def config
      AirCatalogService.entries_for(:mcp)
    rescue AirCatalogService::CatalogError => e
      Rails.logger.warn "[ServersConfig] catalog unavailable: #{e.message}"
      {}
    end

    private

    def build_servers
      AirCatalogService.entries_for(:mcp).map { |name, entry| Server.new(name, entry) }
    rescue AirCatalogService::CatalogError => e
      Rails.logger.warn "[ServersConfig] #{e.message}"
      []
    end
  end
end

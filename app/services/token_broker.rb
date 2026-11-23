# frozen_string_literal: true

# The session token broker: for catalog MCP servers that opt in
# (TokenBroker::Declaration), each session turn gets its own short-lived child
# token, scoped to exactly the servers it has, minted by Zimmer's backend from a
# parent grant only the backend holds (McpBrokerGrant), and revoked when the
# turn comes to rest.
#
# ## Off unless the deployment turns it on
#
# The switch is ZIMMER_TOKEN_BROKER_ENABLED (.enabled?), off by default. While it
# is off a `brokered_auth` declaration is inert: the entry behaves exactly as it
# would without one, static `${STRAD_API_KEY}` included, on every path — the
# prepare step, the session's secret scope, backend calls, the OAuth injector and
# connector status. A catalog is shared between deployments, and one that never
# set the broker up must not lose the servers another one brokers.
#
# The switch is configuration and nothing else. It is not "a grant exists" or "the
# client identity is configured": those are runtime state, and a lost grant or a
# KMS outage must never read as "off" and hand a session the static key.
#
# Turned on, an entry that declares `brokered_auth` additionally needs a parent
# grant for its authorization server, which only a human creates (the Token
# broker page), and Zimmer's hosted client identity (OauthClientIdentity).
# Connecting mints nothing, so it works while the broker is off: connect first,
# then turn the broker on.
#
# ## Never a broader credential
#
# With the broker on, a declaring entry is served by a child token or not at all. When minting
# fails — no grant, the grant was revoked, the authorization server or KMS is
# down — the entry is left out of that turn's MCP config, and the cause is
# written to the session's log and metadata. Its static header, if the catalog
# still carries one, is never used: falling back would hand the session the
# whole-gateway key the broker exists to replace.
#
# ## Lifecycle
#
#   turn start   AgentSessionJob → AirPrepareService(mint_brokered_tokens: true)
#                → RuntimeConfigPostProcessor#inject_brokered_credentials!
#                → .mint_for_session — one child per authorization server, its
#                  scope the union of the session's brokered entries there,
#                  labelled `session:<id>`. The previous turn's child is
#                  superseded (revoked).
#   turn end     Session after_commit (TokenBroker::SessionHooks) → TokenBrokerRevokeJob
#                → .revoke_session_tokens — for any rest: needs_input (unless
#                  blocked on an elicitation, where the process is alive),
#                  waiting after running, failed, archived.
#   backstop     TokenBrokerSweepJob (cron) — revokes children of sessions that
#                are not running, retries failed revocations with backoff, and
#                lets a child whose revocation never landed simply expire.
#
# The minting entry points (.mint_for_session, .backend_token) take no
# request-scoped state, so a future per-connection hook — a runtime asking
# Zimmer for a fresh token on reconnect — can call them directly.
module TokenBroker
  ENABLED_ENV = "ZIMMER_TOKEN_BROKER_ENABLED"
  # Everything that means off. Any other value is ON, including one nobody
  # recognises: someone set it meaning to turn the broker on, and a misspelling
  # must show up as servers that are missing with a cause, not as sessions
  # quietly carrying the static key.
  OFF_VALUES = [ "", "0", "false", "f", "no", "n", "off", "disabled" ].freeze

  # What a session asks for. strad clamps to its `maxChildTokenTtlSeconds` and
  # to the parent grant's deadline, and answers with what it gave.
  SESSION_TOKEN_TTL = 6.hours
  # Zimmer's own backend children are reused across calls until they are this
  # close to expiry, then replaced.
  BACKEND_TOKEN_TTL = 1.hour
  BACKEND_TOKEN_MIN_REMAINING = 10.minutes
  BACKEND_LABEL = "zimmer:backend"

  # A live child of a session that is not running is left alone for this long
  # by the sweep, because a turn mints before its process starts.
  SWEEP_GRACE = 15.minutes

  class Error < StandardError; end

  # Why an entry could not be given a token. The message names the cause and is
  # safe to show to a human, log, and store: it never contains a token.
  class MintError < Error; end

  # One prepare's outcome: the token for each brokered server that got one, and
  # the cause for each that did not.
  MintResult = Struct.new(:tokens, :failures, keyword_init: true) do
    def self.empty = new(tokens: {}, failures: {})
    def any? = tokens.any? || failures.any?
  end

  module_function

  # Whether this deployment turned the token broker on. Configuration only.
  def enabled?(env = ENV)
    !OFF_VALUES.include?(env[ENABLED_ENV].to_s.scrub.strip.downcase)
  end

  # @return [String, nil] `https://host[:port]`, lowercased; nil unless https
  #   (http is accepted for a loopback host, for local development).
  def normalize_origin(value)
    uri = URI.parse(value.to_s.strip)
    return nil unless uri.host.present?
    return nil unless uri.scheme == "https" || (uri.scheme == "http" && OauthClientIdentity.local_host?(uri.host))

    port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
    "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}"
  rescue URI::InvalidURIError
    nil
  end

  # A URL as an RFC 8707 resource: no query, no fragment, no trailing slash.
  def normalize_resource(value)
    uri = URI.parse(value.to_s.strip)
    return nil unless uri.host.present?

    uri.query = nil
    uri.fragment = nil
    uri.to_s.delete_suffix("/")
  rescue URI::InvalidURIError
    nil
  end

  # @param server [ServersConfig::Server, String]
  # @return [Declaration, nil]
  def declaration_for(server)
    server = ServersConfig.find(server) if server.is_a?(String)
    Declaration.for(server)
  end

  # The names among `server_names` that the broker authenticates on this
  # deployment (Server#brokered?). Nothing at all while the broker is off, and
  # otherwise one pass over the catalog — this is on every session's prepare path.
  #
  # @return [Array<String>]
  def brokered_among(server_names)
    return [] unless enabled?

    # Resolved against the whole catalog, not the declaring subset: a name two
    # catalogs contest must not resolve to whichever of them happens to declare.
    catalog = ServersConfig.all
    return [] if catalog.none?(&:brokered?)

    Array(server_names).map(&:to_s).select { |name| ArtifactIdentity.find(catalog, name)&.brokered? }
  end

  # The entries of one runtime config that the broker authenticates, and the ones
  # it has to refuse because it cannot tell which catalog entry they are.
  #
  # AIR keys a config by short id, and two composed catalogs may contribute the
  # same one, so a key is resolved through what the SESSION selected. A key that
  # still names more than one entry, any of them brokered, is refused: guessing
  # could write one entry's token onto another's URL, or leave a brokered entry
  # with its static key.
  ConfigMatch = Struct.new(:servers, :refused, keyword_init: true) do
    def self.empty = new(servers: {}, refused: {})
  end

  # @param config_entries [Hash{String => Object}] the config's server table
  # @param selected [Array<String>] the session's selected servers (canonical tokens)
  # @return [ConfigMatch] config key => Server, and config key => cause
  # @raise [AirCatalogService::CatalogError] when the catalog cannot be read, so
  #   that it is never mistaken for "nothing is brokered"
  def match_config(config_entries, selected:)
    return ConfigMatch.empty unless enabled?

    catalog = ServersConfig.all!
    return ConfigMatch.empty if catalog.none?(&:brokered?)

    chosen = Array(selected).filter_map { |name| ArtifactIdentity.find(catalog, name.to_s) }.uniq
    config_entries.each_with_object(ConfigMatch.empty) do |(key, entry), match|
      next unless entry.is_a?(Hash)

      candidates = chosen.select { |server| config_key?(server, key) }
      candidates = catalog.select { |server| config_key?(server, key) } if candidates.empty?
      next if candidates.none?(&:brokered?)

      if candidates.one?
        match.servers[key] = candidates.first
      else
        match.refused[key] = "more than one catalog entry is called #{key} (#{candidates.map(&:qualified_name).sort.to_sentence}), " \
          "so the broker cannot tell which one this is"
      end
    end
  end

  def config_key?(server, key) = server.name == key.to_s || ArtifactIdentity.short_id(server.name) == key.to_s

  # Whether a token minted for `server` may be written onto a config entry with
  # this URL: they must be the same resource, or the token would be sent elsewhere.
  def same_resource?(server, url)
    resource = Declaration.for(server)&.resource
    resource.present? && resource == normalize_resource(url)
  end

  # Every catalog entry that declares `brokered_auth`, by authorization server,
  # whether or not the broker is on here. For the Token broker page, which has to
  # show a declaration that is doing nothing and connect a grant before the
  # broker is turned on.
  #
  # @return [Hash{String => Array<Declaration>}]
  def declarations_by_authorization_server
    ServersConfig.all.filter_map { |server| Declaration.for(server) }
      .select(&:valid?)
      .group_by(&:authorization_server)
  end

  # Why the broker could not mint a token for this entry right now, or nil when
  # it could — or when the broker does not authenticate it here at all. Configuration and database only — no network — so the Connectors
  # page and `get_configs` can ask it for every entry.
  #
  # @param server [ServersConfig::Server]
  # @return [String, nil]
  def readiness_problem(server)
    return nil unless enabled?

    declaration = Declaration.for(server)
    return nil if declaration.nil?
    return "its catalog entry's brokered_auth declaration is invalid: #{declaration.error}" unless declaration.valid?

    usable_grant!(declaration.authorization_server, [ declaration ])
    nil
  rescue MintError => e
    e.message
  end

  # Mint the turn's child tokens for every brokered entry among `server_names`.
  #
  # One exchange per authorization server, its scope the sorted union of those
  # entries' scopes. A failure on one authorization server does not touch the
  # others, and never raises: it comes back in `failures`, keyed by entry.
  #
  # @param session [Session]
  # @param server_names [Array<String>] the entries in this turn's MCP config
  # @return [MintResult]
  def mint_for_session(session, server_names, client: Client.new)
    return MintResult.empty unless enabled?

    declarations = Array(server_names).filter_map { |name| declaration_for(name.to_s) }
    return MintResult.empty if declarations.empty?

    result = MintResult.empty
    declarations.reject(&:valid?).each do |declaration|
      result.failures[declaration.server_name] = "its catalog entry's brokered_auth declaration is invalid: #{declaration.error}"
    end

    declarations.select(&:valid?).group_by(&:authorization_server).each do |origin, group|
      token = mint_session_child(session, origin, group, client: client)
      group.each { |declaration| result.tokens[declaration.server_name] = token }
    rescue MintError => e
      group.each { |declaration| result.failures[declaration.server_name] = e.message }
    end
    result
  end

  # A child token for Zimmer's own calls to one brokered entry — MCP Apps, the
  # live modes' tool bridge, event polling, reachability probes. Never a
  # session's token: these are labelled `zimmer:backend`, scoped to the one
  # entry, and reused until BACKEND_TOKEN_MIN_REMAINING before they expire.
  #
  # @param server [ServersConfig::Server]
  # @return [String]
  # @raise [MintError]
  def backend_token(server, client: Client.new, now: Time.current)
    raise MintError, "the token broker is off on this deployment (#{ENABLED_ENV})" unless enabled?

    declaration = Declaration.for(server) || raise(MintError, "#{server.name} does not opt into brokered auth")
    raise MintError, "#{server.name}: #{declaration.error}" unless declaration.valid?

    grant = usable_grant!(declaration.authorization_server, [ declaration ])
    scope = declaration.scopes.join(" ")
    cached = ->(at) {
      grant.brokered_tokens.for_backend.live.where(scope: scope)
        .where("expires_at > ?", at + BACKEND_TOKEN_MIN_REMAINING).order(expires_at: :desc).first
    }
    hit = cached.call(now)
    return hit.token if hit

    # Renew the parent first, outside the lock below: a refresh that fails
    # records why on the grant, and a raise inside that lock's transaction
    # would roll the record back.
    begin
      grant.access_token!(client: client)
    rescue McpBrokerGrant::Unusable => e
      raise MintError, e.message
    end

    # Serialized per grant, and the cache re-read under the lock, so two
    # processes missing the cache at once do not each mint and then revoke
    # the other's token.
    grant.with_lock do
      hit = cached.call(Time.current)
      next hit.token if hit

      row = exchange!(grant, scopes: declaration.scopes, label: BACKEND_LABEL, ttl: BACKEND_TOKEN_TTL,
        purpose: "backend", session: nil, client: client)
      grant.brokered_tokens.for_backend.live.where(scope: scope).where.not(id: row.id).find_each(&:request_revoke!)
      row.token
    end
  end

  # Revoke the children a session minted at or before `rested_at`. A child
  # minted after it belongs to a turn that started since, and is left alone.
  #
  # @return [Integer] how many were revoked now
  def revoke_session_tokens(session_id, rested_at: Time.current, client: Client.new)
    McpBrokeredToken.for_sessions.live.where(session_id: session_id)
      .where("created_at <= ?", rested_at).find_each(&:request_revoke!)

    McpBrokeredToken.revoke_pending.where(session_id: session_id).to_a.count do |row|
      revoke!(row, client: client)
    end
  end

  # One revocation attempt. Success marks the row revoked; a failure schedules
  # the next attempt (McpBrokeredToken::REVOKE_BACKOFF), or — once the token has
  # expired anyway — closes the row as expired.
  #
  # @return [Boolean] whether the revocation landed
  def revoke!(row, client: Client.new, now: Time.current)
    return false unless row.state == "revoke_pending"

    if row.expired?(now)
      row.update!(state: "expired", next_revoke_attempt_at: nil)
      return false
    end

    client.revoke(row.grant, row.token)
    row.revoke_succeeded!(now: now)
    true
  rescue Client::Error, OauthClientIdentity::Unavailable => e
    Rails.logger.warn("[TokenBroker] revoking child #{row.id} (#{row.label}) failed: #{e.message}")
    row.revoke_failed!(e.message, now: now)
    false
  end

  # Called by the session lifecycle hook. Cheap when there is nothing to do: one
  # indexed EXISTS, and no job unless the session holds a live child.
  def session_came_to_rest(session, rested_at: Time.current)
    return unless McpBrokeredToken.for_sessions.live.where(session_id: session.id).exists?

    TokenBrokerRevokeJob.set(wait: TokenBrokerRevokeJob::DELAY).perform_later(session.id, rested_at.utc.iso8601(6))
  end

  # --- internals ---------------------------------------------------------

  def mint_session_child(session, origin, declarations, client:)
    raise MintError, "the session has no id to label its token with" if session&.id.blank?

    grant = usable_grant!(origin, declarations)
    scopes = declarations.flat_map(&:scopes).uniq.sort

    # The previous turn's child for this server: its process is gone, because
    # a turn is starting. Marked first, so a failed exchange below still
    # leaves nothing live behind.
    previous = grant.brokered_tokens.for_sessions.live.where(session_id: session.id).to_a
    previous.each(&:request_revoke!)

    row = exchange!(grant, scopes: scopes, label: "session:#{session.id}", ttl: SESSION_TOKEN_TTL,
      purpose: "session", session: session, client: client)
    TokenBrokerRevokeJob.perform_later(session.id, row.created_at.utc.iso8601(6), only_pending: true) if previous.any?
    row.token
  end

  def usable_grant!(origin, declarations)
    names = declarations.map(&:server_name).to_sentence
    unless OauthClientIdentity.enabled?
      raise MintError, "Zimmer's OAuth client identity is not configured on this deployment " \
        "(#{OauthClientIdentity::BASE_URL_ENV} and a signing key), so no token can be brokered for #{names}"
    end

    grant = McpBrokerGrant.for_authorization_server(origin)
    unless grant
      raise MintError, "no token broker grant exists for #{origin} yet — a human has to connect it once " \
        "on Zimmer's Token broker page before #{names} can be used"
    end
    raise MintError, grant.unusable_message unless grant.active?

    mismatched = declarations.reject { |d| d.resource == TokenBroker.normalize_resource(grant.resource) }
    if mismatched.any?
      raise MintError, "#{mismatched.map(&:server_name).to_sentence} #{mismatched.one? ? 'is' : 'are'} not served by " \
        "the grant for #{origin}, whose resource is #{grant.resource}"
    end
    grant
  end

  def exchange!(grant, scopes:, label:, ttl:, purpose:, session:, client:)
    subject = grant.access_token!(client: client)
    tokens = client.exchange(grant, subject_token: subject, scopes: scopes, label: label, expires_in: ttl.to_i)
    expires_in = tokens.expires_in.to_i.positive? ? tokens.expires_in.to_i : ttl.to_i

    # Stored as asked for, which is what the backend cache looks up by; strad
    # answers with the same set, sorted.
    row = begin
      grant.brokered_tokens.create!(
        purpose: purpose, session: session, label: label, scope: scopes.join(" "),
        token: tokens.access_token, expires_at: Time.current + expires_in.seconds
      )
    rescue StandardError => e
      # strad issued a child that Zimmer could not record. Unrecorded, nothing
      # could revoke or redact it, so it is revoked here, and not handed out.
      begin
        client.revoke(grant, tokens.access_token)
      rescue Client::Error, OauthClientIdentity::Unavailable
        nil
      end
      raise MintError, "a token was issued but could not be recorded (#{e.class}), so it was revoked"
    end
    # The redactor rebuilds its known-value set on a timer; a token that is
    # about to be written into a session's config should be covered now. Its
    # `strad_oat_` shape is also a redaction pattern, as a second line.
    TranscriptRedactor.reset_known_secrets!
    row
  rescue McpBrokerGrant::Unusable => e
    raise MintError, e.message
  rescue Client::Error, OauthClientIdentity::Unavailable => e
    raise MintError, "the authorization server #{grant.authorization_server} did not issue a token: #{e.message}"
  end
end

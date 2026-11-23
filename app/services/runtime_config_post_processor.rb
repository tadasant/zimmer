# frozen_string_literal: true

# Interface for runtime-specific post-processing of the MCP config that the AIR
# CLI writes during `air prepare`.
#
# AIR produces a runtime-native config file (`.mcp.json` for Claude,
# `.codex/config.toml` for Codex). Zimmer then applies a fixed set of conceptually
# runtime-agnostic tweaks to it:
#
#   1. Inject Zimmer's own MCP server when the root declares default_subagent_roots
#      (so parent roots can spawn subagent sessions).
#   2. Inject the self-session Zimmer MCP server unless an existing Zimmer server
#      already covers the self_session tool group.
#   3. Retarget Zimmer MCP server entries at the current Zimmer instance so a
#      local-dev or staging session orchestrates itself, not production, and stamp
#      each with `session_id` so its tools know which session is calling them.
#   4. Write the elicitation address (ELICITATION_REQUEST_URL / _SESSION_ID) into
#      every stdio server's own `env` table, and into the `X-Elicitation-Url`
#      header of every HTTP entry pointing at strad.
#   5. Resolve ${VAR} interpolations from SecretsLoader.
#   6. Pin every npx server's npm cache inside the clone (NPM_CONFIG_CACHE), so no
#      server resolves against the host-shared `~/.npm/_npx`.
#   7. Give every stdio server the MCP startup timeout the runtime needs written
#      into its config — a no-op for a runtime that takes it from the spawn env.
#
# A catalog entry's `command`/`args` are written through verbatim — in particular,
# no `--prefix` is spliced into an npx invocation. `--prefix /tmp` makes npm treat
# /tmp as the project root, so the bin-link destination becomes
# `/tmp/node_modules/.bin`, which is absent on the host; the `chmod 0755` that
# accompanies bin-linking then does not land on the package entrypoint and the
# server dies on `exec` with EACCES for the life of the clone (zimmer#467). It also
# points npm at a host-shared path, defeating the per-clone cache isolation. The
# cache is redirected through the entry's own `env` instead (step 6), which is what
# the catalog entries already assume and needs no prefix flag.
#
# The injected servers are streamable-HTTP entries pointing at this instance's
# native /mcp endpoint (see McpController) — Zimmer speaks MCP itself, so nothing
# is spawned via npx to reach it.
#
# Steps 1-4 and 6 operate purely on the normalized server hash (`command`/`args`/`env`
# for stdio, `url`/header-table for http) that both formats share, so they live
# here as concrete shared logic. Steps tied to the file format and serialization
# (read/parse, server-table extraction, per-entry secret resolution, write) —
# and step 7, which each runtime spells in its own config key or not at all —
# are template-method hooks each concrete subclass implements
# (ClaudeMcpConfigPostProcessor for JSON, CodexConfigTomlPostProcessor for TOML),
# reusing the shared helpers SelfSessionInjector and SecretsInterpolator for the
# format-agnostic value logic.
#
# Subclasses append the names of any auto-injected servers to
# #injected_mcp_servers so callers can record them in session metadata.
class RuntimeConfigPostProcessor
  # The header strad reads a caller's approval URL from, and the one host it is
  # sent to (see #inject_elicitation_header!).
  ELICITATION_URL_HEADER = "X-Elicitation-Url"
  ELICITATION_HEADER_HOST = "strad.tadasant.com"

  attr_reader :session, :working_directory, :file_system, :injected_mcp_servers

  # Whether #inject_brokered_credentials! mints child tokens (a turn is
  # starting) or only leaves brokered entries out. See AirPrepareService.
  attr_accessor :mint_brokered_tokens

  # Session metadata naming the config entries the broker wrote or removed. It is
  # what lets a later prepare know that a file already on the clone is not what
  # AIR (or the seeding a runtime does in its place) would have written, including
  # after the broker was turned off.
  BROKERED_ENTRIES_KEY = "brokered_config_entries"

  # @return [TokenBroker::MintResult] what the broker step did on the last run
  def brokered_token_result
    @brokered_token_result || TokenBroker::MintResult.empty
  end

  # @param session [Session] the session being prepared
  # @param working_directory [String] the session's working directory
  # @param file_system [FileSystemAdapter] injectable file system
  def initialize(session:, working_directory:, file_system:)
    @session = session
    @working_directory = working_directory
    @file_system = file_system
    @injected_mcp_servers = []
  end

  # Post-process the MCP config AIR wrote: inject servers, retarget, resolve
  # secrets. Reads the runtime's config file, mutates it, writes it back.
  #
  # AIR only writes a config file when the session has explicit MCP servers. A
  # session that is skills/hooks/plugins-only (so it takes this prepare! branch)
  # or a subagent-roots-only root can therefore reach here with no file on disk.
  # We must NOT skip in that case: the subagent Zimmer server (for a root with
  # default_subagent_roots) and the self-session Zimmer server are auto-injected
  # here, not by AIR, so gating injection on an AIR-produced file would silently
  # drop a parent root's only spawning server. Synthesize an empty skeleton when
  # the file is absent so injection + retarget + secret resolution + persist all
  # still run. See #ensure_baseline!, which shares this synthesize-when-absent
  # behavior.
  def post_process!
    config = read_or_synthesize_config
    servers = servers_map(config)

    inject_subagent_server!(servers)
    inject_self_session_server!(servers)
    retarget_zimmer_servers_to_current_env!(servers)
    stamp_session_id_on_zimmer_servers!(servers)
    # After the steps that rewrite URLs, so nothing moves an entry that carries a
    # token. Before the elicitation header, which the rewritten entry needs too.
    inject_brokered_credentials!(servers)
    inject_elicitation_env!(servers)
    inject_elicitation_header!(servers)
    resolve_secrets!(servers)
    pin_npx_caches_to_clone!(servers)
    apply_startup_timeouts!(servers)

    persist_config!(config)
    forget_brokered_entries!
  end

  # Ensure a baseline MCP config exists for sessions without explicit MCP
  # servers: create the config file if needed and inject the auto-injected Zimmer
  # servers so every session has basic self-management tools, and every parent
  # root with default_subagent_roots keeps its subagent-spawning server.
  #
  # The subagent Zimmer server must be injected here too (not only in #post_process!):
  # a root whose spawning capability comes purely from auto-injection (no
  # default_mcp_servers/skills/hooks/plugins) routes through this baseline path
  # on regeneration, and omitting the subagent injection here silently strips its
  # only start_session server. The subagent injection deduplicates the
  # self-session server (a full-surface Zimmer server with ALLOWED_AGENT_ROOTS
  # already covers the self_session tool group), so the two injections never
  # write duplicate Zimmer servers.
  def ensure_baseline!
    config = read_or_synthesize_config
    servers = servers_map(config)

    inject_subagent_server!(servers)
    inject_self_session_server!(servers)
    # A session that had MCP servers and no longer does reaches here with the
    # previous run's entries still on the clone, possibly written before the
    # broker was turned on. No turn's token is minted on this path, so a brokered
    # entry is only ever removed.
    removed = inject_brokered_credentials!(servers, mint: false)

    # Nothing injected means no Zimmer entry needs retarget/secret resolution: this
    # path runs only for a session with blank mcp_servers/skills/hooks/plugins, so
    # no catalog `zimmer` entry (which arrives via default_mcp_servers → the
    # post_process! branch) can be present for inject_subagent_server! to skip over.
    # A catalog entry that DID reach here would be left un-retargeted by this early
    # return — but by construction one cannot.
    if injected_mcp_servers.empty? && !removed
      forget_brokered_entries!
      return
    end

    retarget_zimmer_servers_to_current_env!(servers)
    stamp_session_id_on_zimmer_servers!(servers)
    # A no-op today — everything reachable on this path is an auto-injected HTTP
    # Zimmer entry, and only stdio servers have an environment. It runs anyway so
    # the two paths stay identical: a stdio server that ever reaches here must not
    # be the one server on the instance that silently loses its approval address.
    inject_elicitation_env!(servers)
    inject_elicitation_header!(servers)
    resolve_secrets!(servers)
    # Also a no-op today, and for the same reason: nothing reachable here is an npx
    # entry. It runs anyway so the two paths stay identical, on the same argument as
    # the elicitation injection above.
    pin_npx_caches_to_clone!(servers)
    # And again, for the third time and the same reason. This one is the least
    # hypothetical of the three: #read_or_synthesize_config parses whatever
    # `.codex/config.toml` is already on the clone, and a session that HAD explicit
    # MCP servers and no longer does (a follow-up, an unarchive, a fork) reaches
    # here with the previous run's stdio entries still in that file.
    apply_startup_timeouts!(servers)

    persist_config!(config)
    forget_brokered_entries!
  end

  private

  # Read the runtime's config file, or synthesize an empty skeleton when AIR did
  # not write one. Shared by #post_process! and #ensure_baseline! so both run the
  # auto-injections against a real server table regardless of whether an explicit
  # MCP server produced a file on disk.
  def read_or_synthesize_config
    file_system.exists?(config_path) ? parse_config(file_system.read(config_path)) : empty_config
  end

  # --- Format-specific hooks: each concrete runtime implements these. ---

  # @return [String] absolute path to the runtime's native config file.
  def config_path
    raise NotImplementedError, "#{self.class} must implement #config_path"
  end

  # @param raw [String] the file contents
  # @return [Hash] the parsed config
  def parse_config(_raw)
    raise NotImplementedError, "#{self.class} must implement #parse_config"
  end

  # @return [Hash] a fresh, empty config skeleton (used by #read_or_synthesize_config
  #   when AIR wrote no file)
  def empty_config
    raise NotImplementedError, "#{self.class} must implement #empty_config"
  end

  # @param config [Hash] the parsed config
  # @return [Hash] the mutable server table within the config, created if absent
  def servers_map(_config)
    raise NotImplementedError, "#{self.class} must implement #servers_map"
  end

  # The key an HTTP server entry stores its literal header table under
  # ("headers" for Claude's JSON, "http_headers" for Codex's TOML).
  # @return [String]
  def http_headers_key
    raise NotImplementedError, "#{self.class} must implement #http_headers_key"
  end

  # An HTTP MCP server entry in the runtime's native shape.
  # @return [Hash]
  def build_http_entry(url:, headers:)
    raise NotImplementedError, "#{self.class} must implement #build_http_entry"
  end

  # Remove any host-env forwarding rule for the given header, so a literal value
  # written by retargeting survives the rest of the pipeline. Only Codex has such
  # a table; Claude resolves header refs in place, so this is a no-op there.
  def drop_forwarded_credential_header!(_entry, _header)
    nil
  end

  # Remove any host-env forwarding rule for the given env var, for the same
  # reason as the header version above: a forwarding rule and a literal `env`
  # entry for one name is an ambiguity, and the literal one is the value Zimmer
  # means. Only Codex has such a table (`env_vars`); no-op for Claude.
  def drop_forwarded_env_var!(_entry, _name)
    nil
  end

  # Resolve ${VAR} interpolations in every server entry, in the runtime's native
  # field layout. `command`/`args` are otherwise passed through as the catalog
  # wrote them.
  def resolve_secrets!(_servers)
    raise NotImplementedError, "#{self.class} must implement #resolve_secrets!"
  end

  # @param config [Hash] the mutated config
  # @return [String] the serialized config contents
  def serialize_config(_config)
    raise NotImplementedError, "#{self.class} must implement #serialize_config"
  end

  # Write the config back, creating the parent directory first so runtimes whose
  # config lives in a subdirectory (e.g. Codex's .codex/config.toml) work even
  # when AIR did not create the file (ensure_baseline! path).
  def persist_config!(config)
    file_system.mkdir_p(File.dirname(config_path))
    file_system.write(config_path, serialize_config(config))
  end

  # --- Shared, format-agnostic logic. ---

  # When the root declares default_subagent_roots, inject Zimmer's MCP server
  # scoped to those roots (allowed_agent_roots), so parent roots can spawn
  # subagent sessions without explicitly listing a Zimmer MCP server in
  # default_mcp_servers. The entry is full-surface (no tool_groups), which is why
  # it also satisfies the self-session dedup below.
  #
  # Defensive against a name collision, mirroring SelfSessionInjector's dedup: if
  # the catalog already supplies a `zimmer` entry, leave it alone. In the native
  # MCP world every Zimmer variant is the SAME URL differentiated only by query
  # param, so blindly writing servers["zimmer"] would overwrite a catalog-provided
  # full-surface entry with our root-restricted one — silently narrowing
  # start_session's allowed_agent_roots with no error. Skipping keeps
  # start_session's full root surface, and retargeting still points the surviving
  # entry at the current instance.
  #
  # This trusts the catalog's naming convention: the bare `zimmer` key is reserved
  # for the unrestricted, full-surface server, while scoped variants are named
  # `zimmer-*` (see mcp.json). So an entry under this exact key is at least as
  # capable as the one we would inject. A plain key check is therefore enough —
  # unlike the self-session dedup, which must inspect tool_groups because it
  # matches every `zimmer*` name, not one reserved key.
  def inject_subagent_server!(servers)
    root = find_root
    return unless root&.default_subagent_roots&.any?

    name = SelfSessionInjector::SUBAGENT_SERVER_NAME
    if servers.key?(name)
      Rails.logger.info "[#{self.class.name}] Skipping subagent Zimmer server injection: " \
        "a catalog-provided '#{name}' entry is already present."
      return
    end

    servers[name] = build_http_entry(
      url: self_session_injector.endpoint_url(
        allowed_agent_roots: root.default_subagent_roots.join(","),
        session_id: session.id
      ),
      headers: self_session_injector.headers
    )

    injected_mcp_servers << name
  end

  def inject_self_session_server!(servers)
    existing = servers.filter_map do |name, entry|
      next unless entry.is_a?(Hash)
      { name: name, url: entry["url"] }
    end

    injected_name = self_session_injector.inject!(existing_servers: existing, session_id: session.id) do |name, url, headers|
      servers[name] = build_http_entry(url: url, headers: headers)
    end

    injected_mcp_servers << injected_name if injected_name
  end

  # Retarget every Zimmer MCP server entry at the current Zimmer instance.
  #
  # Why: a root's default_mcp_servers may reference a catalog entry whose URL
  # points at production Zimmer. A local-dev or staging session inheriting that
  # entry would orchestrate production instead of its own instance. Rewriting at
  # config-write time lets the same root work against any Zimmer environment
  # without per-env duplication in the catalog. Query-string scoping
  # (tool_groups / allowed_agent_roots) is preserved — only the origin and the
  # API key change.
  #
  # No-op in production, where the catalog's URLs already point at the instance
  # serving the session.
  def retarget_zimmer_servers_to_current_env!(servers)
    return if Rails.env.production?

    target = self_session_injector.self_target
    retargeted_any = false

    servers.each do |name, entry|
      next unless entry.is_a?(Hash)
      next unless self_session_injector.zimmer_server_name?(name)
      next if entry["url"].blank?

      entry["url"] = rebase_url(entry["url"], target[:base_url])
      # A catalog entry's API key arrives as a ${VAR} header ref, which a runtime
      # may carry as a host-env *forwarding* rule resolved later in the pipeline
      # (Codex's env_http_headers). Drop that rule: it names the catalog's var —
      # the production key — and would overwrite the key we are about to write.
      drop_forwarded_credential_header!(entry, SelfSessionInjector::API_KEY_HEADER)
      headers = entry[http_headers_key] ||= {}
      headers[SelfSessionInjector::API_KEY_HEADER] = target[:api_key]
      retargeted_any = true
    end

    # A blank API key means every MCP call 401s with a confusing auth error rather
    # than a clear configuration error. Warn at session-prep time instead.
    if retargeted_any && target[:api_key].blank?
      env_var = Rails.env == "staging" ? "ZIMMER_STAGING_API_KEY" : "ZIMMER_LOCAL_API_KEY"
      Rails.logger.warn "[#{self.class.name}] Retargeted Zimmer MCP servers in #{Rails.env} env with blank API key — " \
        "MCP calls will fail to authenticate. Set #{env_var} in your .env or credentials."
    end
  end

  # Brokered auth (TokenBroker): write every brokered entry the session selected
  # with this turn's child token as its `Authorization`, and leave out every one
  # that got no token.
  #
  # Never a fallback, and never an edit in place. A brokered entry is not passed to
  # AIR at all, every key on disk that is or could be one is removed, and what the
  # session gets is built here from the catalog: the catalog's URL, which is the
  # resource the token was minted for, the child token, and the catalog's other
  # headers, which carry no credential (TokenBroker::Declaration). So nothing an
  # earlier prepare, the repository or the agent left on that entry survives beside
  # the token: no second header, no env forwarding, no other URL. A key the session
  # did not select is removed and nothing is minted for it.
  #
  # "Could not tell" is treated as brokered, never as not: a catalog that cannot be
  # read, or a name that could be two entries, costs those servers the turn. The
  # cause is in #brokered_token_result, which AgentSessionJob writes into the
  # session's log and metadata.
  #
  # Free while the broker is off, apart from taking out what it left behind
  # (#discard_brokered_leftovers!).
  #
  # @return [Boolean] whether any entry was written or removed
  def inject_brokered_credentials!(servers, mint: mint_brokered_tokens)
    @brokered_token_result = TokenBroker::MintResult.empty
    @brokered_entry_names = []
    return discard_brokered_leftovers!(servers) unless TokenBroker.enabled?

    owned = servers.keys.map(&:to_s) - injected_mcp_servers.map(&:to_s)
    plan = begin
      TokenBroker.plan_config(owned, selected: selected_mcp_servers) { |server| brokered_config_key(server) }
    rescue AirCatalogService::CatalogError => e
      cause = "the catalog could not be read (#{e.class}), so Zimmer cannot tell whether it is brokered"
      TokenBroker::ConfigPlan.new(serve: {}, remove: owned, refused: (owned | selected_mcp_servers.map(&:to_s)).index_with { cause })
    end
    return false if plan.empty?

    remember_brokered_entries!(plan.remove | plan.serve.keys | plan.refused.keys)
    plan.remove.each { |key| servers.delete(key) }
    plan.refused.each { |name, cause| @brokered_token_result.failures[name] = cause }
    unselected = plan.remove - plan.serve.keys - plan.refused.keys
    if unselected.any?
      Rails.logger.warn "[#{self.class.name}] Removed #{unselected.join(', ')} from the MCP config: the broker " \
        "authenticates #{unselected.one? ? 'it' : 'them'}, and the session did not select #{unselected.one? ? 'it' : 'them'}"
    end
    return true if plan.serve.empty?

    unless mint
      Rails.logger.info "[#{self.class.name}] Left brokered MCP server(s) #{plan.serve.keys.join(', ')} out of a config " \
        "written outside a turn start; the turn that runs them mints their token"
      return true
    end

    names = plan.serve.values.map(&:name)
    minted = begin
      TokenBroker.mint_for_session(session, names)
    rescue StandardError => e
      # A broker bug must cost the brokered entries, not the whole turn.
      TokenBroker::MintResult.new(tokens: {}, failures: names.index_with { "the token broker raised #{e.class}" })
    end

    plan.serve.each do |key, server|
      if (token = minted.tokens[server.name])
        servers[key] = brokered_entry(server, token)
        @brokered_token_result.tokens[server.name] = token
      else
        @brokered_token_result.failures[server.name] = minted.failures[server.name] || "the token broker gave no reason"
      end
    end
    true
  end

  # The key this runtime's config uses for a catalog server. AIR writes the short id.
  def brokered_config_key(server) = ArtifactIdentity.short_id(server.name)

  def brokered_entry(server, token)
    replaced = [ "authorization", ELICITATION_URL_HEADER.downcase ]
    headers = server.headers.to_h.reject { |header, _| replaced.include?(header.to_s.downcase) }
    entry = build_http_entry(url: server.url, headers: headers.merge("Authorization" => "Bearer #{token}"))
    # `sse` and streamable HTTP are different wire protocols. Codex writes no type.
    entry["type"] = server.type if entry.key?("type") && server.type == "sse"
    entry
  end

  # With the broker off, remove what it left under a key the session does not
  # select: nothing else rewrites those, and they hold a revoked token. A selected
  # entry is AIR's to write back, or Pi's seeding, which reads the same record.
  def discard_brokered_leftovers!(servers)
    record = brokered_entries_on_record
    return false if record.empty?

    selected = selected_mcp_servers.flat_map { |name| [ name.to_s, ArtifactIdentity.short_id(name.to_s) ] }
    (record - selected).count { |key| servers.delete(key) }.positive?
  end

  def selected_mcp_servers
    session.respond_to?(:user_selected_mcp_servers) ? Array(session.user_selected_mcp_servers) : []
  end

  # Recorded BEFORE the config is written: a prepare that dies in between must
  # leave a record of what the broker may have done, not a file nobody knows about.
  # A warm pool's template session is never saved, and has no later prepare to tell.
  def remember_brokered_entries!(names)
    @brokered_entry_names |= names.map(&:to_s)
    return unless session.respond_to?(:merge_metadata!) && session.persisted?

    known = brokered_entries_on_record
    return if (@brokered_entry_names - known).empty?

    session.merge_metadata!({ BROKERED_ENTRIES_KEY => (known | @brokered_entry_names).sort })
  end

  # Once a config with nothing of the broker's in it is on disk, the record is done.
  def forget_brokered_entries!
    return if Array(@brokered_entry_names).any? || brokered_entries_on_record.empty? || !session.persisted?

    session.merge_metadata!({}, [ BROKERED_ENTRIES_KEY ])
  end

  def brokered_entries_on_record
    metadata = session.respond_to?(:metadata) ? session.metadata : nil
    metadata.is_a?(Hash) ? Array(metadata[BROKERED_ENTRIES_KEY]).map(&:to_s) : []
  end

  # Write the approval endpoint's address into every stdio server's own `env`
  # table: ELICITATION_REQUEST_URL (where an approval request goes) and
  # ELICITATION_SESSION_ID (who is asking).
  #
  # Why here and not only in the spawn env: CliSpawnEnv sets both on the agent CLI
  # process, and Claude Code hands a stdio MCP server its own environment, so that
  # was enough there. Codex is not: it builds each server's environment from a
  # fixed whitelist (HOME, LANG, PATH, PWD, SHELL) plus exactly what the entry's
  # own `env`/`env_vars` name. Measured on codex-cli 0.146.0 — a stub stdio server
  # spawned by `codex exec` from a shell with both variables set received neither.
  # So on Codex every approval POST went to the client's baked-in default
  # (`http://zimmer/…`, which does not resolve in the agent container) and died as
  # `fetch failed`: a gate that fails closed and silently, indistinguishable from a
  # human denial. Writing the values into the config the runtime itself hands the
  # server is the one form of "reaching the server" both runtimes honor.
  #
  # Precedence: Zimmer's value wins over a catalog entry's `env` for these two keys
  # specifically. The address of Zimmer's own endpoint is Zimmer's to know, and a
  # catalog copy is a duplicate that can go stale without anything failing loudly —
  # which is exactly what happened: a `http://zimmer` left in a catalog entry
  # shadowed the injected URL for months. An operator who genuinely wants a
  # different endpoint still has the clone's `.env`, which wins here as it does for
  # the agent process (see #elicitation_env).
  #
  # Everything else in the entry is left alone: the values are MERGED into the
  # existing `env` table, never replacing it, because that table is where a
  # server's credentials live.
  def inject_elicitation_env!(servers)
    values = elicitation_env
    return if values.empty?

    written = servers.filter_map do |name, entry|
      next unless entry.is_a?(Hash)
      # stdio only — an HTTP/SSE entry (`url`, no `command`) has no child process
      # and therefore no environment to write.
      next if entry["command"].blank?

      env = (entry["env"] ||= {})
      # An `env` that is not a table is a malformed entry the runtime will reject
      # on its own terms; skip rather than making this step the thing that raises.
      next unless env.is_a?(Hash)

      values.each do |var, value|
        env[var] = value
        drop_forwarded_env_var!(entry, var)
      end
      name
    end

    return if written.empty?

    # Say so in the session log. The failure this fixes was silent on both ends —
    # the server could not reach the endpoint and nothing recorded that it had not
    # been told where the endpoint was. CliSpawnEnv logs the same for the agent
    # process; this is the other half.
    Rails.logger.info "[#{self.class.name}] Wrote #{ElicitationEndpoint::VARIABLES.join(' + ')} " \
      "into the env of #{written.size} stdio MCP server(s): #{written.join(', ')}"
  end

  # The HTTP twin of #inject_elicitation_env!: tell strad where this session's
  # approvals go, as the `X-Elicitation-Url` header on every request it gets.
  #
  # A stdio server learns the address from its environment. A remote server has
  # no environment Zimmer can write, so strad reads it per request instead, and
  # its confirmation-gated tools (a Gmail `send_email` on a slug with
  # `confirmations: true`) refuse — fail-closed — when the header is missing or
  # names anything outside its allow-listed prefix, which is this instance's
  # `/api/v1/elicitations/session/`. A catalog `"${ELICITATION_REQUEST_URL}"`
  # header cannot do this job: #resolve_secrets! fills `${VAR}` from Zimmer's own
  # secrets and ENV, which carry no session, so the value has to be written here,
  # per session.
  #
  # Strad only, matched on the exact host over https. The URL is a capability:
  # whoever holds it can raise approval prompts in this session, so it goes to
  # the one server Zimmer trusts with it and to no other HTTP server, however
  # similar its name.
  #
  # Precedence: Zimmer's value replaces any catalog copy, under any casing of the
  # header name, for the reason #inject_elicitation_env! gives — the address of
  # Zimmer's own endpoint is Zimmer's to know. Unlike the env version, a clone's
  # `.env` does not override it: strad refuses every address but this instance's.
  #
  # The host is read before #resolve_secrets!, so a strad entry whose `url` is a
  # `${VAR}` interpolation does not parse and gets no header. Catalog strad URLs
  # are literals.
  def inject_elicitation_header!(servers)
    return if session&.id.blank?

    url = ElicitationEndpoint.session_url(session.id)

    written = servers.filter_map do |name, entry|
      next unless entry.is_a?(Hash)
      next unless elicitation_header_host?(entry["url"])

      headers = (entry[http_headers_key] ||= {})
      next unless headers.is_a?(Hash)

      headers.delete_if { |header, _| header.to_s.casecmp?(ELICITATION_URL_HEADER) }
      drop_forwarded_credential_header!(entry, ELICITATION_URL_HEADER)
      headers[ELICITATION_URL_HEADER] = url
      name
    end

    return if written.empty?

    Rails.logger.info "[#{self.class.name}] Wrote #{ELICITATION_URL_HEADER}=#{ElicitationEndpoint.loggable_url(url)} " \
      "into the headers of #{written.size} strad MCP server(s): #{written.join(', ')}"
  rescue StandardError => e
    # Same trade as #elicitation_env: a send that strad refuses is a degraded
    # gate, a session that fails to prepare is a dead one.
    Rails.logger.warn "[#{self.class.name}] Skipping #{ELICITATION_URL_HEADER} injection: #{e.class}: #{e.message}"
  end

  def elicitation_header_host?(url)
    return false if url.blank?

    uri = URI.parse(url.to_s)
    uri.scheme == "https" && uri.host.to_s.casecmp?(ELICITATION_HEADER_HOST)
  rescue URI::InvalidURIError
    false
  end

  # Tell every Zimmer MCP entry in this config which session it belongs to.
  #
  # Injection already stamps the entries it writes, but a Zimmer server can also
  # arrive from the catalog (a root's default_mcp_servers), and that entry is the
  # one a session in production is most likely to be holding — retarget is a no-op
  # there, so nothing else would ever add the parameter. The config file is written
  # per session, so stamping the session's own id is always correct.
  #
  # Mostly a DEFAULT for "which session is asking": Mcp::Context uses it to fill in
  # an omitted session_id argument, and `tool_groups` / `allowed_agent_roots` are
  # untouched, so it grants no tool and widens no scope. The one thing it decides
  # beyond that is whether a caller counts as the session it is acting on, which
  # exempts a self-archive from Sessions::LiveTurn's refusal (#400) — so a config
  # stamped with the WRONG session's id hands over that session's exemption.
  #
  # An entry that already names a session is left alone rather than overwritten, so
  # a deliberately hand-pointed entry keeps pointing where it was aimed. That is
  # also why a config generated for the wrong session cannot be repaired by
  # regenerating it, and why ForkSessionService prepares a fork's config for the
  # fork rather than for its source.
  def stamp_session_id_on_zimmer_servers!(servers)
    servers.each do |name, entry|
      next unless entry.is_a?(Hash)
      next unless self_session_injector.zimmer_server_name?(name)
      next if entry["url"].blank?

      entry["url"] = with_session_id(entry["url"], session.id)
    end
  rescue => e
    # Never fatal. Without the stamp the tools simply ask for session_id explicitly,
    # which is the behaviour every session had before this existed.
    Rails.logger.warn(
      "[RuntimeConfigPostProcessor] Could not stamp session_id onto Zimmer MCP entries " \
      "for session #{session.id}: #{e.class}: #{e.message}"
    )
  end

  def with_session_id(url, session_id)
    uri = URI.parse(url.to_s)
    query = Rack::Utils.parse_query(uri.query)
    return url if query["session_id"].present?

    query["session_id"] = session_id.to_s
    uri.query = Rack::Utils.build_query(query)
    uri.to_s
  rescue URI::InvalidURIError
    url
  end

  # Write every `npx`-launched stdio server's npm cache location into its own env
  # table: the clone's shared cache, or an isolated root within it for a server
  # that shares an npx package with another server here.
  #
  # Writing it per entry rather than relying on the agent process's exported
  # NPM_CONFIG_CACHE is the point. A server that inherits nothing resolves against
  # npm's user-level `~/.npm/_npx`, which every session on the host shares and no
  # clone-scoped guard can reach — see NpxCacheIsolator for the two ways that
  # inheritance goes missing, and for what it cost production session 7335.
  #
  # This is the prevention half of the npx-cache story; NpxCacheHealService is the
  # repair half.
  #
  # Runs after #resolve_secrets! so the args it reads are the final ones the
  # runtime will execute.
  def pin_npx_caches_to_clone!(servers)
    return if working_directory.blank?

    shared = NpxCacheIsolator.shared_cache_dir(working_directory)
    isolated = []

    pinned = NpxCacheIsolator.cache_dirs_for(servers, working_directory).filter_map do |name, cache_dir|
      entry = servers[name]
      env = (entry["env"] ||= {})
      next unless env.is_a?(Hash)
      # An explicit cache location in the catalog entry is the operator's call.
      next if env[NpxCacheIsolator::NPM_CACHE_VAR].present?

      env[NpxCacheIsolator::NPM_CACHE_VAR] = cache_dir
      # Codex would otherwise have two sources for one variable (see
      # #inject_elicitation_env!); the literal we just wrote is the one Zimmer means.
      drop_forwarded_env_var!(entry, NpxCacheIsolator::NPM_CACHE_VAR)
      isolated << name unless cache_dir == shared
      name
    end

    return if pinned.empty?

    detail = if isolated.any?
      " #{isolated.size} of them share an npx package (#{isolated.join(', ')}) and got a cache root " \
        "of their own, so their installs cannot race the same _npx directory."
    end

    Rails.logger.info "[#{self.class.name}] Pinned #{NpxCacheIsolator::NPM_CACHE_VAR} inside the clone " \
      "for #{pinned.size} npx MCP server(s): #{pinned.join(', ')}.#{detail}"
  end

  # Write McpStartupTimeout's budget into the config, for a runtime that takes
  # its MCP startup timeout from there rather than from the spawn env.
  #
  # The pairing with #pin_npx_caches_to_clone! is the whole reason this step
  # exists: pinning the cache into the clone is what makes every first launch a
  # cold one, so the runtime has to be willing to wait out the download it just
  # guaranteed. Claude is, via `MCP_TIMEOUT` on the agent process
  # (ClaudeSpawnEnv#configure_mcp_env), which reaches every server it spawns —
  # so the Claude processor leaves this a no-op rather than writing the same
  # budget twice in two places that could disagree.
  #
  # Codex has no such variable and a 30-second default, so it overrides this.
  # Pi has no such variable either, and its MCP client is the `pi-mcp-adapter`
  # extension rather than Pi itself, so PiMcpConfigPostProcessor overrides this
  # too — writing the adapter's per-entry `requestTimeoutMs` over its 60-second
  # SDK default ([#844](https://github.com/tadasant/zimmer/issues/844)).
  #
  # So the default is a no-op for Claude alone, and benignly: its spawn env
  # already carries the budget to every server it spawns, and writing the same
  # budget in two places that could disagree is worse than writing it once.
  #
  # @param _servers [Hash] server name => entry
  def apply_startup_timeouts!(_servers)
    # No-op by default.
  end

  # The elicitation variables as the agent process will see them, so a server's
  # env table and its parent agree: Zimmer's computed values, with the clone's
  # `.env` winning over them exactly as it does in CliSpawnEnv#apply_elicitation_env.
  #
  # The `.env` pass iterates the canonical names rather than what spawn_env
  # returned, so an operator's value is honored even for a name Zimmer itself has
  # nothing to say about (a session-less caller sets no session tag).
  def elicitation_env
    values = ElicitationEndpoint.spawn_env(session_id: session&.id)
    dotenv = EnvFile.load(working_directory, file_system: file_system)

    ElicitationEndpoint::VARIABLES.each do |name|
      values[name] = dotenv[name] if dotenv[name].present?
    end
    values
  rescue StandardError => e
    # A broken .env or an unresolvable base URL must not fail session prep; losing
    # the address is a degraded gate, losing the session is a dead session.
    Rails.logger.warn "[#{self.class.name}] Skipping elicitation env injection: #{e.class}: #{e.message}"
    {}
  end

  # Swap a URL's origin for the current instance's, keeping path and query.
  def rebase_url(url, base_url)
    uri = URI.parse(url.to_s)
    base = URI.parse(base_url.to_s)
    uri.scheme = base.scheme
    uri.host = base.host
    uri.port = base.port
    uri.to_s
  rescue URI::InvalidURIError
    url
  end

  # Look up the AgentRoot object for this session.
  def find_root
    root_name = find_root_name
    return unless root_name.present?
    AgentRootsConfig.find(root_name)
  end

  # Determine the agent root key for this session. Prefers the explicit key
  # stored in session metadata at creation time; falls back to reverse-lookup
  # by URL + subdirectory.
  def find_root_name
    session.metadata&.dig("agent_root_key") ||
      AgentRootsConfig.find_for_session(session)&.name
  end

  def self_session_injector
    @self_session_injector ||= SelfSessionInjector.new(secrets_interpolator: secrets_interpolator)
  end

  # Everything this class resolves is written into the runtime's MCP config,
  # which the agent can read, so the secrets store is never consulted.
  def secrets_interpolator
    @secrets_interpolator ||= SecretsInterpolator.for_agent_surface
  end
end

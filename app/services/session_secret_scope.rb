# frozen_string_literal: true

# Which of Zimmer's secrets a session's clone is allowed to see.
#
# ## The problem this solves
#
# `SecretsLoader.all` is one undifferentiated bundle — every `mcp_secrets` entry
# the deployment holds, around ninety of them in production. Writing all of it
# into every clone's `.env` means a session provisioned with nothing but
# `grafana` still has `SLACK_BOT_TOKEN`, three GCS service-account keys, two
# DigitalOcean tokens and the Cloudflare DNS/WAF read-write pair sitting in its
# process environment. Nothing has leaked — the file is 0600 and gitignored —
# but the session can reach every one of them, and on 2026-08-01 one did: an
# agent booted Zimmer in its own clone, `AlertService` read `SLACK_BOT_TOKEN`
# out of that environment, and the real production `#alerts` channel took seven
# posts from a development-mode health check nobody had asked for
# ([#372](https://github.com/tadasant/zimmer/issues/372)).
#
# ## The rule
#
# A session gets the secrets its own artifacts ask for, and nothing else:
#
#   1. Every `${VAR}` named by a catalog MCP server the session has selected —
#      `ServersConfig::Server#required_variables` + `#optional_variables`, over
#      `Session#user_selected_mcp_servers` (explicit + plugin-bundled).
#      This is the bulk of it: 66 of the 86 production catalog entries declare
#      their credential this way, and that declaration is already how the server
#      gets its value at all (SecretsInterpolator resolves it into the entry's
#      own `env`/`headers` table before the server is launched).
#   2. Every `$VAR` / `${VAR}` a catalog *skill or hook* the session carries
#      mentions in its own files, intersected with the names Zimmer actually
#      holds. Some skills tell the agent to run a command with a credential in it
#      — `manage-secrets-for-zimmer` curls strad with `${STRAD_API_KEY}` — and no
#      MCP server declares that for them. The intersection is what makes this
#      safe: a skill cannot invent a name, only select one Zimmer already has.
#   3. Whatever `ZIMMER_SESSION_ENV_EXTRA_KEYS` names, for the deployment-wide
#      exception that turns out to be needed after the fact.
#
# ## What is deliberately NOT in it
#
# - **References.** They are prose Zimmer injects for context, and the secrets
#   references alone name three dozen credentials in passing. A skill is a
#   procedure the agent is told to execute; a reference is background reading.
#   Scanning them would put most of the bundle back.
# - **Anything the Rails app in the clone reads at runtime.** `AlertService`
#   reading `SLACK_BOT_TOKEN`, `TriggerCondition` reading
#   `SLACK_BOT_MENTION_ALLOWED_USER_IDS` — those are the harm, not a requirement.
#   A clone needs no `mcp_secrets` entry to run `bin/rails`: its database comes
#   from `config/database.yml` and `CliSpawnEnv#clear_inherited_env_vars`, and
#   its master key from the image.
# - **A name only mentioned without a `$`.** Prose that says "set
#   `GITHUB_PERSONAL_ACCESS_TOKEN`" is talking *about* the variable; `$GITHUB_…`
#   is using it. Requiring the sigil errs toward writing fewer keys, which is the
#   direction this class is supposed to err in.
#
# ## Getting back what a narrowing took away
#
# Three ways out, smallest blast radius first:
#
#   1. **Per session** — attach the MCP server that declares the variable
#      (`change_mcp_servers` / the Servers picker). The `.env` is rewritten on
#      the next prepare, which is the next turn.
#   2. **Fleet-wide, one variable** — `ZIMMER_SESSION_ENV_EXTRA_KEYS=A,B` in the
#      deploy config.
#   3. **Fleet-wide, everything** — `ZIMMER_SESSION_ENV_SCOPE=all` hands every
#      clone the whole bundle again. One deploy-time variable, no code change and
#      no shell on the box.
class SessionSecretScope
  # Deploy-time switch. Anything other than `all` (the default being unset) means
  # scoped. Spelled as an opt-OUT rather than an opt-in so the safe mode is what a
  # deployment gets by forgetting to configure anything.
  MODE_VARIABLE = "ZIMMER_SESSION_ENV_SCOPE"
  UNSCOPED_MODE = "all"

  # Comma-separated secret names every clone gets regardless of its artifacts.
  # Empty by default: nothing in the bundle is needed by a clone for a reason no
  # artifact declares.
  EXTRA_KEYS_VARIABLE = "ZIMMER_SESSION_ENV_EXTRA_KEYS"

  # `$VAR` or `${VAR}` (with or without a `:-default`) inside an artifact's own
  # files. Deliberately looser than SecretsInterpolator::ENV_VAR_PATTERN, which
  # only has to recognize a well-formed interpolation in a config value — here we
  # are reading hand-written markdown and shell, where `$STRAD_API_KEY` appears
  # bare as often as `${STRAD_API_KEY}`. The looseness costs nothing because
  # every match is intersected with the names Zimmer holds before it is used.
  ARTIFACT_REFERENCE_PATTERN = /\$\{?([A-Z][A-Z0-9_]{2,})\}?/

  # Bounds on the artifact body scan. The catalog's largest skill is ~200 KB and
  # the biggest skill directory holds seven files, so these are ceilings that
  # never bind in practice — they exist so a catalog that grows a binary blob or
  # a thousand-file skill cannot turn session prep into an unbounded read.
  MAX_FILES_PER_ARTIFACT = 32
  MAX_BYTES_PER_FILE = 1.megabyte

  class << self
    # The subset of `available_keys` this session's clone may hold.
    #
    # @param session [Session]
    # @param available_keys [Array<String>] every secret name Zimmer holds
    # @param env [Hash] injectable process environment (for tests)
    # @return [Array<String>] a subset of available_keys, sorted
    def allowed_keys(session:, available_keys:, env: ENV)
      available = Array(available_keys).map(&:to_s).to_set
      return available.to_a.sort if unscoped?(env: env)

      named = mcp_server_variables(session) +
        artifact_variables(session) +
        extra_keys(env: env)

      named.select { |name| available.include?(name) }.uniq.sort
    end

    # True when this deployment has opted out of scoping entirely.
    def unscoped?(env: ENV)
      env[MODE_VARIABLE].to_s.strip.downcase == UNSCOPED_MODE
    end

    # Every `${VAR}` the session's selected MCP servers declare — the catalog's own
    # server→credential map, read through the same objects that decide whether a
    # server is configured at all.
    #
    # A name the catalog does not know contributes nothing rather than raising:
    # a server id that no longer resolves is already absent from the session's
    # `.mcp.json`, so giving its credential to the clone would hand out a secret
    # for a server that is not there.
    #
    # @return [Array<String>]
    def mcp_server_variables(session)
      server_names(session).flat_map do |name|
        server = ServersConfig.find(name)
        server ? server.required_variables + server.optional_variables : []
      end
    rescue StandardError => e
      # A catalog that cannot resolve must not stop a session spawning. It fails
      # CLOSED — the clone gets fewer keys, not more — because the alternative is
      # a broken catalog silently restoring the whole bundle.
      Rails.logger.warn "[SessionSecretScope] Could not read MCP server variables: #{e.class}: #{e.message}"
      []
    end

    # Every `$VAR` the session's skills and hooks mention in their own files.
    # @return [Array<String>]
    def artifact_variables(session)
      artifact_paths(session).flat_map { |path| variables_in_directory(path) }
    rescue StandardError => e
      Rails.logger.warn "[SessionSecretScope] Could not read artifact variables: #{e.class}: #{e.message}"
      []
    end

    private

    # Explicit + plugin-bundled — the servers someone chose for this session.
    #
    # The auto-injected Zimmer servers are deliberately left out. The self-session
    # server is injected into EVERY session, and its catalog entry authenticates
    # with `${ZIMMER_PROD_API_KEY}` — a key to Zimmer's whole API — so counting it
    # would hand that key to every clone. The agent does not need it in its shell:
    # RuntimeConfigPostProcessor resolves the key straight into the injected
    # entry's own header, and that is the only place the server reads it from. A
    # session that was given a Zimmer server by name still gets the key, because
    # someone decided it should.
    def server_names(session)
      session.user_selected_mcp_servers
    end

    def artifact_paths(session)
      skills = (Array(session.catalog_skills) + session.plugin_derived_skills.keys).uniq
      hooks = (Array(session.catalog_hooks) + session.plugin_derived_hooks.keys).uniq

      skills.filter_map { |id| SkillsConfig.find(id)&.absolute_path } +
        hooks.filter_map { |id| HooksConfig.find(id)&.absolute_path }
    end

    def variables_in_directory(path)
      return [] if path.blank? || !File.directory?(path)

      # Symlinks are skipped: a link inside a skill directory could otherwise put
      # an arbitrary file outside it in front of the scan.
      Dir.glob(File.join(path, "**", "*"))
        .select { |entry| File.file?(entry) && !File.symlink?(entry) }
        .sort
        .first(MAX_FILES_PER_ARTIFACT)
        .flat_map { |entry| variables_in_file(entry) }
    end

    def variables_in_file(entry)
      return [] if File.size(entry) > MAX_BYTES_PER_FILE

      content = File.read(entry, encoding: "BINARY").force_encoding(Encoding::UTF_8)
      return [] unless content.valid_encoding?

      content.scan(ARTIFACT_REFERENCE_PATTERN).flatten
    rescue SystemCallError
      []
    end

    def extra_keys(env:)
      env[EXTRA_KEYS_VARIABLE].to_s.split(",").filter_map { |name| name.strip.presence }
    end
  end
end

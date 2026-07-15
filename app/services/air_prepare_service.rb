# frozen_string_literal: true

require "digest"
require "tmpdir"

# Service to prepare a session's working directory using the AIR CLI.
#
# AIR CLI resolves the air.json entry point, selects the requested skills and
# MCP servers, writes the runtime's native MCP config (`.mcp.json` for Claude),
# and injects skills + references. The @pulsemcp/air-secrets-env transform
# resolves ${VAR} patterns from process.env during `air prepare`.
#
# The AIR adapter to prepare with (`air prepare <adapter>`) is sourced from the
# session's runtime via RuntimeRegistry, so each runtime declares its own
# adapter id (claude → "claude", codex → "codex"). After AIR runs, this service
# hands off to the runtime's RuntimeConfigPostProcessor, which resolves
# remaining ${VAR} interpolations from SecretsLoader and applies Zimmer-specific
# tweaks (server injection, env retargeting, npx --prefix) in the runtime's
# native config format.
class AirPrepareService
  class AirPrepareError < StandardError; end

  # Raised when `air prepare --root <name>` reports that the named root is not in
  # the resolved AIR catalog. Distinct from AirPrepareError so AgentSessionJob can
  # treat an unresolvable root as a graceful session failure (logged at WARN)
  # rather than letting an unhandled error bubble to ActiveJob and page
  # #eng-alerts. The two causes are (1) a freshly-merged root whose definition
  # hasn't propagated to this worker's AIR github cache yet — a self-resolving
  # propagation race, since CatalogRefreshJob runs `air update` only every 15 min
  # — and (2) a genuinely bad root name. Neither is broken-system behavior, so
  # neither should page.
  class RootResolutionError < AirPrepareError; end

  # Raised when `air prepare` reports that a ${VAR} interpolated by one of the
  # session's selected MCP servers (or hooks) could not be resolved from the
  # environment or a secrets transform. Sibling to RootResolutionError, and for
  # the same reason: this is a deterministic, non-retryable, session-scoped
  # *configuration* problem — the selected artifact needs a secret that Zimmer's
  # SecretsLoader does not carry — not broken-system behavior. Retrying never
  # helps and nothing is wrong server-side, so AgentSessionJob fails the session
  # gracefully at WARN rather than letting an unhandled error bubble to
  # ActiveJob and page #eng-alerts. The fix is always operator-side: add the
  # variable to Zimmer's `mcp_secrets` credentials, or stop selecting that server.
  # Carries the offending variable names so the failure message can tell the
  # operator exactly which secret to provision.
  class SecretResolutionError < AirPrepareError
    attr_reader :variable_names

    def initialize(message, variable_names: [])
      super(message)
      @variable_names = variable_names
    end
  end

  # Raised when `air prepare` reports that a selected skill / MCP server / hook /
  # plugin id is absent from the resolved AIR catalog — AIR's adapters emit
  # `Unknown <type> ID "<id>". Available: ...`. Sibling to RootResolutionError, and
  # for the same reason: the caller asked for an artifact that does not exist, which
  # is a deterministic, non-retryable, session-scoped *configuration* problem, not
  # broken-system behavior. The usual cause is a renamed or removed catalog id still
  # referenced by a persisted session/trigger — e.g. the skill `pr` renamed to
  # `open-pr` in the catalog while a daily trigger still requested `pr`. Retrying
  # never helps and nothing is wrong server-side, so AgentSessionJob fails the
  # session gracefully at WARN rather than letting an unhandled error bubble to
  # ActiveJob and page #eng-alerts. Carries the offending artifact type and id so
  # the failure message can tell the owner exactly which id to fix.
  class ArtifactResolutionError < AirPrepareError
    attr_reader :artifact_type, :artifact_id

    def initialize(message, artifact_type: nil, artifact_id: nil)
      super(message)
      @artifact_type = artifact_type
      @artifact_id = artifact_id
    end
  end

  AIR_CLI_VERSION = "0.13.0"

  # Hard wall-clock cap for a single `air prepare` invocation. AIR shells out to
  # `git clone` for the catalog repo (tadasant/zimmer-catalog) over HTTPS to github.com;
  # a half-open connection during fetch-pack can hang that clone forever. Because
  # run_air_prepare! runs synchronously inside AgentSessionJob on the
  # `waiting → running` launch path, a hung `air prepare` would wedge the session
  # in `waiting` with no output and no recovery. The watchdog (BoundedSubprocess)
  # SIGKILLs the whole process group when this is exceeded. The default is
  # generous because a cold catalog clone of the monorepo plus skill/MCP
  # resolution is legitimately slow. Overridable via ENV for ops tuning.
  AIR_PREPARE_TIMEOUT_SECONDS = Integer(ENV.fetch("AIR_PREPARE_TIMEOUT_SECONDS", "600"))

  # Backoff (seconds) between retries when `air prepare` fails transiently — e.g.
  # the catalog clone hits a github.com `ETIMEDOUT` or stalls and is watchdog-
  # killed. Mirrors GitCloneService's clone retry. Overridable via ENV as a
  # comma-separated list; the number of retries is the list length.
  AIR_PREPARE_RETRY_DELAYS_SECONDS =
    (ENV["AIR_PREPARE_RETRY_DELAYS_SECONDS"]&.split(",")&.map { |s| Integer(s.strip) }).presence ||
    [ 5, 10, 20 ].freeze

  # `air prepare` failures worth retrying. AIR shells out to `git clone` for the
  # catalog repo, so a transient github.com hiccup surfaces here as a non-zero
  # exit carrying one of these signatures (or as a watchdog TimeoutError, which is
  # always retried). Reuses GitCloneService's transient git patterns and adds the
  # signatures AIR's own clone wrapper emits (`spawnSync git ETIMEDOUT`,
  # `Failed to clone …`).
  TRANSIENT_AIR_PREPARE_PATTERNS = Regexp.union(
    GitCloneService::TRANSIENT_CLONE_ERROR_PATTERNS,
    /ETIMEDOUT/,
    /ECONNRESET/,
    /EAI_AGAIN/,
    /Failed to clone/,
    /spawnSync git/
  )

  # Signature AIR emits (exit 1) when `--root <name>` names a root absent from the
  # resolved catalog: `Error: Root "<name>" not found. Available roots: ...`. The
  # quoted-name + "not found" shape is the stable anchor. Matched in
  # run_air_prepare_command! to trigger a one-time catalog-cache refresh + retry,
  # and ultimately to raise RootResolutionError (a graceful, non-paging failure)
  # rather than a plain AirPrepareError that would page as an unhandled job crash.
  ROOT_NOT_FOUND_PATTERN = /Root\s+"[^"]*"\s+not found/

  # Signature AIR's adapters emit (exit 1) when a selected skill / MCP server /
  # hook / plugin id is absent from the resolved catalog. Built by air-adapter's
  # `resolveActivations` (see @pulsemcp/air-adapter-claude claude-adapter.js):
  #
  #   Unknown <type> ID "<id>". Available: <keys> (<n> total).
  #
  # where <type> is one of skill, MCP server, hook, plugin. The `Unknown … ID "…"`
  # shape is the stable anchor, and the quoted id is captured so the failure
  # message can name it. Matched in run_air_prepare_command! to bust a
  # possibly-stale catalog cache once and retry — a just-added id may not have
  # propagated to this worker yet, the same race ROOT_NOT_FOUND_PATTERN handles —
  # and ultimately to raise ArtifactResolutionError (a graceful, non-paging
  # failure) rather than a plain AirPrepareError that would page as an unhandled
  # job crash. The commonest cause is the mirror image: a renamed/removed id still
  # requested by a persisted session/trigger, where the refresh can't help and the
  # graceful failure is the point.
  UNKNOWN_ARTIFACT_PATTERN = /Unknown (skill|MCP server|hook|plugin) ID "([^"]*)"/

  # Signature AIR emits (exit 1) when a selected MCP server or hook interpolates a
  # ${VAR} that neither the environment nor the @pulsemcp/air-secrets-env transform
  # can resolve. Built by air-sdk's `unresolvedVarsMessage(configPath, unresolved)`
  # (see @pulsemcp/air-sdk validate-config.js, pinned via AIR_CLI_VERSION):
  #
  #   Unresolved variable{s} in <targetDir>: ${A}, ${B}. Ensure all variables are
  #   provided via environment or a secrets transform.
  #
  # The "Unresolved variable" prefix plus the `${…}` token list is the stable
  # anchor. Note the message is pluralized and can carry several comma-separated
  # variables, and air-sdk's own extractor (`/\$\{([^}]+)\}/g`) does not constrain
  # the name charset — so neither do we. Matched in run_air_prepare_command! to
  # raise SecretResolutionError immediately: no retry, no catalog refresh.
  #
  # Deliberately NOT multiline: AIR emits this as a single line (it can be preceded
  # by unrelated warning lines in the same stderr). Letting `.` cross newlines would
  # allow the prefix on one line to bind to a `${…}` on a later, unrelated one.
  UNRESOLVED_VARIABLE_PATTERN =
    /Unresolved variables? in .*?: (\$\{[^}]+\}(?:, \$\{[^}]+\})*)/

  # Pulls the bare names out of the `${A}, ${B}` token list captured above.
  VARIABLE_TOKEN_PATTERN = /\$\{([^}]+)\}/

  # Where the AIR CLI npm packages are installed. Overridable via ENV so CI
  # runners (which can't write to /opt) can redirect to a user-writable path.
  # Default prefers /opt/air-cli when the parent dir is writable (Docker
  # production), falling back to a user cache directory otherwise.
  AIR_INSTALL_DIR = ENV.fetch("AIR_INSTALL_DIR") do
    File.writable?("/opt") || File.directory?("/opt/air-cli") ? "/opt/air-cli" : File.join(Dir.home, ".cache", "air-cli")
  end

  class << self
    # Ensure the AIR CLI is installed. Idempotent: no-op if the expected version
    # is already present. Callable from any context that needs the AIR binary
    # (AirCatalogService, AirPrepareService#run_air_prepare!).
    #
    # Install is serialized across processes via a flock on a sibling lockfile
    # so parallel test workers / concurrent web requests don't race on the same
    # AIR_INSTALL_DIR. The fast path (marker + binary file exists) short-circuits
    # before acquiring the lock.
    #
    # We deliberately do NOT run `air --version` in the fast/lock-check paths:
    # under heavy parallel load (32 CI test workers) the check can spuriously
    # fail, triggering a reinstall whose rm_rf destroys files other workers are
    # actively using. The marker is only touched after install + health check
    # succeed, so its presence is proof the install was valid. Health is
    # re-verified inside install_air_cli! for fresh installs.
    def ensure_air_installed!
      marker = File.join(AIR_INSTALL_DIR, ".air-version-#{AIR_CLI_VERSION}")
      binary = File.join(AIR_INSTALL_DIR, "node_modules", ".bin", "air")
      return if File.exist?(marker) && File.exist?(binary)

      with_install_lock do
        # Double-check after acquiring the lock: another process may have just
        # finished installing while we were waiting.
        return if File.exist?(marker) && File.exist?(binary)

        install_air_cli!(marker, binary)
      end
    end

    # Run `air --version` to verify the binary is functional.
    def air_binary_healthy?(binary)
      return false unless File.exist?(binary)

      Timeout.timeout(10) do
        _stdout, _stderr, status = Open3.capture3(binary, "--version")
        status.success?
      end
    rescue StandardError, Timeout::Error
      false
    end

    private

    def install_air_cli!(marker, binary)
      FileUtils.rm_rf(AIR_INSTALL_DIR)
      FileUtils.mkdir_p(AIR_INSTALL_DIR)
      packages = [
        "@pulsemcp/air-cli@#{AIR_CLI_VERSION}",
        "@pulsemcp/air-adapter-claude@#{AIR_CLI_VERSION}",
        "@pulsemcp/air-adapter-codex@#{AIR_CLI_VERSION}",
        "@pulsemcp/air-secrets-env@#{AIR_CLI_VERSION}",
        "@pulsemcp/air-provider-github@#{AIR_CLI_VERSION}"
      ]
      install_cmd = [ "npm", "install", "--prefix", AIR_INSTALL_DIR ] + packages

      Rails.logger.info "[AirPrepareService] Installing AIR packages: #{packages.join(', ')}"
      _stdout, stderr, status = Open3.capture3(*install_cmd)

      unless status.success?
        raise AirPrepareError, "Failed to install AIR packages: #{stderr}"
      end

      unless air_binary_healthy?(binary)
        raise AirPrepareError,
          "AIR CLI installed but binary is broken (#{binary} --version failed). " \
          "This usually means a broken npm publish of @pulsemcp/air-cli@#{AIR_CLI_VERSION}."
      end

      FileUtils.touch(marker)
    end

    # Acquire an exclusive flock on a sibling lockfile so concurrent callers
    # (parallel test workers, concurrent web requests) serialize on install.
    # The lockfile lives in /tmp (universally writable) rather than inside
    # AIR_INSTALL_DIR so it isn't clobbered by the rm_rf + mkdir_p rebuild.
    def with_install_lock(&block)
      lock_key = Digest::SHA1.hexdigest(AIR_INSTALL_DIR)[0, 12]
      lock_path = File.join(Dir.tmpdir, "air-cli-#{lock_key}.install.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    end
  end

  attr_reader :session, :working_directory, :file_system

  # @param session [Session] the session being prepared
  # @param working_directory [String] the session's working directory
  # @param file_system [FileSystemAdapter] injectable file system (default: RealFileSystemAdapter)
  # @param sleeper [#call] injectable sleeper for retry backoff (default: Kernel.sleep);
  #   tests pass a no-op to exercise the retry loop without real delays.
  def initialize(session:, working_directory:, file_system: nil, sleeper: nil)
    @session = session
    @working_directory = working_directory
    @file_system = file_system || RealFileSystemAdapter.new
    @sleeper = sleeper || ->(seconds) { Kernel.sleep(seconds) }
  end

  # Prepare a session: run AIR CLI then hand off to the runtime's config
  # post-processor. After completion, #injected_mcp_servers contains names of
  # servers that were auto-injected (e.g. zimmer for subagent roots).
  def prepare!
    run_air_prepare!
    post_processor.post_process!
    write_system_prompt_file!
  end

  # Ensure baseline self-session MCP config exists for sessions without explicit
  # MCP servers. Delegates to the runtime's config post-processor.
  def ensure_baseline_mcp_config!
    post_processor.ensure_baseline!
    write_system_prompt_file!
  end

  # Names of servers the post-processor auto-injected during prepare! /
  # ensure_baseline_mcp_config! (e.g. zimmer for subagent roots).
  def injected_mcp_servers
    post_processor.injected_mcp_servers
  end

  private

  # Deliver the orchestrator system prompt to disk for runtimes that consume it
  # from a file rather than a CLI flag (Codex reads `AGENTS.md`; Claude appends it
  # via `--append-system-prompt` at spawn time, so this is a no-op for Claude).
  def write_system_prompt_file!
    return unless RuntimePromptContribution.for(session.agent_runtime).delivered_via_file?

    AgentsMdWriter.new(
      session: session,
      working_directory: working_directory,
      file_system: file_system
    ).write!
  end

  # The runtime's config post-processor, resolved from RuntimeRegistry by the
  # session's agent_runtime. Memoized so #injected_mcp_servers reflects what
  # prepare! / ensure_baseline_mcp_config! injected.
  def post_processor
    @post_processor ||= session.runtime.config_post_processor_class.new(
      session: session,
      working_directory: working_directory,
      file_system: file_system
    )
  end

  # Install AIR CLI + adapter once, then invoke the binary directly.
  # npx can't resolve adapter peer packages, so we install both into a shared
  # prefix and call the binary from node_modules/.bin/.
  def run_air_prepare!
    self.class.ensure_air_installed!

    cmd = [
      File.join(AIR_INSTALL_DIR, "node_modules", ".bin", "air"),
      "prepare",
      # The AIR adapter id for this session's runtime (claude → "claude",
      # codex → "codex"), declared by the runtime's RuntimeRegistry bundle.
      session.runtime.air_adapter_name,
      "--target", working_directory,
      "--no-subagent-merge",
      # AIR v0.0.30 flipped skill/mcp/hook/plugin flag semantics from "replace root
      # defaults" to "add to root defaults". Zimmer already stores the final resolved
      # session lists in session.catalog_skills / mcp_servers / catalog_hooks /
      # catalog_plugins (UI PATCH endpoints mutate these). Without this flag, if a
      # user removes a default artifact via the UI, AIR silently re-adds it from
      # the root defaults. --without-defaults tells AIR to start from an empty
      # selection and honor only the flags we pass.
      "--without-defaults"
    ]

    root_name = find_root_name
    cmd += [ "--root", root_name ] if root_name.present?

    # AIR 0.0.32 switched artifact-selection flags from plural + comma-separated
    # (`--skills a,b`) to singular + variadic (`--skill a --skill b`). The plural
    # forms are no longer accepted by the CLI parser. Repeat each flag per value
    # so Commander collects them unambiguously regardless of adjacent flags.
    cmd += session.catalog_skills.flat_map { |id| [ "--skill", id ] } if session.catalog_skills.present?
    effective_mcp_servers = session.user_selected_mcp_servers
    cmd += effective_mcp_servers.flat_map { |id| [ "--mcp-server", id ] } if effective_mcp_servers.present?
    cmd += session.catalog_hooks.flat_map { |id| [ "--hook", id ] } if session.catalog_hooks.present?
    cmd += session.catalog_plugins.flat_map { |id| [ "--plugin", id ] } if session.catalog_plugins.present?

    Rails.logger.info "[AirPrepareService] Running: #{cmd.join(' ')}"

    # AIR CLI looks up its config in this order: --config flag, AIR_CONFIG env, ~/.air/air.json.
    # We pass AIR_CONFIG so Zimmer's Rails-level air.json setting drives the CLI.
    # effective_air_json_path applies any UI-configured catalog pins, so sessions
    # resolve the same frozen catalog refs as the rest of the app.
    env = SecretsLoader.all.merge("AIR_CONFIG" => AirCatalogService.effective_air_json_path)

    run_air_prepare_command!(cmd, env)

    Rails.logger.info "[AirPrepareService] AIR prepare completed successfully"
  end

  # Invoke `air prepare` under a watchdog timeout, retrying with backoff on
  # transient failures.
  #
  # AIR shells out to `git clone` for the catalog repo, and that clone is the
  # observed flaky dependency (transient github.com `ETIMEDOUT`/stalls during a
  # post-deploy clone stampede). Two failure modes are bounded here:
  #   - AIR exits non-zero with a transient clone signature → retried.
  #   - `air prepare` hangs on a half-open connection → the BoundedSubprocess
  #     watchdog SIGKILLs the process group and raises TimeoutError → retried
  #     (and, on the launch path, prevents a session wedged in `waiting`).
  # A non-transient failure (bad config) raises immediately so we don't
  # pointlessly retry a deterministic error.
  #
  # One non-transient failure gets special handling: "Root not found". When a
  # session names a root that was merged to the catalog only minutes ago, this
  # worker's AIR github cache can still be stale (CatalogRefreshJob runs
  # `air update` only every 15 min), so `air prepare --root <name>` fails even
  # though the root is valid. Per the obs-triage philosophy ("never wait for the
  # next scheduled run instead of retrying"), we bust the cache inline once (a
  # bounded `air update`) and retry rather than failing. If the root is still
  # absent after a fresh catalog, it's a genuinely bad name — we raise
  # RootResolutionError (a graceful, non-paging failure) so AgentSessionJob can
  # fail the session cleanly instead of letting it page #eng-alerts.
  #
  # An unknown skill/MCP/hook/plugin id ("Unknown <type> ID") gets the same
  # refresh-once-then-fail-gracefully treatment as a bad root, raising
  # ArtifactResolutionError. A freshly-added id can hit the same propagation race,
  # so we refresh once; but the commonest cause is a renamed/removed id still
  # requested by a persisted session/trigger, which the refresh can't fix — that's
  # exactly when the graceful, non-paging failure matters.
  #
  # An unresolved ${VAR} gets the same graceful treatment via
  # SecretResolutionError, but without the refresh-and-retry dance: a missing
  # secret is not a propagation race, so it is raised on the first attempt.
  def run_air_prepare_command!(cmd, env)
    attempt = 0
    max_attempts = AIR_PREPARE_RETRY_DELAYS_SECONDS.length + 1
    catalog_refreshed = false

    # Unlike GitCloneService (which rm -rf's the clone dir between attempts), we
    # re-run `air prepare` over the same target without cleanup: the failure mode
    # we retry is the catalog clone, which AIR performs into its own cache before
    # writing the target, and `air prepare` is idempotent over its own output —
    # so a transient failure leaves nothing partial to clear.
    loop do
      attempt += 1

      begin
        stdout, stderr, status =
          BoundedSubprocess.run(cmd, env: env, timeout: AIR_PREPARE_TIMEOUT_SECONDS)

        return if status.success?

        error = AirPrepareError.new(
          "AIR prepare failed (exit #{status.exitstatus}): #{stderr.presence || stdout}"
        )
        transient = transient_air_failure?(error.message)
        root_not_found = ROOT_NOT_FOUND_PATTERN.match?(error.message)
        unknown_artifact = UNKNOWN_ARTIFACT_PATTERN.match(error.message)
        unresolved_variables = unresolved_variable_names(error.message)
      rescue BoundedSubprocess::TimeoutError => e
        # A watchdog kill means `air prepare` hung — most likely the catalog clone
        # stalled on a half-open github.com connection. The process group has been
        # killed, so a retry starts clean. Always treat as transient.
        error = AirPrepareError.new(
          "AIR prepare timed out after #{AIR_PREPARE_TIMEOUT_SECONDS}s (process group killed): #{e.message}"
        )
        transient = true
        root_not_found = false
        unknown_artifact = nil
        unresolved_variables = []
      end

      # An unresolved ${VAR} is deterministic and operator-fixable: the selected
      # MCP server needs a secret Zimmer doesn't carry. Retrying and refreshing the
      # catalog are both pointless, so raise straight away — gracefully, so the
      # job layer fails the session instead of crashing and paging #eng-alerts.
      if unresolved_variables.any?
        Rails.logger.warn(
          "[AirPrepareService] AIR prepare could not resolve required variable(s) " \
          "variables=#{unresolved_variables.join(",")} attempts=#{attempt} error=#{error.message}"
        )
        raise SecretResolutionError.new(error.message, variable_names: unresolved_variables)
      end

      # Root-not-found and unknown-artifact (skill/MCP/hook/plugin id) are both
      # catalog-resolution failures that can be a stale-cache propagation race for a
      # freshly-merged id: bust the (possibly stale) catalog cache once and retry.
      # The refresh is bounded and best-effort — if it fails we fall through to
      # raising the graceful config error below rather than masking the original.
      if (root_not_found || unknown_artifact) && !catalog_refreshed
        catalog_refreshed = true
        Rails.logger.info(
          "[AirPrepareService] AIR prepare reported an unresolvable catalog id; refreshing " \
          "catalog cache and retrying once attempt=#{attempt} error=#{error.message}"
        )
        refresh_catalog_cache!(env)
        next
      end

      # Root still absent after a fresh catalog (or the refresh failed): a
      # graceful, non-paging failure. Distinct from AirPrepareError so the job
      # layer can fail the session cleanly instead of re-raising into a paging
      # job crash.
      if root_not_found
        Rails.logger.warn(
          "[AirPrepareService] AIR prepare root unresolvable after catalog refresh " \
          "attempts=#{attempt} error=#{error.message}"
        )
        raise RootResolutionError, error.message
      end

      # Artifact id still unknown after a fresh catalog: the caller asked for a
      # skill/MCP/hook/plugin that does not exist — typically a renamed or removed
      # catalog id still referenced by a persisted session/trigger. Deterministic
      # and operator-fixable, so fail gracefully (WARN + ArtifactResolutionError)
      # instead of raising a plain AirPrepareError that would page as a job crash.
      if unknown_artifact
        Rails.logger.warn(
          "[AirPrepareService] AIR prepare artifact unresolvable after catalog refresh " \
          "type=#{unknown_artifact[1]} id=#{unknown_artifact[2]} attempts=#{attempt} error=#{error.message}"
        )
        raise ArtifactResolutionError.new(
          error.message,
          artifact_type: unknown_artifact[1],
          artifact_id: unknown_artifact[2]
        )
      end

      if transient && attempt < max_attempts
        delay = AIR_PREPARE_RETRY_DELAYS_SECONDS[attempt - 1]
        Rails.logger.info(
          "[AirPrepareService] AIR prepare failed transiently, retrying " \
          "attempt=#{attempt} sleep_seconds=#{delay} error=#{error.message}"
        )
        @sleeper.call(delay)
        next
      end

      if transient
        Rails.logger.error(
          "[AirPrepareService] AIR prepare failed after retries " \
          "attempts=#{attempt} error=#{error.message}"
        )
      end
      raise error
    end
  end

  # Bust this worker's AIR github catalog cache by running a bounded `air update`,
  # so a freshly-merged root that hasn't propagated here yet becomes resolvable on
  # the immediately-following `air prepare` retry. Best-effort: a refresh failure
  # is logged at WARN and swallowed (returns false) so it never masks the original
  # root-not-found error the caller is mid-handling.
  #
  # We run `air update` directly through BoundedSubprocess rather than calling
  # AirCatalogService.refresh! because that path uses an UNBOUNDED Open3.capture3 —
  # acceptable for the 15-min CatalogRefreshJob, but a hang risk on the synchronous
  # session-launch path this method runs on. Reuses the caller's env so the update
  # targets the same AIR_CONFIG catalog the prepare resolves against.
  def refresh_catalog_cache!(env)
    air_bin = File.join(AIR_INSTALL_DIR, "node_modules", ".bin", "air")
    _stdout, stderr, status = BoundedSubprocess.run(
      [ air_bin, "update", "--git-protocol", "https" ],
      env: env,
      timeout: AIR_PREPARE_TIMEOUT_SECONDS
    )
    return true if status.success?

    Rails.logger.warn(
      "[AirPrepareService] catalog cache refresh failed (exit #{status.exitstatus}): " \
      "#{stderr.to_s.truncate(500)}"
    )
    false
  rescue BoundedSubprocess::TimeoutError => e
    Rails.logger.warn("[AirPrepareService] catalog cache refresh timed out: #{e.message}")
    false
  end

  # Whether an `air prepare` failure message looks like a transient github.com
  # clone hiccup worth retrying (vs. a deterministic config/catalog error).
  def transient_air_failure?(message)
    TRANSIENT_AIR_PREPARE_PATTERNS.match?(message.to_s)
  end

  # Names of the ${VAR}s AIR reported as unresolvable, or [] if the message isn't
  # an unresolved-variable failure at all.
  def unresolved_variable_names(message)
    tokens = UNRESOLVED_VARIABLE_PATTERN.match(message.to_s)&.captures&.first
    return [] if tokens.blank?

    tokens.scan(VARIABLE_TOKEN_PATTERN).flatten
  end

  # Determine the agent root key for --root flag.
  # Prefers the explicit key stored in session metadata at creation time.
  # Falls back to reverse-lookup by URL + subdirectory.
  def find_root_name
    session.metadata&.dig("agent_root_key") ||
      AgentRootsConfig.find_for_session(session)&.name
  end
end

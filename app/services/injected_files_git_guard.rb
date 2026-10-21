# frozen_string_literal: true

# Keeps the files Zimmer injects into a session clone out of the clone's commits,
# whatever the cloned repository's own `.gitignore` says (tadasant/zimmer#1382).
#
# `air prepare` and the runtime post-processors write `.mcp.json`, `.env`,
# `.codex/config.toml` and friends into the working directory, and several of
# them carry live credentials in plain text: the strad gateway's bearer token,
# the session's own Zimmer API key, every secret the session's artifacts declare.
# The catalog repos list those paths in `.gitignore`; an arbitrary `git_root`
# does not. A session spawned against a third-party repo ran `git commit -a`,
# and the injected `.mcp.json` was pushed to a public fork.
#
# Two guards, both local to the clone and never committed:
#
# 1. Every injected path is listed in the repository's `info/exclude`, which git
#    honours exactly like `.gitignore`. That stops an *untracked* injected file
#    from reaching `git add -A`, `git add .` or `git commit -a`.
# 2. An injected secret-bearing file that the repository already TRACKS (a repo
#    that ships its own `.mcp.json`, say) is marked `--skip-worktree`, because an
#    exclude does nothing for a tracked file: Zimmer's rewrite of it would show up
#    as an ordinary modification and ride along with `git commit -a`.
#
# Neither stops an explicit `git add -f`. Both are idempotent: the exclude gains
# only the lines it lacks, and re-marking a skip-worktree entry is a no-op, so the
# guard runs on every prepare — fresh clone, warm-pool claim, follow-up, fork,
# unarchive — and a worktree shares its main repository's exclude through
# `git rev-parse --git-path`.
class InjectedFilesGitGuard
  class Error < StandardError; end

  # Paths relative to the working directory, written by Zimmer or by the AIR
  # adapters it drives. A trailing slash excludes a whole directory.
  STATIC_PATHS = [
    McpJsonConfigFormat::MCP_CONFIG_FILENAME, # .mcp.json — Claude and Pi MCP config
    EnvFile::FILENAME,                         # .env — SessionEnvFile's scoped secrets
    ".claude/",                                # AIR claude: skills, hooks, settings.json
    ".codex/",                                 # AIR codex: config.toml, hooks
    ".agents/skills/",                         # AIR codex: skills
    ".pi/",                                    # AIR pi skills, PiAirBridge, Pi transcripts
    "#{NpxCacheLayout::CACHE_DIRNAME}/",       # .npm-cache — npx installs for MCP servers
    ".bundle/",                                # BundleInstallJob's BUNDLE_APP_CONFIG
    "vendor/bundle/",                          # BundleInstallJob's slow-path install
    CodexRuntimeAdapter::LAST_MESSAGE_FILENAME, # codex_last_message.txt
    PiRuntimeAdapter::SYSTEM_PROMPT_FILENAME   # pi_system_prompt.md
  ].freeze

  # The injected files that carry credentials, so the ones worth hiding from
  # `git commit -a` even when the repository tracks them.
  SECRET_BEARING_PATHS = [
    McpJsonConfigFormat::MCP_CONFIG_FILENAME,
    EnvFile::FILENAME,
    CodexConfigTomlPostProcessor::CONFIG_RELATIVE_PATH,
    File.join(".claude", "settings.json")
  ].freeze

  # Opens Zimmer's block in `info/exclude`, so a human reading the file can tell
  # where the lines came from.
  HEADER = "# Injected by Zimmer at prepare time; never commit these (tadasant/zimmer#1382)."

  GIT_TIMEOUT_SECONDS = 15

  # What `git rev-parse` says when the directory is outside any repository —
  # the one failure that means "nothing to guard" rather than "guard broken".
  NOT_A_REPOSITORY = /not a git repository/i

  # The clone's `.git/config` is writable by the agent, so a configured
  # fsmonitor or hook must not run inside the worker on Zimmer's behalf.
  GIT_HARDENING = [ "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" ].freeze

  class << self
    # @param session [Session] whose runtime decides the runtime-specific paths
    # @param working_directory [String] the session's working directory
    # @return [Array<String>, nil] the exclude lines added on this call (empty
    #   when already present); nil when the directory is missing or not inside a
    #   git repository, so there is nothing to guard
    # @raise [Error] when the directory is a git repository and the guard could
    #   not be written — fail the prepare rather than run unguarded
    def apply!(session:, working_directory:)
      new(session: session, working_directory: working_directory).apply!
    end

    # Every path the guard excludes for a session on `runtime`.
    def injected_paths(runtime)
      paths = STATIC_PATHS + spawn_artifact_filenames
      contribution = RuntimePromptContribution.for(runtime)
      # Codex reads its system prompt from AGENTS.md, which Zimmer writes when the
      # repository has none. Excluded only for those runtimes: on any other, a
      # repo without an AGENTS.md must stay free to add one. A tracked AGENTS.md
      # is untouched by the exclude.
      paths += [ contribution.system_prompt_filename ] if contribution.delivered_via_file?
      paths.compact.uniq
    end

    private

    # What every runtime's spawned process writes into the working directory
    # (stderr logs, Codex's event log). All runtimes, not just this session's: a
    # clone outlives a runtime switch.
    def spawn_artifact_filenames
      RuntimeRegistry.registered_runtimes.flat_map do |runtime|
        RuntimeRegistry.for(runtime).cli_adapter_class.spawn_artifact_paths("/").map do |path|
          path.delete_prefix("/")
        end
      end
    end
  end

  def initialize(session:, working_directory:)
    @session = session
    @working_directory = working_directory
  end

  def apply!
    return nil unless File.directory?(@working_directory)

    location = git_location
    return nil if location.nil?

    prefix, exclude_path = location
    added = append_excludes!(exclude_path, prefix)
    skip_tracked_secret_files!
    added
  rescue SystemCallError, BoundedSubprocess::TimeoutError => e
    raise Error, "could not guard injected files in #{@working_directory}: #{e.class}: #{e.message}"
  end

  private

  # The working directory's path inside its repository ("" at the top level,
  # "agents/foo/" in a subdirectory) and the absolute path of the exclude file
  # git reads for it. nil when the directory is not inside a git repository:
  # there is nothing to commit to, so nothing to guard. Any other failure —
  # a corrupt `.git`, a refused `safe.directory` — raises: a guard that cannot
  # tell whether it applies must not quietly stand down.
  def git_location
    stdout, stderr, status = git("rev-parse", "--show-prefix", "--git-path", "info/exclude")
    unless SubprocessStatus.success?(status)
      return nil if stderr.match?(NOT_A_REPOSITORY)

      raise Error, "git rev-parse failed in #{@working_directory}: #{stderr.strip}"
    end

    prefix, exclude = stdout.split("\n", -1).first(2)
    return nil if exclude.blank?

    [ prefix.to_s, File.expand_path(exclude, @working_directory) ]
  end

  # Append the anchored lines the exclude does not already hold, under a lock so
  # two concurrent prepares of one clone cannot interleave their writes.
  def append_excludes!(exclude_path, prefix)
    wanted = self.class.injected_paths(@session.agent_runtime).map { |path| "/#{escape(prefix)}#{path}".b }

    FileUtils.mkdir_p(File.dirname(exclude_path))
    # Binary: the file is the user's too, and a line in another encoding must
    # not make the comparison raise.
    File.open(exclude_path, File::RDWR | File::CREAT, 0o644) do |file|
      file.flock(File::LOCK_EX)
      existing = file.read.b
      present = existing.lines.map(&:strip)
      missing = wanted.reject { |line| present.include?(line) }
      next [] if missing.empty?

      block = "".b
      block << "\n" unless existing.empty? || existing.end_with?("\n")
      block << "#{HEADER}\n" unless present.include?(HEADER.b)
      block << missing.map { |line| "#{line}\n" }.join
      file.write(block)
      missing.map { |line| line.dup.force_encoding(Encoding::UTF_8) }
    end
  end

  def skip_tracked_secret_files!
    candidates = SECRET_BEARING_PATHS.select { |path| File.exist?(File.join(@working_directory, path)) }
    return if candidates.empty?

    stdout, stderr, status = git("ls-files", "-z", "--", *candidates)
    raise Error, "git ls-files failed in #{@working_directory}: #{stderr.strip}" unless SubprocessStatus.success?(status)

    tracked = stdout.split("\0").reject(&:empty?)
    return if tracked.empty?

    _stdout, stderr, status = git("update-index", "--skip-worktree", "--", *tracked)
    return if SubprocessStatus.success?(status)

    raise Error, "git update-index --skip-worktree failed in #{@working_directory}: #{stderr.strip}"
  end

  # gitignore glob metacharacters in a subdirectory name would otherwise widen
  # or break the anchored pattern.
  def escape(prefix)
    prefix.gsub(/[\\*?\[]/) { |char| "\\#{char}" }
  end

  def git(*args)
    BoundedSubprocess.run([ "git", *GIT_HARDENING, "-C", @working_directory, *args ], timeout: GIT_TIMEOUT_SECONDS)
  end
end

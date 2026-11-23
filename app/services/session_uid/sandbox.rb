# frozen_string_literal: true

require "open3"

module SessionUid
  # Hands one session's directories to its uid, just before a spawn.
  #
  # Runs on every spawn, not once: the app keeps writing into these directories as
  # uid 1000 between turns (AIR prepare, `.mcp.json`, `.env`, credential writes, a
  # web upload, a fork), and under the flag the app's umask is 077, so each of those
  # files is unreadable to the session until it is handed over here.
  #
  # The handover is `chown -R -P --from=1000`, deliberately not a Ruby walk:
  #
  #   * `-P` never follows a symlink, and GNU chown's traversal opens each directory
  #     with O_NOFOLLOW and checks it against the lstat it made, so a session that
  #     swaps a directory for a symlink mid-walk cannot steer it into the app's files.
  #   * `--from=1000` changes only what the app created. A file owned by root, or by
  #     another session's uid, is left alone.
  #
  # A hard link to an app file inside a clone would still be followed; the kernel's
  # `fs.protected_hardlinks` (on by default) is what stops a session creating one to a
  # file it cannot already read and write. docs/src/content/docs/limitations.md
  # records that dependency.
  class Sandbox
    # Mode of every per-session root once handed over: the session alone.
    ROOT_MODE = 0o700

    # The handover, as an argv. Public so the boundary test runs exactly this.
    def self.chown_command(uid, root)
      [ "chown", "-R", "-P", "--from=#{APP_UID}", "#{uid}:#{uid}", root.to_s ]
    end

    def initialize(session:, uid:, working_dir:, logger: Rails.logger)
      @session = session
      @uid = uid
      @working_dir = working_dir.to_s
      @logger = logger
    end

    # @return [String] the session's HOME
    # @raise [SessionUid::Unavailable] when a directory could not be handed over
    def prepare!
      home = ensure_home!
      relocate_claude_transcripts!
      link_mcp_logs!(home)
      Lockdown.expose_tools!

      roots.each { |root| hand_over!(root) }
      home
    end

    # Every per-session directory the session should own. The clone first: it is the
    # largest, and the one whose failure matters most.
    def roots
      [
        clone_root,
        ClaudeSessionConfigDirectory.ensure_for(@session.id),
        SessionScratchDirectory.ensure_for(@session.id),
        SessionHomeDirectory.path_for(@session.id),
        FileStorageService.new(session_id: @session.id).session_dir,
        ImageStorageService.new(session_id: @session.id).session_dir
      ].compact.uniq.select { |path| File.directory?(path) }
    end

    private

    def clone_root
      @session.clone_root.presence || @working_dir.presence
    end

    def hand_over!(root)
      stat = File.lstat(root)
      raise Unavailable, "#{root} is not a directory" unless stat.directory?

      _out, err, status = Open3.capture3(*self.class.chown_command(@uid, root))
      raise Unavailable, "could not hand #{root} to uid #{@uid}: #{err.strip}" unless status.success?

      File.chmod(ROOT_MODE, root)
    end

    # A HOME holding only what the session needs: git's identity and credential helper,
    # and an empty gh config directory (gh authenticates from GH_TOKEN).
    #
    # After the first handover the HOME is the session's, and anything in it may be a
    # symlink the session planted. So the directory is made as the session's uid and the
    # gitconfig is written without following a link (PathGuard.open_for_write).
    def ensure_home!
      home = SessionHomeDirectory.path_for(@session.id)
      FileUtils.mkdir_p(home)
      mkdir_in_session(home, File.join(home, ".config/gh"))

      global = File.join(Dir.home, ".gitconfig")
      # The app's global git config holds the commit identity and the credential helper
      # path (bin/zimmer-git-credential); GitIdentityProvisioner writes it. No secret.
      if File.file?(global)
        PathGuard.open_for_write(File.join(home, ".gitconfig"), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(File.read(global))
        end
      end
      home
    end

    # Under the flag a session keeps its transcripts in its own CLAUDE_CONFIG_DIR.
    #
    # Normally `<config dir>/projects` is a symlink to the shared ~/.claude/projects,
    # which every reader in the app looks in (ClaudeSessionConfigDirectory explains
    # why). A shared directory every session writes into is exactly what the uid
    # boundary forbids, so here the arrangement is turned inside out: `projects` is a
    # real directory the session owns, and the shared tree gets a symlink to this
    # session's transcript directory under the same name. Every reader still opens
    # ~/.claude/projects/<sanitized working dir>/, and gets there through the link.
    #
    # A session that ran before the flag has its transcripts in the shared tree; they are
    # moved over once. That copy is done by the app, so it only happens while the config
    # directory is still the app's (the session has never run isolated, or a rollback
    # handed it back) — never into a tree the session could have laid symlinks in.
    def relocate_claude_transcripts!
      config_dir = ClaudeSessionConfigDirectory.ensure_for(@session.id)
      projects = File.join(config_dir, ClaudeSessionConfigDirectory::PROJECTS_DIRNAME)
      File.delete(projects) if File.symlink?(projects)

      key = PathSanitizer.sanitize(@working_dir)
      private_dir = File.join(projects, key)
      shared_dir = File.join(ClaudeTranscriptSource.projects_root, key)
      FileUtils.mkdir_p(File.dirname(shared_dir))
      refuse_shared_link!(shared_dir, private_dir)

      if File.directory?(shared_dir) && !File.symlink?(shared_dir)
        owner = File.lstat(config_dir).uid
        if SessionUid.agent_uid?(owner)
          raise Unavailable, "session #{@session.id}'s transcripts are still in the shared tree, but its " \
            "config directory already belongs to session uid #{owner}; refusing to copy into it"
        end

        FileUtils.mkdir_p(private_dir)
        FileUtils.cp_r(File.join(shared_dir, "."), private_dir, preserve: true)
        FileUtils.rm_rf(shared_dir)
        @logger.info("[SessionUid] moved session #{@session.id}'s transcripts into its own config dir")
      end
      mkdir_in_session(config_dir, private_dir)
      replace_with_symlink(shared_dir, private_dir)
    end

    # The shared transcript link names a working directory, so it can serve one session.
    # A second isolated session on the same working directory would re-point it and leave
    # the first one's poller reading a directory it may not.
    def refuse_shared_link!(shared_dir, private_dir)
      return unless File.symlink?(shared_dir)

      current = File.readlink(shared_dir)
      return if current == private_dir || !File.exist?(current)

      raise Unavailable, "#{shared_dir} already serves another session (#{current}); two isolated " \
        "sessions cannot share a working directory"
    end

    # Claude Code writes its MCP server logs under $HOME/.cache/claude-cli-nodejs. The
    # session's HOME is its own now, so McpLogPollerService — which reads the app's
    # cache directory — is given a symlink to where they land. Logs from before the flag
    # are dropped rather than copied into a HOME the session controls.
    def link_mcp_logs!(home)
      key = PathSanitizer.sanitize(@working_dir)
      target = File.join(home, ".cache", "claude-cli-nodejs", key)
      mkdir_in_session(home, target)

      link = File.join(PathSanitizer.cache_base, key)
      FileUtils.mkdir_p(File.dirname(link))
      FileUtils.rm_rf(link) if File.directory?(link) && !File.symlink?(link)
      replace_with_symlink(link, target)
    end

    # `mkdir -p path`, below `root`. While the session has never owned `root` the app makes
    # it; once it has, the session's own uid does, so a symlink it planted on the way can
    # only lead somewhere it could already write.
    def mkdir_in_session(root, path)
      return FileUtils.mkdir_p(path) unless File.lstat(root).uid == @uid

      argv, env, extra = [ SessionUid.wrap([ "mkdir", "-p", path ], uid: @uid, env: {}),
                           ENV.to_h.slice("PATH").merge("HOME" => root), { unsetenv_others: true } ]
      _out, err, status = Open3.capture3(env, *argv, **extra)
      raise Unavailable, "could not create #{path} as uid #{@uid}: #{err.strip}" unless status.success?
    end

    def replace_with_symlink(link, target)
      return if File.symlink?(link) && File.readlink(link) == target

      File.delete(link) if File.symlink?(link) || File.file?(link)
      File.symlink(target, link)
    end
  end
end

# frozen_string_literal: true

module SessionUid
  # Takes "group" and "other" access off everything of the app's that an isolated
  # session has no business reading, and leaves exactly the paths it needs traversable.
  #
  # Runs once per worker process, before its first isolated spawn (#ensure_applied!),
  # which only happens with the flag on and the capabilities it grants. It never runs, and
  # nothing it does happens, on a deployment that does not set ZIMMER_SESSION_UID=1.
  #
  # The shape it leaves behind:
  #
  #   /home/rails                    0711  traverse only: nothing can be listed
  #   ├── .zimmer                    0711
  #   │   ├── clones                 0711  each clone 0700, its session's uid
  #   │   ├── claude-config          0711  each dir 0700, its session's uid
  #   │   ├── session-scratch        0711  "
  #   │   ├── session-homes          0711  "
  #   │   ├── agent-orchestrator-*   0711  "
  #   │   └── everything else        go-rwx
  #   ├── .local/bin, .local/share/claude/versions/<v>   traversable, to run `claude`
  #   └── everything else            go-rwx  (.ssh .claude .codex .config .cache .npm ...)
  #   /rails/log /rails/tmp /rails/storage   go-rwx
  #
  # A per-session directory still owned by uid 1000 is one that predates the flag (or
  # belongs to a session out of its scope); it loses group/other access here and is
  # handed to its session's uid the next time that session spawns (Sandbox).
  #
  # Rolling back needs none of this undone: uid 1000 owns everything listed above, and
  # every mode set here still lets the owner in.
  module Lockdown
    TRAVERSE_ONLY = 0o711
    APP_PRIVATE_DIRS = %w[log tmp storage].freeze

    module_function

    MUTEX = Mutex.new

    # Apply once per process, before the first isolated spawn. SessionUid.context_for
    # calls this, so a worker never starts an isolated session with the app's files
    # still open to it; a lockdown that raises fails that spawn rather than being skipped.
    #
    # Only the worker needs it. Agents run in the worker's container: they share the
    # durable volumes with web, but never see web's own HOME.
    def ensure_applied!
      MUTEX.synchronize do
        return if @applied

        counts = apply!
        Rails.logger.info "[SessionUid] lockdown applied: #{counts[:traversable]} directories left " \
          "traversable, #{counts[:locked]} paths closed to other users"
        @applied = true
      end
    end

    def reset!
      MUTEX.synchronize { @applied = false }
    end

    # @return [Hash] counts, for the log line
    def apply!(home: Dir.home, rails_root: Rails.root.to_s)
      counts = { traversable: 0, locked: 0 }
      session_bases = per_session_bases.map { |path| File.expand_path(path) }
      exposed = exposed_paths(home, session_bases + tool_paths)

      exposed.sort.each do |dir|
        next unless File.directory?(dir) && !File.symlink?(dir)

        if dir == home || under?(dir, home)
          set_mode(dir, (File.stat(dir).mode & 0o700) | 0o011) && counts[:traversable] += 1
          # A base's children are sessions' directories: the loop below decides those.
          next if session_bases.include?(dir)

          each_child(dir) do |child|
            next if exposed.include?(child) || tool_paths.include?(child)

            counts[:locked] += 1 if lock(child)
          end
        end
      end

      session_bases.each do |base|
        FileUtils.mkdir_p(base)
        set_mode(base, TRAVERSE_ONLY)
        each_child(base) do |child|
          next if SessionUid.agent_uid?(File.lstat(child).uid)

          counts[:locked] += 1 if lock(child)
        end
      end

      APP_PRIVATE_DIRS.each do |name|
        path = File.join(rails_root, name)
        counts[:locked] += 1 if File.directory?(path) && lock(path)
      end

      expose_tools!
      counts
    end

    # Keep the runtime binaries an isolated session executes reachable: every directory
    # from HOME down to each one traversable, and the file itself readable and
    # executable. Called at boot and before every isolated spawn, because
    # ClaudeCodeUpdateJob installs new versions under the app's umask of 077.
    def expose_tools!(home: Dir.home)
      tool_paths.each do |path|
        next unless under?(path, home)

        ancestors_within(File.dirname(path), home).each do |dir|
          set_mode(dir, File.stat(dir).mode | 0o011) unless File.symlink?(dir)
        end
        set_mode(path, File.stat(path).mode | 0o055) if File.file?(path) && !File.symlink?(path)
      end
    rescue SystemCallError => e
      Rails.logger.warn("[SessionUid::Lockdown] could not expose runtime binaries: #{e.message}")
    end

    # The bases under which each session has a directory of its own.
    def per_session_bases
      [
        ClonesDirectory.base,
        ClaudeSessionConfigDirectory.base,
        SessionScratchDirectory.base,
        SessionHomeDirectory.base,
        FileStorageService.base_dir,
        ImageStorageService.base_dir
      ]
    end

    # The runtime binaries an isolated session runs, as the path on PATH and the file
    # it resolves to. Only `claude` lives under the app's HOME; codex, pi and node are
    # in the image under /usr.
    def tool_paths
      found = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "claude") }
                         .find { |path| File.exist?(path) }
      return [] if found.nil?

      [ File.expand_path(found), File.realpath(found) ].uniq
    rescue SystemCallError
      []
    end

    # Every path that has to stay traversable: each target plus its ancestors up to
    # and including HOME.
    def exposed_paths(home, targets)
      targets.each_with_object(Set.new) do |target, set|
        next unless target == home || under?(target, home)

        ancestors_within(target, home).each { |dir| set << dir }
      end
    end

    def ancestors_within(path, home)
      dirs = []
      current = File.expand_path(path)
      while current == home || under?(current, home)
        dirs << current
        break if current == home

        current = File.dirname(current)
      end
      dirs
    end

    def under?(path, dir)
      File.expand_path(path).start_with?("#{File.expand_path(dir)}/")
    end

    def each_child(dir, &block)
      Dir.children(dir).each { |name| block.call(File.join(dir, name)) }
    rescue SystemCallError
      nil
    end

    # Group and other lose everything; setuid/setgid/sticky bits go too.
    def lock(path)
      stat = File.lstat(path)
      return false if stat.symlink?
      return false if (stat.mode & 0o7077).zero?

      set_mode(path, stat.mode & 0o700)
    rescue SystemCallError
      false
    end

    def set_mode(path, mode)
      File.chmod(mode, path)
      true
    rescue SystemCallError => e
      Rails.logger.warn("[SessionUid::Lockdown] could not chmod #{path}: #{e.message}")
      false
    end
  end
end

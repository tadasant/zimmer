# frozen_string_literal: true

module SessionUid
  # Stops an isolated session using the app's privileges to read a file it could not.
  #
  # Under ZIMMER_SESSION_UID=1 the app reads what sessions write — transcripts, MCP
  # logs, stderr, credential stores — and it can read anything, because it holds
  # CAP_DAC_OVERRIDE. A session controls the paths it writes, so it can replace its
  # transcript with a symlink to `~/.claude/.credentials.json`, or to another session's
  # transcript, and the poller would read that and store it as the session's own
  # transcript, where the session can read it back. The uid boundary would be intact and
  # beside the point.
  #
  # The rule, checked against the file actually opened (its fstat, and the path the
  # kernel reports for the open descriptor), so a swap between check and read changes
  # nothing:
  #
  #   1. Find the per-session root the requested path lies in: a direct child of one of
  #      the per-session bases (Lockdown.per_session_bases), reached lexically. The
  #      app's own transcript and MCP-log trees hold symlinks the app made into those
  #      roots (Sandbox), and are followed one level to the root they point into. Those
  #      links live in directories no session can write, so they can be trusted.
  #   2. A root a session's uid does not own is not isolated: nothing to check, and the
  #      read is exactly what it always was.
  #   3. Otherwise the file must be owned by that same uid, or be one of the app's files
  #      (uid 1000) that sits physically inside that same root — something the app wrote
  #      there since the last handover.
  #
  # Anything else raises Errno::EACCES, which every caller already treats as "could not
  # read this file".
  module PathGuard
    module_function

    # Open `path` for reading, checked. With the flag unset this is File.open.
    def open(path, mode = "r", &block)
      return File.open(path, mode, &block) unless SessionUid.enabled?

      # O_NONBLOCK so a FIFO the session swapped in cannot hang the reader on open; it is
      # then refused for not being a regular file. Reads of a regular file ignore the flag.
      File.open(path, File::RDONLY | File::NONBLOCK, binmode: mode.include?("b")) do |io|
        raise Errno::EACCES, "#{path} is not a regular file" unless io.stat.file?

        verify!(path, io)
        block.call(io)
      end
    end

    # With the flag unset these are the very File methods they replace, not equivalents
    # built on File.open: same calls, same exceptions, same behaviour under a stub.
    def read(path)
      return File.read(path) unless SessionUid.enabled?

      open(path, "r", &:read)
    end

    def binread(path)
      return File.binread(path) unless SessionUid.enabled?

      open(path, "rb", &:read)
    end

    # Like File.foreach: without a block, an Enumerator — which opens (and checks) the
    # file only when it is iterated, so the descriptor is never closed under it.
    def foreach(path, mode: "r", &block)
      return File.foreach(path, mode: mode, &block) unless SessionUid.enabled?
      return enum_for(:foreach, path, mode: mode) unless block

      open(path, mode) { |io| io.each_line(&block) }
      nil
    end

    # @raise [Errno::EACCES]
    def verify!(path, io)
      root = session_root_for(path)
      return if root.nil?

      root_uid = owner(root)
      return unless SessionUid.agent_uid?(root_uid)

      file_uid = opened_owner(io)
      return if file_uid == root_uid

      opened = File.readlink("/proc/self/fd/#{io.fileno}")
      real_root = File.realpath(root)
      return if file_uid == APP_UID && opened.start_with?("#{real_root}/")

      raise Errno::EACCES, "#{path} resolves outside its session's own files (owner #{file_uid}); refusing to read it"
    end

    def owner(path)
      File.lstat(path).uid
    end

    def opened_owner(io)
      io.stat.uid
    end

    # Open `path` for writing without following any symlink below the session root.
    #
    # The app writes into directories a session owns (its stderr log, its credential store,
    # `.bundle/config`, its HOME). With CAP_DAC_OVERRIDE, a session that replaced a
    # directory or the file itself with a symlink would otherwise have the app write — or
    # truncate — wherever it pointed. So below an isolated session's root every component
    # is opened with O_NOFOLLOW, each relative to the descriptor of the one before it
    # (through /proc/self/fd, Ruby having no openat), which leaves nothing to swap. The
    # root itself sits in a base directory only the app can write.
    #
    # Anywhere else, and always with the flag unset, this is File.open(path, flags, perm).
    #
    # @raise [Errno::ELOOP] when a component is a symlink
    def open_for_write(path, flags, perm = 0o600, &block)
      root = SessionUid.enabled? ? session_root_for(path) : nil
      return File.open(path, flags, perm, &block) if root.nil? || !SessionUid.agent_uid?(owner(root))

      relative = File.expand_path(path).delete_prefix("#{File.expand_path(root)}/").split("/")
      name = relative.pop
      # Ruby has no O_DIRECTORY (its value differs by architecture), so each step is
      # opened O_NOFOLLOW and then required to be a directory.
      # O_NONBLOCK throughout so a FIFO swapped in cannot hang the open.
      dirs = [ File.open(root, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) ]
      raise Errno::ENOTDIR, root unless dirs.last.stat.directory?

      relative.each do |component|
        dirs << File.open("/proc/self/fd/#{dirs.last.fileno}/#{component}", File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
        raise Errno::ENOTDIR, component unless dirs.last.stat.directory?
      end
      file = File.open("/proc/self/fd/#{dirs.last.fileno}/#{name}", flags | File::NOFOLLOW | File::NONBLOCK, perm)
      unless file.stat.file?
        file.close
        raise Errno::EACCES, "#{path} is not a regular file"
      end
      return file unless block

      begin
        block.call(file)
      ensure
        file.close
      end
    ensure
      dirs&.each(&:close)
    end

    # The per-session root directory `path` lies in, or nil.
    def session_root_for(path)
      expanded = File.expand_path(path.to_s)

      Lockdown.per_session_bases.each do |base|
        root = direct_child(File.expand_path(base), expanded)
        return root if root
      end

      link_bases.each do |base|
        link = direct_child(File.expand_path(base), expanded)
        next if link.nil? || !File.symlink?(link)

        target = File.expand_path(File.readlink(link), File.dirname(link))
        Lockdown.per_session_bases.each do |session_base|
          root = direct_child(File.expand_path(session_base), target)
          return root if root
        end
      end

      nil
    rescue SystemCallError
      nil
    end

    # The app-owned trees Sandbox links into session roots.
    def link_bases
      [ ClaudeTranscriptSource.projects_root, PathSanitizer.cache_base ]
    end

    # `base/<first component of path below base>`, when path is below base.
    def direct_child(base, path)
      return nil unless path.start_with?("#{base}/")

      first = path.delete_prefix("#{base}/").split("/").first
      first.present? ? File.join(base, first) : nil
    end
  end
end

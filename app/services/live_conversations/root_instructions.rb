# frozen_string_literal: true

require "tmpdir"

module LiveConversations
  # Reads an agent root's AGENTS.md — the system prompt of a live conversation.
  #
  # An agent root is a git repository (`url`, `default_branch`) plus an optional
  # `subdirectory`, and nothing on the web or worker host keeps a trustworthy
  # checkout of it. So this fetches the one file it needs: a shallow, blobless
  # clone with no checkout (commits and trees only), then `git show` of the file,
  # which pulls exactly that blob. Bounded like every session clone: the same
  # stall-detection env as GitCloneService and a wall-clock cap, with whatever
  # git credentials the host already has.
  #
  # AGENTS.md is preferred; CLAUDE.md is accepted for a root that only ships that.
  #
  # Beside it the root may ship one style file per mode (`modes/text.md`,
  # `modes/voice.md`; Mode#style_path): how to answer when typed, how when
  # spoken. Each is optional. They come back in `modes`, keyed by mode, and
  # SystemPrompt puts the current mode's after AGENTS.md — Zimmer's own short
  # default when the root ships none.
  class RootInstructions
    FILENAMES = %w[AGENTS.md CLAUDE.md].freeze
    TIMEOUT_SECONDS = 90

    # Big enough for any sensible prompt, small enough that a mistake (a root
    # pointing at a repo whose AGENTS.md is a manual) cannot blow the model's
    # context.
    MAX_BYTES = 60_000

    class Error < StandardError; end

    # Per mode-style file, smaller still: it is a paragraph or two of style.
    MAX_MODE_BYTES = 12_000

    Result = Data.define(:text, :source, :modes)

    def self.fetch(root, runner: BoundedSubprocess)
      new(root, runner: runner).fetch
    end

    def initialize(root, runner:)
      @root = root
      @runner = runner
    end

    def fetch
      raise Error, "Agent root #{@root.name} names no repository" if @root.url.blank?

      Dir.mktmpdir("live-root-") do |dir|
        clone_into(dir)
        sha = git!(%w[rev-parse HEAD], cwd: dir).strip

        FILENAMES.each do |filename|
          path = root_path(filename)
          text = show(dir, path)
          next if text.nil?

          return Result.new(text: clean(text, MAX_BYTES), source: "#{repo_label}@#{sha[0, 12]}:#{path}", modes: mode_styles(dir))
        end
      end

      raise Error, "Agent root #{@root.name} has no #{FILENAMES.join(' or ')} at " \
                   "#{[ repo_label, @root.subdirectory.presence ].compact.join(':')}"
    rescue BoundedSubprocess::TimeoutError
      raise Error, "Timed out reading agent root #{@root.name}'s instructions from #{repo_label}"
    end

    private

    def root_path(relative) = [ @root.subdirectory.presence, relative ].compact.join("/")

    # NUL is the one byte Postgres text will not store.
    def clean(text, limit) = text.byteslice(0, limit).scrub.delete("\u0000")

    def mode_styles(dir)
      LiveConversations::MODES.values.each_with_object({}) do |mode, styles|
        text = show(dir, root_path(mode.style_path))
        styles[mode.key] = clean(text, MAX_MODE_BYTES).strip if text.present? && text.strip.present?
      end
    end

    def clone_into(dir)
      git!([ "clone", "--quiet", "--depth", "1", "--filter=blob:none", "--no-checkout", "--single-branch",
             "--branch", branch, "--", @root.url, dir ])
    end

    # The file's contents, or nil when the path is not in the tree. Any other
    # failure is a real one.
    def show(dir, path)
      stdout, stderr, status = git([ "show", "HEAD:#{path}" ], cwd: dir)
      return stdout if SubprocessStatus.success?(status)
      return nil if stderr.match?(/does not exist|exists on disk, but not in|invalid object name/i)

      raise Error, "git show #{path} failed: #{stderr.lines.first.to_s.strip}"
    end

    def git(args, cwd: nil)
      @runner.run([ "git", *args ], env: GitCloneService::GIT_STALL_ENV, cwd: cwd, timeout: TIMEOUT_SECONDS)
    end

    def git!(args, cwd: nil)
      stdout, stderr, status = git(args, cwd: cwd)
      return stdout if SubprocessStatus.success?(status)

      raise Error, "Could not read agent root #{@root.name}'s instructions: git #{args.first} failed " \
                   "(#{SubprocessStatus.describe_failure(status)}): #{stderr.lines.first.to_s.strip}"
    end

    def branch = @root.default_branch.presence || "main"

    def repo_label
      @root.url.to_s.sub(%r{\Ahttps?://(www\.)?github\.com/}, "").delete_suffix(".git")
    end
  end
end

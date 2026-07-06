# frozen_string_literal: true

require "shellwords"

# Service for managing git clones
# Used to create isolated working directories for agents
class GitCloneService
  class GitError < StandardError; end

  # Raised when a git subprocess exceeds GIT_CLONE_TIMEOUT_SECONDS and is
  # killed by the watchdog. Subclasses GitError so it flows through the same
  # rescue paths, and is classified as transient so the clone is retried.
  class GitTimeoutError < GitError; end

  # Raised when a clone fails on a transient error (network/server hiccup) AND
  # the in-process retries in run_git_clone_with_retry have been exhausted.
  # Subclasses GitError so existing `rescue GitCloneService::GitError` paths keep
  # working, but lets callers distinguish "transient, worth retrying on a longer
  # horizon" from a permanent failure (bad auth, missing repo/branch). The
  # in-process retry window is only ~4–5 minutes; a slow-transfer window (curl 28
  # low-speed aborts) can outlast it, in which case the right move is to retry the
  # whole clone minutes later rather than hard-fail the session — see
  # AgentSessionJob's job-level clone retry.
  class TransientGitError < GitError; end

  # Hard wall-clock cap for a single git subprocess. A stalled clone — e.g. a
  # half-open HTTPS connection during fetch-pack that never sends a TCP reset —
  # would otherwise block the calling thread forever. Because GitCloneService
  # runs inside AgentSessionJob on the `waiting → running` launch path, that
  # blocked thread leaves the session wedged in `waiting` indefinitely with no
  # output and no recovery (the job keeps its GoodJob lock, so it still looks
  # "alive" to orphan detection). The watchdog kills the whole process group
  # when this is exceeded. Overridable via ENV for ops tuning.
  GIT_CLONE_TIMEOUT_SECONDS = Integer(ENV.fetch("GIT_CLONE_TIMEOUT_SECONDS", "300"))

  # Belt-and-suspenders before the hard watchdog: ask git itself to abort an
  # HTTP transfer that drops below ~1 KB/s for this many seconds, so a stalled
  # fetch fails fast with a transient error (which the retry logic recognizes)
  # rather than crawling up to the full timeout. GIT_TERMINAL_PROMPT=0 ensures a
  # missing-credential situation fails instead of blocking on an interactive
  # prompt. All overridable via ENV.
  GIT_STALL_ENV = {
    "GIT_HTTP_LOW_SPEED_LIMIT" => ENV.fetch("GIT_HTTP_LOW_SPEED_LIMIT", "1000"),
    "GIT_HTTP_LOW_SPEED_TIME" => ENV.fetch("GIT_HTTP_LOW_SPEED_TIME", "60"),
    "GIT_TERMINAL_PROMPT" => "0"
  }.freeze

  TRANSIENT_CLONE_ERROR_PATTERNS = Regexp.union(
    /remote: Internal Server Error/,
    /The requested URL returned error: 5\d\d/,
    /Could not resolve host/,
    /Connection timed out/,
    /Connection reset by peer/,
    /early EOF/,
    /RPC failed/,
    /Couldn't connect to server/,
    /fetch-pack: unexpected disconnect/,
    /unexpected EOF/,
    # Slow / interrupted transfer signatures. These co-occurred with the patterns
    # above in the sustained slow-clone that hard-failed session #9439 (curl 28
    # from GIT_HTTP_LOW_SPEED_TIME aborting a stalled fetch), but each can also
    # surface on its own. All three are unambiguous transfer failures — never
    # emitted for a permanent condition like bad auth or a missing repo/branch —
    # so classifying them transient only ever costs a bounded, backed-off retry.
    /Operation too slow/,
    /invalid index-pack output/,
    /bytes of body are still expected/
  )

  CLONE_RETRY_DELAYS_SECONDS = [ 5, 10, 20 ].freeze

  class << self
    # Allow injection of file system for testing
    attr_writer :file_system

    # Allow injection of sleeper for testing retry backoff without real sleeps
    attr_writer :sleeper

    def file_system
      @file_system ||= RealFileSystemAdapter.new
    end

    def sleeper
      @sleeper ||= ->(seconds) { Kernel.sleep(seconds) }
    end

    # Logger for git operations
    def logger
      @logger ||= StructuredLogger.new({ service: "GitCloneService" })
    end

    # Whether a clone failure should be treated as transient (worth retrying).
    # A GitTimeoutError (watchdog) is always transient; otherwise match the raw
    # message against the known transient signatures. Accepts either an exception
    # or a message string so callers that only have the wrapped message (e.g.
    # AgentSessionJob catching a GitError) can classify without the object.
    def transient_clone_error?(error_or_message)
      return true if error_or_message.is_a?(TransientGitError) || error_or_message.is_a?(GitTimeoutError)

      message = error_or_message.respond_to?(:message) ? error_or_message.message : error_or_message.to_s
      TRANSIENT_CLONE_ERROR_PATTERNS.match?(message)
    end

    # Create a git clone from a repository
    # @param repo_url [String] the git repository URL or local path
    # @param branch [String] the branch to checkout (default: 'main')
    # @param clone_path [String, nil] optional custom path for clone
    # @param subdirectory [String, nil] optional subdirectory within the repo to use as working directory
    # @return [Hash] hash with :clone_path and :working_directory keys
    def create_clone(repo_url, branch: "main", clone_path: nil, subdirectory: nil)
      # Generate a unique clone path if not provided
      clone_path ||= generate_clone_path(repo_url, branch)

      # Ensure parent directory exists
      file_system.mkdir_p(File.dirname(clone_path))

      # Clone the repository directly with the specified branch.
      # Retries on transient network/server errors (e.g., GitHub 5xx).
      run_git_clone_with_retry(repo_url, branch, clone_path)

      # Calculate working directory (clone path + subdirectory if specified)
      working_directory = if subdirectory.present?
        File.join(clone_path, subdirectory)
      else
        clone_path
      end

      # Verify subdirectory exists if specified
      if subdirectory.present? && !file_system.directory?(working_directory)
        cleanup_clone(clone_path)
        raise GitError, "Subdirectory '#{subdirectory}' not found in repository"
      end

      { clone_path: clone_path, working_directory: working_directory }
    rescue StandardError => e
      # Clean up on failure
      cleanup_clone(clone_path) if clone_path && file_system.directory?(clone_path)
      # Preserve the transient signal through the wrapper so callers can decide
      # whether a longer-horizon retry is warranted. run_git_clone_with_retry
      # raises TransientGitError once its own retries are exhausted; a bare
      # GitError (or any other error) means "don't retry — permanent".
      error_class = e.is_a?(TransientGitError) ? TransientGitError : GitError
      raise error_class, "Failed to create clone: #{e.message}"
    end

    # Clean up a git clone
    # @param path [String] the path to the clone
    # @return [void]
    def cleanup_clone(path)
      return unless path && file_system.directory?(path)

      file_system.rm_rf(path)
    rescue StandardError => e
      logger.error("Failed to cleanup clone", path: path, error: e.message)
      # Try forceful removal as last resort
      file_system.rm_rf(path) rescue nil
    end

    private

    # Run `git clone` with bounded retries for transient failures.
    # Non-transient failures (auth, missing branch, missing repo) raise immediately.
    def run_git_clone_with_retry(repo_url, branch, clone_path)
      attempt = 0
      max_attempts = CLONE_RETRY_DELAYS_SECONDS.length + 1

      loop do
        attempt += 1
        begin
          return run_git_command(
            [ "clone", "--branch", branch, "--single-branch", repo_url, clone_path ]
          )
        rescue GitError => e
          # A timed-out clone is always worth retrying — the stall may be a
          # transient network hiccup, and the previous attempt's process group
          # has already been killed by the watchdog.
          transient = transient_clone_error?(e)

          if transient && attempt < max_attempts
            delay = CLONE_RETRY_DELAYS_SECONDS[attempt - 1]
            logger.info(
              "git clone failed transiently, retrying",
              attempt: attempt,
              error: e.message,
              sleep_seconds: delay
            )
            cleanup_clone(clone_path) if file_system.directory?(clone_path)
            sleeper.call(delay)
            next
          end

          if transient
            # In-process retries exhausted, but the failure was transient. Re-raise
            # as TransientGitError so the caller (AgentSessionJob) can retry the
            # whole clone on a longer horizon instead of hard-failing the session —
            # a slow-transfer window can outlast our ~5-minute in-process budget.
            logger.error(
              "git clone failed after retries",
              attempts: attempt,
              error: e.message
            )
            raise TransientGitError, e.message
          end
          raise
        end
      end
    end

    # Generate a unique path for the clone
    def generate_clone_path(repo_url, branch)
      # Extract repo name from URL
      repo_name = File.basename(repo_url, ".git")
      timestamp = Time.now.to_i
      random = SecureRandom.hex(4)

      # Sanitize branch name: replace slashes with dashes to avoid creating nested directories
      # e.g., "claude/add-feature" becomes "claude-add-feature"
      safe_branch = branch.tr("/", "-")

      # Resolve the durable, configurable clones base via the single source of
      # truth (see ClonesDirectory) so writers and the GC always agree on it.
      base_path = Pathname.new(ClonesDirectory.base)
      file_system.mkdir_p(base_path)

      base_path.join("#{repo_name}-#{safe_branch}-#{timestamp}-#{random}").to_s
    end

    # Run a git command with a hard wall-clock timeout.
    #
    # Uses array syntax to prevent shell injection and a watchdog that kills the
    # subprocess's entire process group if it exceeds GIT_CLONE_TIMEOUT_SECONDS.
    # This is what prevents a stalled clone from hanging the calling thread (and
    # the AgentSessionJob it runs in) forever.
    def run_git_command(command, cwd: nil, timeout: GIT_CLONE_TIMEOUT_SECONDS)
      # Split command into array to prevent shell injection
      command_array = if command.is_a?(Array)
        [ "git" ] + command
      else
        # Parse command string into array (basic parsing)
        [ "git" ] + Shellwords.split(command)
      end

      logger.debug("Running git command", command: command_array.join(" "), cwd: cwd || "current", timeout: timeout)

      stdout, stderr, status = run_subprocess(command_array, cwd: cwd, timeout: timeout)

      unless status.success?
        raise GitError, "Git command failed: #{command_array.join(' ')}\nStdout: #{stdout}\nStderr: #{stderr}"
      end

      # Combine stdout and stderr for compatibility with existing code
      "#{stdout}#{stderr}"
    end

    # Spawn a git subprocess under a wall-clock watchdog (see BoundedSubprocess).
    # The child runs as its own process-group leader so that on timeout the whole
    # group is SIGKILLed — git spawns helper processes (git-remote-https,
    # index-pack) that must die too, not just the parent. This is what prevents a
    # stalled clone from hanging the calling thread (and the AgentSessionJob it
    # runs in) forever.
    #
    # Returns [stdout, stderr, Process::Status]. Raises GitTimeoutError (a
    # GitError subclass, classified transient) if the deadline is exceeded.
    def run_subprocess(command_array, cwd:, timeout:)
      BoundedSubprocess.run(command_array, env: GIT_STALL_ENV, cwd: cwd, timeout: timeout)
    rescue BoundedSubprocess::TimeoutError => e
      raise GitTimeoutError, e.message.sub(/\Acommand /, "git command ")
    end
  end
end

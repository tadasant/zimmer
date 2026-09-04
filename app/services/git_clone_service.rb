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

  # Raised when the clones volume cannot accommodate the clone (see
  # CloneDiskGuard). Subclasses GitError so existing `rescue
  # GitCloneService::GitError` paths keep working, but is deliberately NOT
  # transient: retrying a full disk on a 5-second backoff accomplishes nothing,
  # and the message is written to tell a human what to do instead.
  class InsufficientDiskSpaceError < GitError; end

  # Raised when the requested subdirectory (and the fallback, when one was
  # supplied) is absent from the freshly cloned tree. Subclasses GitError so
  # existing rescue paths keep working, and is deliberately NOT transient:
  # cloning the same commit again finds the same missing directory. It is a
  # statement about configuration — the agent root names a path this repo does
  # not have — rather than about git or the network, which is why callers on a
  # synchronous, user-initiated path log it as a refusal rather than a fault.
  class SubdirectoryNotFoundError < GitError; end

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
    # above in the sustained slow-clone that hard-failed session 9439 (curl 28
    # from GIT_HTTP_LOW_SPEED_TIME aborting a stalled fetch), but each can also
    # surface on its own. All three are unambiguous transfer failures — never
    # emitted for a permanent condition like bad auth or a missing repo/branch —
    # so classifying them transient only ever costs a bounded, backed-off retry.
    /Operation too slow/,
    /invalid index-pack output/,
    /bytes of body are still expected/,
    # A clone whose exit code was never read, because ZombieReaperJob reaped the
    # child before Open3's waiter did (see SubprocessStatus). "We never learned how
    # it ended" is the most retryable failure there is: nothing suggests the repo,
    # branch, or credential is wrong, and on this path there is no next tick — a
    # permanent classification fails the session over a result we merely missed.
    Regexp.new(Regexp.escape(SubprocessStatus::REAPED_DESCRIPTION))
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
    # @param fallback_subdirectory [String, nil] subdirectory to use when `subdirectory`
    #   is absent from the cloned tree but this one is present. Callers pass the path the
    #   agent root declares in the *current* catalog, so a root whose directory was renamed
    #   after the session was created still resolves (#921).
    # @return [Hash] hash with :clone_path, :working_directory and :subdirectory keys
    #   (:subdirectory is the path the clone actually landed on — the fallback, when one was taken)
    def create_clone(repo_url, branch: "main", clone_path: nil, subdirectory: nil, fallback_subdirectory: nil)
      # Generate a unique clone path if not provided
      clone_path ||= generate_clone_path(repo_url, branch)

      # Ensure parent directory exists
      file_system.mkdir_p(File.dirname(clone_path))

      # Refuse to start a clone the volume cannot hold. Prunes orphaned clones
      # first, so the common "disk filled with abandoned clones" case self-heals;
      # raises with an actionable message when it cannot.
      ensure_disk_space!(repo_url, File.dirname(clone_path))

      # Clone the repository directly with the specified branch.
      # Retries on transient network/server errors (e.g., GitHub 5xx).
      run_git_clone_with_retry(repo_url, branch, clone_path)

      # Which subdirectory this clone actually lands on: the requested one, the
      # fallback when the requested one is gone from the tree and the fallback is
      # there, or a raise when neither exists. Owns the existence check, so a
      # subdirectory that comes back from here is one that was seen on disk.
      effective_subdirectory = resolve_subdirectory!(clone_path, subdirectory, fallback_subdirectory)

      # Calculate working directory (clone path + subdirectory if specified)
      working_directory = if effective_subdirectory.present?
        File.join(clone_path, effective_subdirectory)
      else
        clone_path
      end

      { clone_path: clone_path, working_directory: working_directory, subdirectory: effective_subdirectory }
    rescue StandardError => e
      # Clean up on failure
      discard_failed_clone(clone_path)
      # Preserve the transient signal through the wrapper so callers can decide
      # whether a longer-horizon retry is warranted. run_git_clone_with_retry
      # raises TransientGitError once its own retries are exhausted; a bare
      # GitError (or any other error) means "don't retry — permanent".
      # InsufficientDiskSpaceError is preserved for the same reason in reverse:
      # it is permanent by construction and carries an actionable message.
      error_class = case e
      when TransientGitError then TransientGitError
      when InsufficientDiskSpaceError then InsufficientDiskSpaceError
      when SubdirectoryNotFoundError then SubdirectoryNotFoundError
      else GitError
      end
      raise error_class, "Failed to create clone: #{e.message}"
    end

    # Clean up a git clone.
    #
    # Atomic from every consumer's point of view: AtomicCloneRemoval renames the
    # clone aside before deleting it, so an interrupted delete can never leave a
    # half-tree wearing the clone's name (#412).
    #
    # Guarded, too: CloneReaper re-asks the database who owns this directory at
    # the instant of deletion and refuses if a session that is live — or being
    # unarchived — still does. Every scheduled reaper reaches the filesystem
    # through here, so that check covers all of them at once (#808).
    #
    # This is the *reaper's* door. The rollback paths in this class use
    # #discard_failed_clone instead: they are disposing of a directory they just
    # created and no session references, so there is nothing for the guard to
    # protect, and failing closed there would strand a partial tree that makes
    # the next `git clone` fail permanently.
    #
    # @param path [String] the path to the clone
    # @param reason [String] what asked for the deletion, for the refusal log
    # @return [Symbol, nil] CloneReaper's outcome, or nil when there was no path
    def cleanup_clone(path, reason: "GitCloneService")
      return unless path && file_system.directory?(path)

      CloneReaper.reap(path, reason: reason, file_system: file_system)
    rescue StandardError => e
      # Logged, not retried: a failure can only be raised once the clone has been
      # renamed out of the way, so the path the caller cares about is already gone
      # and a second attempt at it would be a no-op. What is left is a tombstone,
      # which the hourly clone sweeps reap.
      #
      # Reported as a refusal, because that is what it is from the caller's point
      # of view: this method did not confirm the clone is gone, and a caller that
      # reads anything else writes "clone deleted" into a session log about a
      # directory that may still be there.
      logger.error("Failed to cleanup clone", path: path, error: e.message)
      :refused
    end

    private

    # The subdirectory a clone should actually use, or a raise if it has none of
    # the candidates.
    #
    # Normally the one that was asked for. When that one is absent from the tree
    # and a `fallback_subdirectory` was supplied that *is* present, the fallback:
    # an agent root whose directory is renamed in the catalog leaves every session
    # row created before the rename naming the old path, and the caller has no way
    # to know which of the two the freshly cloned commit carries without looking
    # ([#921](https://github.com/tadasant/zimmer/issues/921)).
    #
    # A clone with neither is a hard failure, exactly as it was before the fallback
    # existed — re-resolving is about asking the catalog, not about making a
    # missing directory soft. This owns the existence check rather than leaving a
    # second one to the caller, so the ordinary case still costs the one
    # `directory?` it always cost, and a request for no subdirectory at all costs
    # none. A blank `subdirectory` is returned as-is: a session that never had one
    # must not acquire one from a root that has since grown a subdirectory.
    def resolve_subdirectory!(clone_path, subdirectory, fallback_subdirectory)
      return subdirectory if subdirectory.blank?
      return subdirectory if file_system.directory?(File.join(clone_path, subdirectory))

      if fallback_subdirectory.present? && fallback_subdirectory.to_s != subdirectory.to_s &&
         file_system.directory?(File.join(clone_path, fallback_subdirectory))
        logger.info(
          "Requested subdirectory is absent from the clone; using the agent root's current path",
          requested_subdirectory: subdirectory,
          fallback_subdirectory: fallback_subdirectory
        )
        return fallback_subdirectory
      end

      discard_failed_clone(clone_path)
      raise SubdirectoryNotFoundError, subdirectory_not_found_message(subdirectory, fallback_subdirectory)
    end

    def subdirectory_not_found_message(subdirectory, fallback_subdirectory)
      message = "Subdirectory '#{subdirectory}' not found in repository"
      return message if fallback_subdirectory.blank? || fallback_subdirectory.to_s == subdirectory.to_s

      "#{message} (also tried '#{fallback_subdirectory}')"
    end

    # Dispose of a clone directory this class just created and is rolling back.
    #
    # Deliberately NOT through CloneReaper: the path is not in any session's
    # `clone_path` yet, so the ownership question has no answer worth asking —
    # while a guard that fails closed on a database blip would leave a partial
    # tree here, and `git clone` into a non-empty directory fails with an error
    # #transient_clone_error? does not recognise, turning a retryable failure
    # into a permanent one. Atomic all the same (#412).
    def discard_failed_clone(path)
      return unless path && file_system.directory?(path)

      AtomicCloneRemoval.remove(path, file_system: file_system)
    rescue StandardError => e
      logger.error("Failed to discard a failed clone", path: path, error: e.message)
    end

    # Translate the guard's refusal into a GitError subclass so it flows through
    # the callers' existing rescue paths (AgentSessionJob fails the session and
    # surfaces the message in its log) instead of escaping as an unhandled error.
    def ensure_disk_space!(repo_url, base)
      CloneDiskGuard.ensure_space!(repository_url: repo_url, base: base)
    rescue CloneDiskGuard::InsufficientDiskSpaceError => e
      raise InsufficientDiskSpaceError, e.message
    end

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
            discard_failed_clone(clone_path)
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

      unless SubprocessStatus.success?(status)
        raise GitError, "Git command failed (#{SubprocessStatus.describe_failure(status)}): " \
          "#{command_array.join(' ')}\nStdout: #{stdout}\nStderr: #{stderr}"
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
    # Returns [stdout, stderr, Process::Status] — with a nil status when the child
    # was reaped elsewhere before its waiter ran, so read it through
    # SubprocessStatus. Raises GitTimeoutError (a GitError subclass, classified
    # transient) if the deadline is exceeded.
    def run_subprocess(command_array, cwd:, timeout:)
      BoundedSubprocess.run(command_array, env: GIT_STALL_ENV, cwd: cwd, timeout: timeout)
    rescue BoundedSubprocess::TimeoutError => e
      raise GitTimeoutError, e.message.sub(/\Acommand /, "git command ")
    end
  end
end

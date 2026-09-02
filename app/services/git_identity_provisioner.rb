# frozen_string_literal: true

# GitIdentityProvisioner — writes the commit identity (`user.name` / `user.email`)
# into the container's GLOBAL git config, so a session can commit in the clone it
# was handed.
#
# WHY THIS EXISTS
#
# Zimmer configured git *credentials* centrally and git *identity* nowhere. The
# image's `~/.gitconfig` carried the `gh auth git-credential` helper (Dockerfile.base)
# and no `[user]` section, and clone preparation set a remote and a branch and never
# an identity. So pushing worked and committing did not: the first `git commit` of
# every committing session exited 128 with
#
#   Author identity unknown
#   fatal: empty ident name (for <rails@…>) not allowed
#
# A transcript scan of one production instance found that 118 times in three days,
# spread thin across many clones — every committing session paying it once (#575).
# The session then recovered by *inventing* an identity, usually by reading `git log`,
# which made authorship a norm rediscovered per session rather than a configured
# fact.
#
# WHY THE GLOBAL CONFIG, NOT THE CLONE
#
# The identity could equally be set per clone with `git config --local`. The global
# config wins because a session's working trees are not all clones Zimmer made:
# `GitCloneService` clones the session's own, `ForkSessionService` `git init`s a
# scaffold for a fork with no source tree to copy, `Execution::Providers::LocalFilesystem`
# runs its own `git clone`, and an agent freely makes worktrees and scratch repos of
# its own. One `[user]` section covers all of them — including whatever creates a
# working tree next — where a clone-local write covers exactly the call sites that
# remembered to make it. It also puts identity where credentials already are, which
# is the consistency the issue asks for.
#
# WHY BOOT, NOT BUILD
#
# The values are configuration, so they must not be baked into a public image at
# build time: this deployment's identity is not a self-hoster's. They arrive as
# ordinary env vars through Kamal's `env.clear`, and are written at boot in the same
# best-effort, idempotent shape as the operator SSH key and the `gh` token — see
# `config/initializers/git_identity.rb`.
#
# WHAT AN UNCONFIGURED DEPLOYMENT GETS
#
# Nothing, deliberately, plus one warning line at boot naming the two variables.
# There is no default identity and there must not be: a missing identity fails
# loudly at commit time and is recoverable, while a *guessed* one — `Zimmer Agent
# <zimmer@localhost>` — lands silently in history and is not. Refusing to guess is
# the same reason a half-configured identity (one variable set, not both) provisions
# nothing rather than filling in the other half.
class GitIdentityProvisioner
  # Env vars carrying the identity. Both, or neither.
  NAME_ENV_VAR = "ZIMMER_GIT_USER_NAME"
  EMAIL_ENV_VAR = "ZIMMER_GIT_USER_EMAIL"

  # `git config` is a local file edit with no network in it, so anything beyond a
  # couple of seconds means git is wedged on its own lock — which must not hold up a
  # boot.
  TIMEOUT_SECONDS = 10

  # Serializes the write. Puma and GoodJob both boot Rails in-process, and the
  # session spawn path may reassert this from several `agents` threads at once; two
  # `git config` writers racing on one file is what git's own lock exists for, but
  # losing that race would surface here as a spurious warning.
  MUTEX = Mutex.new

  # Rejects what cannot be a sane ident. `<` and `>` are the ident delimiters
  # themselves, and git refuses a name made of them ("name consists only of
  # disallowed characters"); a newline git would accept and store escaped, as a
  # quoted multi-line value, producing an author nobody meant.
  #
  # Neither can corrupt `~/.gitconfig`: git writes every value through its own
  # escaping, so even `a@b.com"]\n[core]\n\tpager = …` lands as one escaped string
  # rather than a second config section. This is a *typo* check, not a security
  # boundary — it exists so a bad deploy variable is one warning naming that
  # variable, rather than every commit thereafter wearing a mangled author.
  DISALLOWED = /[<>\n\r]/

  # The same check for the email half, which has a shape a name does not. Deliberately
  # minimal — one `@`, no whitespace either side — because this is here to catch
  # `ZIMMER_GIT_USER_EMAIL="Tadas Antanavicius"` (the two variables swapped, or one
  # left as prose), not to adjudicate RFC 5322. git itself accepts anything.
  EMAIL_SHAPE = /\A[^@\s]+@[^@\s]+\z/

  class << self
    # Write `[user]` into the global git config when both variables are set.
    #
    # Idempotent and safe to call on every boot: it reads the current values first
    # and writes only what differs, so a container that is already correct runs two
    # `git config --get-all` calls and stops.
    #
    # Best-effort by design — a missing, malformed, or unwritable identity must never
    # break a boot. It degrades to exactly the state before this class existed
    # (sessions cannot commit until they set an identity themselves) and says so in
    # the log.
    #
    # @param home [String, nil] home directory whose global config to write (defaults to $HOME)
    # @param logger [Logger, nil] where to report (defaults to Rails.logger)
    # @return [Hash, nil] the provisioned {name:, email:}, or nil when nothing was
    def ensure!(home: nil, logger: nil)
      # Resolved in the body, not as default arguments: a default is evaluated
      # *outside* the method's `rescue`, so a raising `Dir.home` or `Rails.logger`
      # would escape `ensure!` entirely and abort the boot this promises never to
      # break.
      home ||= Dir.home
      logger ||= Rails.logger

      name = ENV[NAME_ENV_VAR].presence&.strip
      email = ENV[EMAIL_ENV_VAR].presence&.strip

      if name.nil? && email.nil?
        # The common self-hosted case, not a misconfiguration to shout about — one
        # line, once, naming both variables.
        logger.info "No git identity is configured (#{NAME_ENV_VAR} / #{EMAIL_ENV_VAR}); " \
          "agent sessions will not be able to commit until one is"
        return nil
      end

      if name.nil? || email.nil?
        missing = name.nil? ? NAME_ENV_VAR : EMAIL_ENV_VAR
        logger.warn "#{missing} is not set, so no git identity was provisioned — " \
          "git needs both a name and an email to commit, and Zimmer will not invent the missing half"
        return nil
      end

      if name.match?(DISALLOWED) || email.match?(DISALLOWED)
        offender = name.match?(DISALLOWED) ? NAME_ENV_VAR : EMAIL_ENV_VAR
        logger.warn "#{offender} contains a character git cannot put in an ident line (<, >, or a newline) — " \
          "no git identity was provisioned"
        return nil
      end

      unless email.match?(EMAIL_SHAPE)
        logger.warn "#{EMAIL_ENV_VAR} does not look like an email address (#{email.inspect}) — " \
          "no git identity was provisioned"
        return nil
      end

      MUTEX.synchronize { write_identity(name, email, home: home, logger: logger) }
    rescue => e
      logger.warn "Failed to provision the git identity: #{e.class} - #{e.message}"
      nil
    end

    # Path the identity is (or would be) written to, without provisioning it.
    #
    # Named explicitly rather than left to `--global`'s own search, which prefers
    # `$XDG_CONFIG_HOME/git/config` when `~/.gitconfig` is absent — so on a home
    # without one the file git wrote and the file a reader expected could differ.
    #
    # @param home [String] the home directory
    # @return [String] absolute path to the global git config
    def config_path(home: Dir.home)
      File.join(home, ".gitconfig")
    end

    private

    def write_identity(name, email, home:, logger:)
      path = config_path(home: home)
      written = false

      { "user.name" => name, "user.email" => email }.each do |key, value|
        existing = read_config(key, path: path)
        next if existing == [ value ]

        # Logged before the write, and only when something is actually being taken
        # away, so a value this replaces is recoverable from the log. That matters
        # most off the deployment: a developer who exports these and then runs
        # `bin/rails console` is having their personal global identity rewritten,
        # and `--replace-all` leaves no other trace of what was there.
        logger.warn "Replacing the existing global #{key} #{existing.inspect} with #{value.inspect} in #{path}" if existing.any?

        run_git([ "config", "--global", "--replace-all", key, value ], path: path)
        written = true
      end

      logger.info "Provisioned the git identity #{name} <#{email}> in #{path}" if written
      { name: name, email: email }
    end

    # Every value a global key currently holds, oldest first — `[]` when unset.
    #
    # `--get-all` rather than `--get`, which returns only the LAST of several values
    # with exit 0: a config that somehow carries the key twice would then compare
    # equal and never be converged, leaving the duplicate forever. Exit 1 means "not
    # found", which is not a failure worth raising over.
    def read_config(key, path:)
      stdout, _stderr, status = run_subprocess([ "git", "config", "--global", "--get-all", key ], path: path)
      return [] unless SubprocessStatus.success?(status)

      stdout.lines.map(&:strip).reject(&:empty?)
    end

    def run_git(args, path:)
      _stdout, stderr, status = run_subprocess([ "git" ] + args, path: path)
      return if SubprocessStatus.success?(status)

      raise "git #{args.join(' ')} failed: #{SubprocessStatus.describe_failure(status, stderr)}"
    end

    # GIT_CONFIG_GLOBAL pins which file `--global` means, so this writes the config
    # for the home it was given rather than for whatever `$HOME` the calling process
    # happens to hold — which is what lets a test drive it against a temp directory
    # without mutating the machine's real one.
    def run_subprocess(command_array, path:)
      BoundedSubprocess.run(
        command_array,
        env: { "GIT_CONFIG_GLOBAL" => path },
        timeout: TIMEOUT_SECONDS
      )
    end
  end
end

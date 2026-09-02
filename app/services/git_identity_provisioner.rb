# frozen_string_literal: true

# GitIdentityProvisioner — writes the commit identity (`user.name` / `user.email`)
# into the container's GLOBAL git config, so a session can commit in the clone it
# was handed.
#
# WHY THIS EXISTS
#
# Zimmer configures git *credentials* centrally and git *identity* nowhere. The
# image's `~/.gitconfig` carries the `gh auth git-credential` helper (Dockerfile.base)
# and no `[user]` section, and clone preparation sets a remote and a branch and never
# an identity. So pushing works and committing does not: the first `git commit` of
# every committing session exits 128 with
#
#   Author identity unknown
#   fatal: empty ident name (for <rails@…>) not allowed
#
# A transcript scan of one production instance found that 118 times in three days,
# spread thin across many clones — every committing session paying it once (#575).
# The session then recovers by *inventing* an identity, usually by reading `git log`,
# which makes authorship a norm rediscovered per session rather than a configured
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
  # Neither can corrupt `~/.gitconfig` — git writes the value through its own
  # escaping, and Kamal's env-file encoder turns a real newline into a literal `\n`
  # before it ever reaches here. This is caught early so a typo in a deploy variable
  # is one warning naming that variable, rather than every commit thereafter wearing
  # a mangled author.
  DISALLOWED = /[<>\n\r]/

  class << self
    # Write `[user]` into the global git config when both variables are set.
    #
    # Idempotent and safe to call on every boot: it reads the current values first
    # and writes only what differs, so a container that is already correct runs two
    # `git config --get` calls and stops.
    #
    # Best-effort by design — a missing, malformed, or unwritable identity must never
    # break a boot. It degrades to exactly the state before this class existed
    # (sessions cannot commit until they set an identity themselves) and says so in
    # the log.
    #
    # @param home [String] home directory whose global config to write (defaults to $HOME)
    # @param logger [Logger] where to report
    # @return [Hash, nil] the provisioned {name:, email:}, or nil when nothing was
    def ensure!(home: Dir.home, logger: Rails.logger)
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
        next if read_config(key, path: path) == value

        run_git([ "config", "--global", "--replace-all", key, value ], path: path)
        written = true
      end

      logger.info "Provisioned the git identity #{name} <#{email}> in #{path}" if written
      { name: name, email: email }
    end

    # Current value of a global key, or nil when unset. `git config --get` exits 1
    # for "not found", which is not a failure worth raising over.
    def read_config(key, path:)
      stdout, _stderr, status = run_subprocess([ "git", "config", "--global", "--get", key ], path: path)
      return nil unless SubprocessStatus.success?(status)

      stdout.strip.presence
    end

    def run_git(args, path:)
      stdout, stderr, status = run_subprocess([ "git" ] + args, path: path)
      return if SubprocessStatus.success?(status)

      raise "git #{args.join(' ')} failed (#{SubprocessStatus.describe_failure(status)}): #{stdout}#{stderr}"
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

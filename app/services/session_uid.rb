# frozen_string_literal: true

require "set"

# SessionUid — run an agent session's processes as a unix uid of its own.
#
# WHY
# ---
# Without this, every agent session runs as uid 1000, the same user as the Rails app
# and the GoodJob worker, in the same container. Same uid means a session can read
# `/proc/<worker pid>/environ` (RAILS_MASTER_KEY, SECRET_KEY_BASE, API_KEYS, the
# Parameter Store resolver key, ...), every file the app keeps under its home, and
# every other session's clone and config directory. Scrubbing the spawn environment
# (CliSpawnEnv::SCRUBBED_SECRET_ENV_VARS) closes the casual route and none of those.
# A uid boundary closes all three, because the kernel enforces it.
#
# WHAT IT DOES, WHEN ZIMMER_SESSION_UID=1
# ---------------------------------------
# * The container starts as root and bin/docker-entrypoint drops the app to uid 1000
#   keeping a short list of AMBIENT capabilities (APP_CAPABILITIES): enough to start
#   a process as another uid, hand files to it, read what it wrote, and signal it.
# * Each in-scope session is given its own uid from a reserved range, recorded in
#   `sessions.agent_uid` (#allocate!).
# * Before every spawn, SessionUid::Sandbox hands the session's own directories to
#   that uid and gives it a private HOME.
# * The runtime's argv is wrapped in `setpriv` (#wrap), which switches to that uid,
#   drops every capability, clears supplementary groups and sets no_new_privs, so
#   nothing the agent runs can gain a privilege back.
# * SessionUid::Lockdown, before a worker's first isolated spawn, takes group and other
#   access off the app's own files and off every per-session directory that predates
#   the flag.
#
# A session OUT of scope still runs as uid 1000, as today, but through
# #strip_capabilities so it never inherits the app's ambient set. Out of scope means:
# a root not listed in ZIMMER_SESSION_UID_ROOTS (when that is set), or a runtime this
# does not cover yet (ISOLATED_RUNTIMES). Such a session can still read everything
# uid 1000 can — including isolated sessions' files — so the boundary only holds on a
# deployment where every session is in scope. docs/src/content/docs/limitations.md
# says so.
#
# With the flag unset nothing here runs: #wrap is never reached, #confine returns its
# argument unchanged, and no file is chowned or chmodded. That is the posture every
# deployment that never sets the flag (PulseMCP's included) stays in.
module SessionUid
  FLAG = "ZIMMER_SESSION_UID"
  ROOTS = "ZIMMER_SESSION_UID_ROOTS"
  RANGE_MIN = "ZIMMER_SESSION_UID_MIN"
  RANGE_MAX = "ZIMMER_SESSION_UID_MAX"
  DOCKER = "ZIMMER_SESSION_UID_DOCKER"

  # Inside the 65536 ids a sysbox or Incus user namespace maps by default, and clear
  # of the 1000s a distribution hands to real users. bin/docker-entrypoint writes a
  # passwd entry for each, so the same defaults live there too.
  DEFAULT_MIN = 20_000
  DEFAULT_MAX = 49_999

  APP_UID = 1000

  # Only claude_code today. Codex keeps one CODEX_HOME for every session (auth.json the
  # account pool and the CLI both rotate, and every rollout), and Pi one
  # PI_CODING_AGENT_DIR; splitting those per session is its own change. Until then their
  # sessions run as the app uid with capabilities stripped. See limitations.md.
  ISOLATED_RUNTIMES = %w[claude_code].freeze

  # The capabilities the app keeps after the entrypoint drops it to uid 1000, as
  # capability bit numbers (linux/capability.h). bin/docker-entrypoint names the same
  # set; test/services/session_uid_test.rb holds the two together.
  #
  #   chown        hand a session's files to its uid
  #   dac_override read what a session wrote 0600, write into its 0700 directories
  #   fowner       chmod files a session owns
  #   kill         signal a session's process group
  #   setgid/uid   start a process as the session's uid (setpriv)
  APP_CAPABILITIES = {
    "chown" => 0, "dac_override" => 1, "fowner" => 3, "kill" => 5, "setgid" => 6, "setuid" => 7
  }.freeze

  # Raised when a session in scope cannot be given its uid. The spawn fails rather
  # than running the session as the app's uid: an operator who turned the flag on is
  # relying on the boundary, and silently running without it is the one outcome they
  # would never notice.
  class Unavailable < StandardError; end

  # What a spawn needs to know about an isolated session.
  Context = Struct.new(:session_id, :uid, :home, keyword_init: true)

  module_function

  # @return [Boolean] whether the deployment asked for per-session uids
  def enabled?(env = ENV)
    env[FLAG].to_s.strip == "1"
  end

  # @return [Array<String>] the agent roots isolation is limited to; empty means all
  def scoped_roots(env = ENV)
    env[ROOTS].to_s.split(",").map(&:strip).reject(&:empty?)
  end

  # @return [Boolean] whether isolated sessions also get the nested-Docker socket
  def docker_allowed?(env = ENV)
    env[DOCKER].to_s.strip == "1"
  end

  # @return [Range<Integer>]
  def range(env = ENV)
    min = Integer(env[RANGE_MIN].presence || DEFAULT_MIN, exception: false) || DEFAULT_MIN
    max = Integer(env[RANGE_MAX].presence || DEFAULT_MAX, exception: false) || DEFAULT_MAX
    min = DEFAULT_MIN if min <= APP_UID
    max = min if max < min
    min..max
  end

  # @return [Boolean] whether `uid` is one this module hands out
  def agent_uid?(uid, env = ENV)
    uid.is_a?(Integer) && range(env).cover?(uid)
  end

  # Whether a session's agent should run under a uid of its own.
  #
  # @param session [Session]
  def applies_to?(session, env = ENV)
    return false unless enabled?(env)
    return false unless ISOLATED_RUNTIMES.include?(session.agent_runtime.to_s)

    roots = scoped_roots(env)
    roots.empty? || roots.include?(session.metadata&.dig("agent_root_key").to_s)
  end

  # Whether this process holds every capability in APP_CAPABILITIES. False on every
  # deployment without the flag, because the entrypoint only grants them under it.
  def capable?(status_path: "/proc/self/status")
    effective = capability_mask(status_path, "CapEff")
    return false if effective.nil?

    APP_CAPABILITIES.values.all? { |bit| effective[bit] == 1 }
  end

  # Whether this process carries ambient capabilities a child would inherit.
  def ambient_capabilities?(status_path: "/proc/self/status")
    mask = capability_mask(status_path, "CapAmb")
    !mask.nil? && mask.positive?
  end

  def capability_mask(status_path, field)
    line = File.foreach(status_path).find { |l| l.start_with?("#{field}:") }
    line && Integer(line.split(":", 2).last.strip, 16)
  rescue SystemCallError, ArgumentError
    nil
  end

  # Give `session` a uid, or return the one it already has.
  #
  # The search starts at `id mod size` so consecutive sessions spread across the range
  # and a uid freed by EmptyTrashJob is not handed straight back out. The unique index
  # on `agent_uid` is what makes a race between two spawns safe: the loser moves on.
  #
  # @param session [Session]
  # @return [Integer]
  # @raise [Unavailable] when every uid in the range is held
  def allocate!(session, env = ENV)
    current = session.agent_uid
    return current if agent_uid?(current, env)

    span = range(env)
    size = span.size
    taken = Session.where.not(agent_uid: nil).where.not(id: session.id).pluck(:agent_uid).to_set
    start = session.id.to_i % size

    size.times do |offset|
      uid = span.first + ((start + offset) % size)
      next if taken.include?(uid)

      begin
        updated = Session.where(id: session.id).where(agent_uid: current).update_all(agent_uid: uid)
      rescue ActiveRecord::RecordNotUnique
        taken << uid
        next
      end

      if updated == 1
        session.agent_uid = uid
        session.clear_attribute_changes([ :agent_uid ])
        return uid
      end

      # Someone else allocated for this session between the read and the write.
      session.reload
      return session.agent_uid if agent_uid?(session.agent_uid, env)
    end

    raise Unavailable, "every uid in #{span} is held by a session; widen #{RANGE_MIN}/#{RANGE_MAX}"
  end

  # Free a session's uid once nothing it owned is left on disk. EmptyTrashJob calls
  # this after it has removed the session's directories.
  #
  # Two things can outlive those directories under the same uid, and the next session
  # handed it would inherit both: a process the agent detached (setsid, nohup) and files
  # it left in /tmp or /dev/shm. Both go first. When this process cannot do that (no
  # capabilities, so no flag), the uid is not freed at all.
  def release!(session)
    uid = session.agent_uid
    return if uid.nil?
    return unless agent_uid?(uid)
    return unless capable?

    system("pkill", "-KILL", "-U", uid.to_s, out: File::NULL, err: File::NULL)
    system("find", "/tmp", "/dev/shm", "-xdev", "-uid", uid.to_s, "-delete", out: File::NULL, err: File::NULL)

    Session.where(id: session.id).update_all(agent_uid: nil)
    session.agent_uid = nil
    session.clear_attribute_changes([ :agent_uid ])
  end

  # The context a spawn for `session_id` needs, after its directories have been handed
  # to its uid. Nil when the session is out of scope.
  #
  # @param session_id [Integer, String, nil]
  # @param working_dir [String]
  # @return [Context, nil]
  # @raise [Unavailable]
  def context_for(session_id, working_dir:, env: ENV)
    return nil unless enabled?(env)
    return nil if session_id.blank?

    session = Session.find_by(id: session_id)
    return nil if session.nil? || !applies_to?(session, env)

    unless capable?
      raise Unavailable,
        "#{FLAG}=1 but this worker does not hold #{APP_CAPABILITIES.keys.join(', ')}. The worker " \
        "must start as root so bin/docker-entrypoint can grant them; config/deploy.*.yml does " \
        "that whenever #{FLAG} is set. Session #{session.id} was not started as uid #{APP_UID}."
    end

    begin
      Lockdown.ensure_applied!
    rescue SystemCallError => e
      raise Unavailable, "could not close the app's files to sessions: #{e.message}"
    end

    uid = allocate!(session, env)
    home = Sandbox.new(session: session, uid: uid, working_dir: working_dir).prepare!
    Context.new(session_id: session.id, uid: uid, home: home)
  end

  # Wrap an argv so it runs as `uid` with no capabilities and no way to regain any.
  #
  # `--no-new-privs` is what makes the drop stick: a setuid-root or file-capability
  # binary in the image is inert afterwards. Supplementary groups are cleared, which
  # also takes away the nested-Docker socket (group 1000) unless DOCKER is set — and
  # Docker access is the one thing that voids this boundary, because the inner daemon
  # will bind-mount any path of the container into a container of the agent's choosing.
  #
  # The shell in the middle sets umask 077 so everything the agent creates is its own.
  #
  # @param command [Array<String>]
  # @param uid [Integer]
  # @return [Array<String>]
  def wrap(command, uid:, env: ENV)
    groups = docker_allowed?(env) ? "--groups=#{APP_UID}" : "--clear-groups"
    [
      "setpriv", "--reuid=#{uid}", "--regid=#{uid}", groups,
      "--inh-caps=-all", "--ambient-caps=-all", "--no-new-privs",
      "--", "/bin/sh", "-c", 'umask 077 && exec "$@"', "zimmer-session-uid", *command
    ]
  end

  # Wrap an argv so it runs as the app's uid WITHOUT the app's ambient capabilities.
  # Used for every out-of-scope session while the flag is on. A no-op when this process
  # carries no ambient capabilities, which is every deployment without the flag.
  def strip_capabilities(command)
    return command unless enabled? && ambient_capabilities?

    [ "setpriv", "--inh-caps=-all", "--ambient-caps=-all", "--", *command ]
  end

  # The isolated-session environment overlay, applied on top of what the runtime built.
  #
  # nil values unset the variable in the child, as everywhere in the spawn env.
  #
  # @param env_vars [Hash]
  # @param context [Context]
  # @return [Hash]
  def apply_env(env_vars, context)
    env_vars["HOME"] = context.home
    env_vars["USER"] = env_vars["LOGNAME"] = "zimmer-s#{context.uid}"
    # The operator SSH key is a file only uid 1000 can read, and a long-lived secret an
    # agent should not hold anyway (production invariant 2).
    env_vars["SSH_PRIVATE_KEY_PATH"] = nil
    # The login-free gh directory GithubTokens hands every routed session is shared and
    # owned by the app; each isolated session gets one of its own in its HOME.
    env_vars["GH_CONFIG_DIR"] = File.join(context.home, ".config", "gh")
    %w[XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME].each { |key| env_vars[key] = nil }
    env_vars
  end

  # --- Rails subprocesses inside a session's files ----------------------------------

  # The agent uid that owns `path`, when the flag is on, this process can switch to it,
  # and the owner is an agent uid. Nil otherwise — including always with the flag off.
  def owner_uid_for(path)
    return nil unless enabled?
    return nil if path.blank?

    uid = File.stat(path.to_s).uid
    agent_uid?(uid) && capable? ? uid : nil
  rescue SystemCallError
    nil
  end

  # Turn a Rails-side subprocess that would run inside a directory an agent owns into
  # one that runs AS that agent, with a minimal environment.
  #
  # Rails runs git (and bundler) in session clones. Run as uid 1000, git refuses a
  # repository another user owns, and if told not to, it runs whatever the agent put in
  # `.git/config` or `.git/hooks` with the app's privileges — the escape this whole
  # module exists to close. Run as the owner, it is only the agent running its own code.
  #
  # The environment is rebuilt rather than inherited (`unsetenv_others`): the worker's
  # holds every deploy secret, and a hook in the clone would see all of them.
  #
  # @param command [Array<String>]
  # @param dir [String] the directory the command acts on
  # @param env [Hash] variables the caller passes explicitly
  # @return [Array(Array<String>, Hash, Hash)] argv, env, extra Process.spawn options;
  #   the inputs unchanged (and no extra options) when `dir` is not agent-owned
  def as_owner_of(dir, command, env = {})
    uid = owner_uid_for(dir)
    return [ command, env, {} ] if uid.nil?

    session = Session.find_by(agent_uid: uid)
    home = session ? SessionHomeDirectory.path_for(session.id) : "/nonexistent"
    base = ENV.to_h.slice("PATH", "LANG", "LC_ALL", "TZ")
    child_env = base.merge("HOME" => home, "USER" => "zimmer-s#{uid}", "LOGNAME" => "zimmer-s#{uid}")
                    .merge(env.to_h.compact)
    [ wrap(command, uid: uid, env: {}), child_env, { unsetenv_others: true } ]
  end

  # The directory a git argv acts on: the value after `-C`, else `cwd`.
  def git_target_dir(command, cwd)
    if command.first == "git"
      index = command.index("-C")
      return command[index + 1] if index && command[index + 1]
    end
    cwd
  end
end

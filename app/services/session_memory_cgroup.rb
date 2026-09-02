# frozen_string_literal: true

# A per-session memory bound, enforced by the kernel.
#
# WHY THIS EXISTS
# ---------------
# The worker container runs every agent session on the box, plus the Rails worker,
# plus the nested dockerd/containerd, in ONE cgroup with ONE 10 GiB `memory.max`
# (config/deploy.production.yml). Nothing partitioned that budget, so a single
# session's runaway tool call could spend all of it.
#
# On 2026-09-02 one did: a session's own `bash` reached 6.5 GiB of anonymous RSS in
# a `… | head` pipeline and the kernel OOM-killed it at the container cap
# (tadasant/zimmer#815). Nothing else died that time, because `oom_score` roughly
# tracks RSS and the offender happened to be the biggest thing in the cgroup. When
# it does not — tadasant/zimmer#502 (wedged sysbox worker), tadasant/zimmer#719
# (`bundle` killed four times an hour) — the victim is the Rails worker or the inner
# daemon, and every other session on the box goes with it.
#
# So each session gets its own cgroup with its own `memory.max`. A runaway command
# now exhausts its OWN budget and the kernel kills something inside THAT cgroup,
# which bounds the blast radius to the session that caused it. The container cap
# still exists and still protects the host; this is the missing layer underneath it.
#
# WHAT IT ALSO BUYS
# -----------------
# #815 could not establish which session issued the offending command: "on a
# shared-cgroup worker there is no path from 'a process was OOM-killed' to 'this
# session did it'". The cgroup is named `session-<id>`, so the kernel's own
# `oom-kill:` line now carries `oom_memcg=/zimmer.sessions/session-12398` and names
# it for us — no extra plumbing, and it works for the kill we did not anticipate.
# `memory.peak` and `memory.events` give the same attribution while the session is
# still alive.
#
# HOW A PROCESS GETS IN
# ---------------------
# cgroup v2 has no `Process.spawn` option for this, so the child puts itself in:
# #enter_command wraps the argv in a two-line `sh` that writes its own pid to
# `cgroup.procs` and then `exec`s the real command. `exec` keeps the pid, so the
# process group, the recorded `process_pid` and every signal path are unchanged —
# the wrapper is gone by the time anything observes the process. Descendants inherit
# the cgroup, which is the whole point: the runaway was a grandchild, not the agent.
#
# WHERE IT WORKS, AND WHERE IT QUIETLY DOES NOT
# ---------------------------------------------
# It needs a writable cgroup2 filesystem, which the worker has only because it runs
# under sysbox (ZIMMER_NESTED_DOCKER=1) with its own cgroup namespace. Under plain
# runc `/sys/fs/cgroup` is read-only; on a dev Mac there is no cgroupfs at all. So
# every method here degrades to a no-op rather than raising, and #enter_command hands
# back the command untouched. An unbounded session is exactly today's behaviour, and
# a failed bound must never be the thing that stops a session from running.
#
# `bin/docker-entrypoint` does the one part that needs root: it creates the delegated
# parent, enables the memory controller on it, hands it to uid 1000, and moves the app
# into a sibling cgroup so that uid 1000 can migrate processes within the delegated
# subtree. See that file for why the sibling is load-bearing.
#
# NOT A SANDBOX. An agent runs as the same uid that owns the delegated subtree, so it
# could move itself out. This is a guardrail against a runaway command, not a boundary
# against a hostile one — Zimmer has no such boundary anywhere and this does not
# pretend to add one.
class SessionMemoryCgroup
  # The delegated parent, created by bin/docker-entrypoint. Overridable so tests can
  # point at a tmpdir and so an operator can move it without a new image.
  DEFAULT_PARENT = "/sys/fs/cgroup/zimmer.sessions"

  # 4 GiB per session.
  #
  # Sized to sit well above real usage and well below the container cap. A healthy
  # worker was measured at 1.6 GiB of anonymous memory with three concurrent sessions
  # — and that figure includes the ~845 MB Rails worker — so a session in normal
  # operation is a few hundred MB. 4 GiB is roughly an order of magnitude of headroom,
  # enough for the genuinely heavy cases (a Chromium under the Playwright MCP server, a
  # large build) while still catching the 6.5 GiB runaway that prompted this.
  #
  # It deliberately does NOT sum to the container cap: six sessions at 4 GiB is 24 GiB
  # against a 10 GiB container. That is not an oversight. This bounds ONE runaway
  # session, which is the failure that has actually happened twice; making it an
  # admission-control budget would mean setting it near 1.5 GiB, which would start
  # killing sessions that work today. A conservative bound plus per-session visibility
  # is the right first cut, and `memory.peak` is now recorded per session so the number
  # can be tightened on evidence rather than on guesswork.
  DEFAULT_LIMIT_BYTES = 4 * 1024 * 1024 * 1024

  # `sh -c SCRIPT $0 $1 $2...`: $1 is the cgroup.procs path, $2 onward are the real
  # argv. The shell writes its own pid — which `exec` then keeps — and gets out of the
  # way. Both branches fall through to the exec, so a cgroup that cannot be joined costs
  # the bound and nothing else.
  ENTER_SCRIPT = <<~SH.freeze
    if ! echo $$ > "$1"; then
      echo "zimmer: could not join memory cgroup $1 - running without a per-session memory bound" >&2
    fi
    shift
    exec "$@"
  SH

  # What #stats answers. `nil` fields mean "could not read", which is different from
  # zero and is reported as such rather than papered over with a default.
  Stats = Struct.new(:current_bytes, :peak_bytes, :oom_kills, :limit_bytes, keyword_init: true) do
    def oom_killed?
      oom_kills.to_i.positive?
    end
  end

  class << self
    # The delegated parent cgroup's path. Resolved at call time, never memoized, so a
    # test that stubs the env and an operator who sets it at deploy time both take
    # effect without a process restart.
    def parent_path
      ENV["ZIMMER_SESSION_CGROUP_ROOT"].presence || DEFAULT_PARENT
    end

    # The per-session `memory.max`, in bytes.
    #
    # Configured in MB at deploy time (config/deploy.*.yml) so changing it is a deploy
    # rather than a shell on the box. A zero or unparseable value means "no bound" and
    # is honoured as such — an operator disabling this in an incident should not have to
    # fight a floor.
    def limit_bytes
      configured = ENV["ZIMMER_SESSION_MEMORY_MAX_MB"].presence
      return DEFAULT_LIMIT_BYTES if configured.nil?

      megabytes = Integer(configured, exception: false)
      return DEFAULT_LIMIT_BYTES if megabytes.nil? || megabytes.negative?

      megabytes * 1024 * 1024
    end

    # Is a per-session bound available in this container?
    #
    # True only when the delegated parent exists AND this uid can create children in
    # it — the two halves bin/docker-entrypoint provides together. Anything else (plain
    # runc, the web role, a dev machine, a test run) is false and every caller no-ops.
    def available?
      path = parent_path
      File.directory?(path) && File.writable?(path)
    rescue SystemCallError
      false
    end

    # The bound for one session, or nil when this container cannot enforce one.
    #
    # @param session_id [Integer, String, nil]
    # @return [SessionMemoryCgroup, nil]
    def for(session_id)
      return nil if session_id.blank?
      return nil unless available?

      new(session_id)
    end

    # Remove every session cgroup that no longer holds a process.
    #
    # A cgroup outlives the session's processes: `rmdir` fails while any pid is still
    # in it, and a session can end in ways that never reach #remove (a worker killed
    # mid-deploy, a job interrupted). An empty cgroup costs a directory and a few
    # kernel structs, but they accumulate one per session forever, so something has to
    # sweep. Emptiness is the whole test — a cgroup with a live process in it is a live
    # session, whatever the database thinks, and rmdir would refuse anyway.
    #
    # @return [Integer] how many were removed
    def sweep!
      return 0 unless available?

      Dir.children(parent_path).count do |name|
        next false unless name.start_with?("session-")

        remove_if_empty(File.join(parent_path, name))
      end
    rescue SystemCallError => e
      Rails.logger.warn("[SessionMemoryCgroup] Sweep failed: #{e.message}")
      0
    end

    # @return [Boolean] true if the cgroup was removed
    def remove_if_empty(path)
      return false unless holds_no_processes?(path)

      # `rmdir` and nothing else. A cgroup directory shows control files that no
      # unlink can remove, and the kernel takes them with the directory — so `rmdir`
      # is both the right call and the only one, and its EBUSY is what makes "no
      # processes" a check rather than a race.
      Dir.rmdir(path)
      true
    rescue SystemCallError
      # EBUSY (a process is still in it, or it has children) and ENOENT (someone else
      # removed it) are both ordinary here, and neither is worth a log line every tick.
      false
    end

    def holds_no_processes?(path)
      File.read(File.join(path, "cgroup.procs")).empty?
    rescue Errno::ENOENT
      # No cgroup.procs means no cgroup left to speak of; let rmdir have the last word.
      true
    end
  end

  attr_reader :session_id

  def initialize(session_id)
    @session_id = session_id.to_s
  end

  def name
    "session-#{session_id}"
  end

  def path
    File.join(self.class.parent_path, name)
  end

  def procs_path
    File.join(path, "cgroup.procs")
  end

  # Create the cgroup and write its limit. Idempotent: a session that respawns — a
  # continuation, a signal-death resume, a follow-up turn — reuses the same cgroup, so
  # `memory.peak` and the OOM counter accumulate across the session's whole life rather
  # than resetting on every turn.
  #
  # @return [Boolean] true if the cgroup is ready to be entered
  def prepare!
    FileUtils.mkdir_p(path)

    limit = self.class.limit_bytes
    File.write(File.join(path, "memory.max"), limit.zero? ? "max" : limit.to_s)

    # Deliberately no `memory.high`. It throttles the allocator and reclaims before the
    # hard limit, which sounds like a gentler failure — but the memory at issue here is
    # anonymous and the worker has no swap, so there is nothing to reclaim. All it would
    # buy is a session that stalls for a long time and then gets killed anyway, which is
    # a less legible failure than being killed promptly. Early warning comes from polling
    # `memory.current` instead (AgentSessionJob), which costs nothing and cannot stall
    # anyone.
    true
  rescue SystemCallError => e
    Rails.logger.warn("[SessionMemoryCgroup] Could not prepare #{path}: #{e.message}")
    false
  end

  # Wrap a command so that it runs inside this cgroup.
  #
  # The child writes its own pid to `cgroup.procs` and `exec`s the real command, which
  # preserves the pid — so `pgroup: true`, the recorded `process_pid`, the SIGTERM
  # escalation path and the transcript pollers all see exactly what they saw before.
  #
  # `$1` rather than an interpolated path so a path with a space or a quote in it cannot
  # become shell syntax. A failure to enter warns on stderr — which the monitoring loop
  # already tails into the session log, alongside the shell's own error — and runs the
  # command anyway: unbounded is today's behaviour, and refusing to start the session
  # would be a far worse trade than running it without a bound.
  #
  # @param command [Array<String>] the argv the adapter built
  # @return [Array<String>] argv to hand Process.spawn
  def enter_command(command)
    [ "/bin/sh", "-c", ENTER_SCRIPT, "zimmer-session-memory-cgroup", procs_path, *command ]
  end

  # Current usage, high-water mark, and how many processes the kernel has OOM-killed in
  # this cgroup over the session's life.
  #
  # `memory.peak` needs Linux 5.19; older kernels leave it nil rather than failing the
  # whole read, because the OOM counter is the part that matters and it has been there
  # since cgroup v2 landed.
  #
  # @return [Stats]
  def stats
    Stats.new(
      current_bytes: read_integer("memory.current"),
      peak_bytes: read_integer("memory.peak"),
      oom_kills: read_event("oom_kill"),
      limit_bytes: read_integer("memory.max")
    )
  end

  # @return [Integer, nil] processes the kernel has OOM-killed in this cgroup, or nil
  #   if the counter could not be read
  def oom_kill_count
    read_event("oom_kill")
  end

  def exists?
    File.directory?(path)
  end

  # @return [Boolean] true if the cgroup was removed
  def remove
    self.class.remove_if_empty(path)
  end

  private

  def read_integer(file)
    value = File.read(File.join(path, file)).strip
    return nil if value == "max"

    Integer(value, exception: false)
  rescue SystemCallError
    nil
  end

  # `memory.events` is a flat "key value" table; oom_kill counts tasks the kernel killed
  # in this cgroup, and never decreases.
  def read_event(key)
    File.foreach(File.join(path, "memory.events")) do |line|
      name, value = line.split
      return Integer(value, exception: false) if name == key
    end
    nil
  rescue SystemCallError
    nil
  end
end

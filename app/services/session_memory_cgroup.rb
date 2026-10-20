# frozen_string_literal: true

# A per-session memory bound, and an aggregate bound over all of them, enforced by
# the kernel.
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
# exhausts its OWN budget and the kernel kills something inside THAT cgroup, which
# bounds the blast radius to the session that caused it. The container cap protects
# the host; this is the layer underneath it.
#
# THE FAILURE THAT NEEDED A SECOND BOUND
# --------------------------------------
# A per-session bound sums to nothing. On 2026-09-05 (tadasant/zimmer#981) eight
# concurrent sessions, none of them anywhere near its 4 GiB, each ran a parallel Rails
# suite: 41 `ruby` processes at 215-350 MB apiece, 8.7 GB of anonymous memory between
# them. The container's own 10 GiB cap fired, and because THAT memcg holds the app as
# well as the sessions, the kernel picked the biggest process in it -- `bundle exec
# good_job start`, at 943 MB. The Rails worker died, and every in-flight session with
# it. There was no runaway to catch: the largest process on the box was under 1 GB.
#
# The answer is a second `memory.max`, on a `sessions` POOL cgroup that holds every
# session cgroup and nothing else. Then a pile-up declares its OOM in a memcg the
# worker is not inside, and the kernel's victim can only be a session process.
#
# Where the cap sits is the entire point, and the obvious placement is wrong: a
# `memory.max` on the delegated parent `zimmer.sessions` would also cover
# `zimmer.sessions/app`, which is where bin/docker-entrypoint puts the Rails worker.
# The kernel selects an OOM victim by size across the whole subtree of the memcg that
# declared the OOM, so that placement puts the worker straight back in the victim pool
# -- the failure, relocated one level down rather than fixed. Hence the extra level.
#
# What this does NOT do is stop sessions from being killed. Under the load that
# produced #981 the pool would have been exhausted and a session process would have
# died. That is the trade being made deliberately: one session dies with an
# attributable cause and a recovery prompt, instead of the worker dying and taking
# every session on the box with it.
#
# WHAT IT ALSO BUYS
# -----------------
# #815 could not establish which session issued the offending command: "on a
# shared-cgroup worker there is no path from 'a process was OOM-killed' to 'this
# session did it'". The cgroup is named `session-<id>`, so the kernel's own
# `oom-kill:` line carries `oom_memcg=/zimmer.sessions/sessions/shared/session-12398` and names it
# for us — no extra plumbing, and it works for the kill nobody anticipated.
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
# parent, enables the memory controller on it, hands it to uid 1000, moves the app into
# a sibling cgroup so that uid 1000 can migrate processes within the delegated subtree,
# and creates the `sessions` pool with the aggregate `memory.max` on it. See that file
# for why both children are load-bearing.
#
# The pool's own `memory.max` is left root-owned there, so the aggregate bound cannot be
# widened from inside the app. Everything else about the pool is delegated, because the
# app has to create and remove session cgroups inside it.
#
# A ONE-OFF BOOST, AND WHY IT IS A CARVE-OUT
# -------------------------------------------
# Some sessions genuinely need more than 4 GiB — a Rust build linking a desktop app is the
# case that prompted it — and SessionMemoryBoost lets ONE session have more, for a while,
# without moving any default. Raising that session's own `memory.max` is the easy half and
# on its own buys nothing: session 25433 was killed twice by the POOL (`oom` 0, `oom_kill`
# 2), well inside its own 4 GiB, because the other sessions on the box were holding the rest
# of the pool. Headroom a session cannot actually allocate is not headroom.
#
# The pool's cap is root-owned so that the app cannot widen it, and that stays true: a boost
# is paid for out of the pool, never added on top of it. So the pool has two tiers under it:
#
#   sessions                memory.max 6g (root-owned, unchanged)
#   |-- shared              memory.max max, or pool - boost while a boost is held
#   |   |-- session-12398   memory.max 4g
#   |   `-- session-12401   memory.max 4g
#   `-- boosted
#       `-- session-25433   memory.max = the boost
#
# Without a boost, `shared` carries no cap of its own and the pool is the bound, exactly as
# before. With one, the kernel itself enforces the reservation: everyone else together can
# reach only what the boost left them, so the boosted session can always allocate its share.
# The protection the pool gives the Rails worker is untouched, because both tiers are inside
# it. What the other sessions give up is the boost's size, which is the trade being made on
# purpose and the reason a boost is explicit, single and expires.
#
# The cap on `shared` is never written below what `shared` already holds — lowering a
# `memory.max` under the current charge makes the kernel reclaim and then OOM-kill on the
# spot. It ratchets down towards its target as the other sessions free memory, so a boost
# granted on a busy box reserves its full size within minutes rather than by killing anyone.
# See SessionMemoryBoost for who decides the numbers.
#
# NOT A SANDBOX. An agent runs as the same uid that owns the delegated subtree, so it
# could move itself out. This is a guardrail against a runaway command, not a boundary
# against a hostile one — Zimmer has no such boundary anywhere and this does not
# pretend to add one.
class SessionMemoryCgroup
  # The delegated subtree root, created by bin/docker-entrypoint. Overridable so tests
  # can point at a tmpdir and so an operator can move it without a new image.
  DEFAULT_ROOT = "/sys/fs/cgroup/zimmer.sessions"

  # The pool cgroup inside it that holds every session cgroup, and carries the aggregate
  # `memory.max`. Session cgroups live HERE and not in the root, because the root also
  # holds `app` — see the header for why that distinction is the whole of #981.
  POOL_DIRNAME = "sessions"

  # The two tiers inside the pool — see "A one-off boost" in the header. Every session
  # cgroup lives in `shared` unless SessionMemoryBoost has carved it out into `boosted`.
  SHARED_DIRNAME = "shared"
  BOOSTED_DIRNAME = "boosted"

  # How far above what `shared` currently holds its cap may sit while it ratchets down to
  # the target a boost asks for. Writing the cap AT the current charge would OOM-kill the
  # next allocation anywhere in it; this leaves the other sessions room to keep working.
  SHARED_CAP_SLACK_BYTES = 256 * 1024 * 1024

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
  # is the right first cut, and `memory.peak` is recorded per session so the number can
  # be tightened on evidence rather than on guesswork.
  #
  # That reasoning survived tadasant/zimmer#981 unchanged, and the fix there is not to
  # lower this. Squeezing per-session bounds until N of them fit under the container cap
  # is the same trade rejected above — it kills sessions that work today, and it has to
  # pick an N that no scheduler guarantees. The aggregate is bounded aggregately, by the
  # pool's own `memory.max`.
  DEFAULT_LIMIT_BYTES = 4 * 1024 * 1024 * 1024

  # Where a session remembers what it has already been told about its own cgroup. The
  # count alone is not enough — see #incarnation for why the inode travels with it.
  OOM_KILL_COUNT_KEY = "memory_cgroup_oom_kills"
  # `memory.events`' `oom` counter, recorded alongside the kills for the same reason and
  # read for a different one: it is what separates "this session's own bound" from "the
  # pool's". See #kill_scope.
  OOM_EVENT_COUNT_KEY = "memory_cgroup_oom_events"
  # Which bound the last recorded kill came from — "session" or "pool", or absent when the
  # kernel counters could not answer.
  LAST_KILL_SCOPE_KEY = "memory_cgroup_oom_scope"
  INCARNATION_KEY = "memory_cgroup_incarnation"
  LAST_KILL_AT_KEY = "memory_cgroup_oom_killed_at"

  # The two values #kill_scope answers with. A kill it cannot attribute is nil, which is
  # not the same as either and is reported as such.
  SESSION_SCOPE = "session"
  POOL_SCOPE = "pool"

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

  # The reads of a cgroup's memory interface files. Shared by the per-session cgroup and
  # by the pool above it: both are ordinary cgroup v2 directories and only the path
  # differs, so the "max means no limit", "a missing file is nil, not zero" and "an
  # unreadable cgroup is nil" rules must not be written twice and drift.
  module MemoryFiles
    def read_integer_at(dir, file)
      value = File.read(File.join(dir, file)).strip
      return nil if value == "max"

      Integer(value, exception: false)
    rescue SystemCallError
      nil
    end

    # `memory.events` is a flat "key value" table; oom_kill counts tasks the kernel
    # killed in this cgroup and its descendants, and never decreases.
    def read_event_at(dir, key)
      File.foreach(File.join(dir, "memory.events")) do |line|
        name, value = line.split
        return Integer(value, exception: false) if name == key
      end
      nil
    rescue SystemCallError
      nil
    end

    def stats_at(dir)
      Stats.new(
        current_bytes: read_integer_at(dir, "memory.current"),
        peak_bytes: read_integer_at(dir, "memory.peak"),
        oom_kills: read_event_at(dir, "oom_kill"),
        limit_bytes: read_integer_at(dir, "memory.max")
      )
    end
  end

  extend MemoryFiles
  include MemoryFiles
  private_class_method :read_integer_at, :read_event_at, :stats_at
  private :read_integer_at, :read_event_at, :stats_at

  class << self
    # The delegated subtree's root. Resolved at call time, never memoized, so a test
    # that stubs the env and an operator who sets it at deploy time both take effect
    # without a process restart.
    #
    # The app never creates anything directly in here: this is the cgroup whose
    # `cgroup.procs` uid 1000 owns so that it can migrate a process from `app` into a
    # session cgroup, and it is the parent of both.
    def root_path
      ENV["ZIMMER_SESSION_CGROUP_ROOT"].presence || DEFAULT_ROOT
    end

    # Where session cgroups live: the pool, one level below the delegated root, whose
    # own `memory.max` bounds all of them together.
    def parent_path
      File.join(root_path, POOL_DIRNAME)
    end

    # The tier every session cgroup lives in unless it holds a boost.
    def shared_path
      File.join(parent_path, SHARED_DIRNAME)
    end

    # The tier a boosted session's cgroup is carved out into.
    def boosted_path
      File.join(parent_path, BOOSTED_DIRNAME)
    end

    # Create one tier and enable the memory controller for its children, so a session
    # cgroup inside it can carry a `memory.max`. Idempotent.
    #
    # uid 1000 can do this without root: it owns the pool directory (so it may create the
    # tier) and the tier it creates (so it may write the tier's `cgroup.subtree_control`),
    # and the pool's own `subtree_control`, which root wrote, already offers `memory`.
    #
    # @return [Boolean] false when the tier could not be made usable
    def ensure_tier!(path)
      FileUtils.mkdir_p(path)
      control = File.join(path, "cgroup.subtree_control")
      enabled = File.exist?(control) && File.read(control).split.include?("memory")
      File.write(control, "+memory") unless enabled
      true
    rescue SystemCallError => e
      Rails.logger.warn("[SessionMemoryCgroup] Could not prepare the #{File.basename(path)} tier: #{e.message}")
      false
    end

    # Bound everything in `shared` together, or lift that bound.
    #
    # `nil` writes `max`: no boost is held and the pool alone is the bound. A number is the
    # target, and is approached rather than imposed — see "A one-off boost" in the header:
    # the cap is never written below the current charge plus SHARED_CAP_SLACK_BYTES, and
    # once it is below that it is not loosened again while it still sits above the target,
    # so it can only ever move towards the target.
    #
    # @param target_bytes [Integer, nil]
    # @return [Integer, nil] the cap now in force on `shared` (nil for none), or nil when
    #   it could not be written
    def cap_shared!(target_bytes)
      path = shared_path
      if target_bytes.nil?
        File.write(File.join(path, "memory.max"), "max")
        return nil
      end

      desired = ratcheted_max(path, target_bytes)
      File.write(File.join(path, "memory.max"), desired.to_s) unless desired == read_integer_at(path, "memory.max")
      desired
    rescue SystemCallError => e
      Rails.logger.warn("[SessionMemoryCgroup] Could not cap the shared tier: #{e.message}")
      nil
    end

    # The `memory.max` to write on a cgroup that should be bounded at `target_bytes`
    # without killing anything to get there.
    #
    # Never below the current charge plus SHARED_CAP_SLACK_BYTES: lowering a `memory.max`
    # under the charge makes the kernel OOM-kill on the spot. And never LOOSENED while the
    # value in force is already at or above the target — otherwise a cgroup sitting just
    # under its bound would have the bound pushed up by the slack on every call, and creep
    # past it a step a minute. So the result only ever moves towards the target.
    #
    # @return [Integer]
    def ratcheted_max(path, target_bytes)
      existing = read_integer_at(path, "memory.max")
      current = read_integer_at(path, "memory.current").to_i
      desired = [ target_bytes, current + SHARED_CAP_SLACK_BYTES ].max
      return existing if existing && desired > existing && existing >= target_bytes

      desired
    end

    # Session ids whose cgroup is carved out into `boosted` right now.
    #
    # @return [Array<Integer>]
    def boosted_session_ids
      return [] unless File.directory?(boosted_path)

      Dir.children(boosted_path).filter_map do |name|
        Integer(name.delete_prefix("session-"), exception: false) if name.start_with?("session-")
      end
    rescue SystemCallError
      []
    end

    # Usage, high-water mark and the aggregate bound for the pool as a whole.
    #
    # `limit_bytes` is read from the pool's `memory.max` rather than from an environment
    # variable, because the entrypoint is what writes it and it may have failed to: a
    # container that could not write the cap runs with the pool present and unbounded,
    # and the readers have to be able to tell that from a cap that is simply large.
    #
    # `oom_kills` counts kills anywhere in the subtree, so it moves for a kill in any
    # session's cgroup as well as for one the pool's own cap caused. It is a pressure
    # reading, not an attribution — attribution is #kill_scope's job.
    #
    # @return [Stats]
    def pool_stats
      stats_at(parent_path)
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
    #
    # A configured limit of zero is false here too, and that is the point of it: the
    # break-glass has to take the whole mechanism out of the path, not just widen the
    # bound. Writing `max` into `memory.max` would leave every spawn still wrapped in
    # `sh` and every process still migrated — no use at all to an operator whose
    # incident IS the wrapper.
    def available?
      return false if limit_bytes.zero?

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

    # Remove the session cgroups that are finished with.
    #
    # An empty cgroup costs a directory and a few kernel structs, but they arrive one
    # per session and nothing else would ever remove them: `rmdir` refuses while any pid
    # is still inside, so a session cannot always tear its own down, and a worker killed
    # mid-deploy never gets the chance.
    #
    # Emptiness is NOT sufficient on its own, which is the trap here. A session sits
    # between turns — `needs_input` for hours is the normal case — with a cgroup that
    # holds no processes and is not remotely garbage. Sweeping it would reset
    # `memory.peak` and the OOM counter that the next turn's reporting reads, so a
    # session that OOMs once, idles, and OOMs again would have the second kill silently
    # swallowed. So a cgroup is removed only when it is empty AND its session is
    # archived or gone from the database entirely.
    #
    # The counter can still restart underneath a live session — a deploy recreates the
    # container and takes every cgroup in it — so the readers do not depend on this
    # holding. See #accounted_oom_kills, which keys the baseline to the cgroup's
    # incarnation rather than trusting it to persist.
    #
    # @return [Integer] how many were removed
    def sweep!
      return 0 unless available?

      # Both halves are the filter: a `session-` prefix and a parseable id keep the sweep
      # off anything this class did not create, which is not this class's to remove. The
      # pool holds only its two tiers and session cgroups — `app` is its sibling, not its
      # child — but the filter is what makes that a fact about the sweep rather than about
      # the current layout.
      #
      # Three places to look: the two tiers, and the pool itself, where #prepare! falls back
      # to when the tiers cannot be made (see there). The tier directories are not
      # `session-` names, so the filter keeps the sweep off them too.
      candidates = [ shared_path, boosted_path, parent_path ].select { |dir| File.directory?(dir) }.flat_map do |dir|
        Dir.children(dir).filter_map do |name|
          next unless name.start_with?("session-")

          id = Integer(name.delete_prefix("session-"), exception: false)
          [ File.join(dir, name), id ] if id
        end
      end
      return 0 if candidates.empty?

      live = Session.where(id: candidates.map(&:last)).where.not(status: :archived).pluck(:id).to_set

      candidates.count do |path, id|
        next false if live.include?(id)

        remove_if_empty(path)
      end
    rescue SystemCallError, ActiveRecord::ActiveRecordError => e
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

  # Where this session's cgroup is: carved out into `boosted`, in `shared`, or — only when
  # the tiers could not be made — directly in the pool. A cgroup that does not exist yet is
  # reported at the `shared` path, which is where #prepare! will put it.
  def path
    [ boosted_path, shared_member_path, legacy_path ].find { |candidate| File.directory?(candidate) } ||
      shared_member_path
  end

  def boosted_path
    File.join(self.class.boosted_path, name)
  end

  def shared_member_path
    File.join(self.class.shared_path, name)
  end

  def procs_path
    File.join(path, "cgroup.procs")
  end

  def carved_out?
    File.directory?(boosted_path)
  end

  # Create the cgroup and write its limit.
  #
  # Idempotent, and deliberately so: a session respawns constantly — a follow-up turn, a
  # continuation, a signal-death resume — and each one reuses the cgroup it already has,
  # so `memory.peak` and the OOM counter accumulate over as much of the session's life as
  # the cgroup itself survives.
  #
  # That last clause is the honest one. The cgroup does not outlive the container: a
  # deploy recreates the worker and takes the whole subtree with it, and the sweep
  # removes it once the session is archived. So the counters can restart underneath a
  # session that is still going, which is why the readers key their baseline to
  # #incarnation instead of assuming the count only ever grows.
  #
  # A cgroup carved out into `boosted` is left exactly as it is: its `memory.max` is the
  # boost, and SessionMemoryBoost is the only thing that writes it.
  #
  # The fallback to the pool itself is what keeps a session under the pool's cap when the
  # `shared` tier cannot be made. Left outside every session cgroup it would run in `app`,
  # beside the Rails worker and under no aggregate bound at all — the #981 failure — so the
  # old flat layout is a far better answer than none. A boost needs the tiers, so none is
  # granted in that state (SessionMemoryBoost.reconcile!).
  #
  # @return [Boolean] true if the cgroup is ready to be entered
  def prepare!
    return true if carved_out?

    target = if File.directory?(legacy_path) || !self.class.ensure_tier!(self.class.shared_path)
      legacy_path
    else
      shared_member_path
    end
    FileUtils.mkdir_p(target)

    File.write(File.join(target, "memory.max"), self.class.limit_bytes.to_s)

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

  # Carve this session out into `boosted` with a `memory.max` of `limit_bytes`, moving
  # every process it already has across. Idempotent; SessionMemoryBoost calls it every
  # minute while the boost is held.
  #
  # Processes move, their memory does not: cgroup v2 leaves pages charged where they were
  # allocated, so what the session already holds stays on `shared`'s account until it is
  # freed. That is in the boost's favour — the new cgroup starts empty — and it is why the
  # move is safe to make in the middle of a build.
  #
  # Lowering a carved cgroup's `memory.max` below what it holds would OOM-kill inside it on
  # the spot, so a smaller value is approached the way `shared`'s cap is (.ratcheted_max):
  # never below the current charge plus slack, and never loosened past the boost on the way.
  #
  # @param limit_bytes [Integer]
  # @return [Boolean] true when the cgroup is carved out with that bound
  def carve_out!(limit_bytes)
    FileUtils.mkdir_p(boosted_path)
    File.write(File.join(boosted_path, "memory.max"), self.class.ratcheted_max(boosted_path, limit_bytes).to_s)
    [ shared_member_path, legacy_path ].each { |from| migrate_processes(from, boosted_path) }
    true
  rescue SystemCallError => e
    Rails.logger.warn("[SessionMemoryCgroup] Could not carve out #{boosted_path}: #{e.message}")
    false
  end

  # The boost is over: move this session back into `shared` under the ordinary per-session
  # bound, and remove the carved cgroup once nothing is left in it.
  #
  # The session is not left where it was with a smaller limit, because outside `shared` it
  # would escape the cap the NEXT boost puts on everyone else.
  #
  # @return [Boolean] true when no process of this session is left in `boosted`
  def return_to_shared!
    return true unless carved_out?
    return false unless self.class.ensure_tier!(self.class.shared_path)

    FileUtils.mkdir_p(shared_member_path)
    File.write(File.join(shared_member_path, "memory.max"), self.class.limit_bytes.to_s)
    migrate_processes(boosted_path, shared_member_path)
    self.class.remove_if_empty(boosted_path) || !carved_out?
  rescue SystemCallError => e
    Rails.logger.warn("[SessionMemoryCgroup] Could not return #{name} to the shared tier: #{e.message}")
    false
  end

  # The nearest bound above this session that it shares with other sessions: the
  # `shared` tier's cap while a boost is held elsewhere and that cap is the tighter one,
  # otherwise the pool's.
  #
  # This is what a kill the session's own bound did not cause ran into, and so what the
  # messages about such a kill have to quote — "the 6 GiB all sessions share" is wrong
  # by the size of the boost while one is held.
  #
  # @return [Stats]
  def enclosing_stats
    pool = self.class.pool_stats
    return pool unless File.dirname(path) == self.class.shared_path

    shared = stats_at(self.class.shared_path)
    return pool if shared.limit_bytes.nil?
    return pool if pool.limit_bytes && pool.limit_bytes <= shared.limit_bytes

    shared
  end

  # Wrap a command so that it runs inside this cgroup.
  #
  # The child writes its own pid to `cgroup.procs` and `exec`s the real command, which
  # preserves the pid — so `pgroup: true`, the recorded `process_pid`, the SIGTERM
  # escalation path and the transcript pollers all see exactly what they saw before.
  #
  # `$1` rather than an interpolated path so a path with a space or a quote in it cannot
  # become shell syntax. A failure to enter warns on the runtime's stderr log, alongside
  # the shell's own error, and runs the command anyway: unbounded is the behaviour every
  # deployment had before this existed, and refusing to start the session would be a far
  # worse trade than running it without a bound.
  #
  # That log is only surfaced into the session log when a turn FAILS, so it is not on its
  # own a reliable way to hear about an unbounded session. SessionMemoryWatch is —
  # it notices a cgroup that never took a process and says so from the monitor loop.
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
    stats_at(path)
  end

  # @return [Integer, nil] processes the kernel has OOM-killed in this cgroup, or nil
  #   if the counter could not be read
  def oom_kill_count
    read_event("oom_kill")
  end

  # How many times THIS cgroup's own `memory.max` was reached and an allocation was about
  # to fail.
  #
  # The distinction from `oom_kill` is the whole of the attribution problem. `oom_kill`
  # counts processes killed in this cgroup by any OOM killer, including one declared by an
  # ancestor — so it moves whether the session ran out or the pool did. `oom` counts the
  # cgroup whose own limit was exceeded, and cgroup v2 propagates events upward only, so
  # a pool-declared OOM never touches this counter. `oom` moved means the session's own
  # bound; `oom_kill` moved and `oom` did not means an ancestor's, which here is the pool.
  #
  # @return [Integer, nil]
  def oom_event_count
    read_event("oom")
  end

  # An identifier for THIS instance of the cgroup directory, which changes when the
  # directory is recreated.
  #
  # It is the only thing that distinguishes "the counter has not moved" from "the counter
  # is a different counter now", and both readers need that distinction: `memory.events`
  # restarts at zero whenever the cgroup is recreated — by a deploy, by the sweep after an
  # archive — while the count they recorded lives in Postgres and survives.
  #
  # Without it, a session that OOM-killed a subprocess (recorded: 1), idled long enough to
  # be swept, and then OOM-killed another in a fresh cgroup (counter: 1) would compare
  # 1 to 1 and report nothing at all. That is the repeat-runaway case —
  # tadasant/zimmer#719's four kills an hour — which is precisely the one worth hearing
  # about.
  #
  # The inode ALONE is not enough, which is worth stating because it is the obvious
  # choice and it is wrong: a filesystem is free to hand the same inode straight back, and
  # ext4 does exactly that — measured, a remove-then-recreate of the same directory
  # returns the identical inode number every time. The creation time is what separates
  # them, and the inode is what separates two directories created in the same nanosecond.
  # Neither is load-bearing on its own; the pair is.
  #
  # @return [String, nil]
  def incarnation
    stat = File.stat(path)
    "#{stat.ino}:#{stat.ctime.to_i}.#{stat.ctime.nsec}"
  rescue SystemCallError
    nil
  end

  # How many OOM kills in this cgroup the session has already been told about.
  #
  # Zero whenever the recorded baseline belongs to a different incarnation, because then
  # every kill the current counter holds is news.
  #
  # @param session [Session]
  # @return [Integer]
  def accounted_oom_kills(session)
    metadata = session.metadata || {}
    return 0 unless metadata[INCARNATION_KEY] == incarnation

    metadata[OOM_KILL_COUNT_KEY].to_i
  end

  # Kills the session has not been told about yet.
  #
  # @param session [Session]
  # @return [Integer, nil] nil when the counter could not be read at all
  def unaccounted_oom_kills(session)
    observed = oom_kill_count
    return nil if observed.nil?

    [ observed - accounted_oom_kills(session), 0 ].max
  end

  # Which bound a kill that has just been observed came from.
  #
  # Compared against the recorded baseline the same way the kill count is, and keyed to
  # the same incarnation, so a counter that restarted under a live session does not read
  # as "did not move".
  #
  # Deliberately NOT a comparison of usage against limits. `memory.peak` is a lifetime
  # high-water mark on a cgroup that is reused across every turn of the session and never
  # reset, so a session that touched its bound once on turn 1 would be blamed for its own
  # bound forever after; and `memory.current` is read up to ten seconds after the kill,
  # by which point the victim's memory has been freed and the pool reads low. The kernel's
  # own counters have neither problem.
  #
  # @param session [Session]
  # @param observed_events [Integer, nil] this cgroup's `oom` counter, as just read
  # @return [String, nil] SESSION_SCOPE, POOL_SCOPE, or nil when it cannot be answered
  def kill_scope(session, observed_events)
    return nil if observed_events.nil?

    metadata = session.metadata || {}
    accounted = metadata[INCARNATION_KEY] == incarnation ? metadata[OOM_EVENT_COUNT_KEY].to_i : 0
    observed_events > accounted ? SESSION_SCOPE : POOL_SCOPE
  end

  # The scope recorded for the most recent kill, when it belongs to this incarnation.
  #
  # ProcessLifecycleManager needs this for the race #recently_oom_killed? covers: the
  # watch has already consumed the delta and moved the baseline, so re-deriving the scope
  # would read "pool" for every kill. The answer is recorded at the moment it could still
  # be computed.
  #
  # @param session [Session]
  # @return [String, nil]
  def last_kill_scope(session)
    metadata = session.metadata || {}
    return nil unless metadata[INCARNATION_KEY] == incarnation

    metadata[LAST_KILL_SCOPE_KEY].presence
  end

  # Record what we have reported, against the incarnation it was counted in.
  #
  # The scope is computed here rather than by the caller because it has to be computed
  # BEFORE the baseline moves, and this is the method that moves it.
  #
  # @param session [Session]
  # @param observed [Integer]
  # @return [String, nil] the scope of the kill just recorded, for the caller's message
  def record_oom_kills!(session, observed)
    observed_events = oom_event_count
    scope = kill_scope(session, observed_events)

    session.merge_metadata!(
      OOM_KILL_COUNT_KEY => observed,
      OOM_EVENT_COUNT_KEY => observed_events,
      LAST_KILL_SCOPE_KEY => scope,
      INCARNATION_KEY => incarnation,
      LAST_KILL_AT_KEY => Time.current.iso8601
    )
    scope
  end

  # Did the kernel kill something in here recently enough that a process dying now is
  # plausibly the same event?
  #
  # ProcessLifecycleManager needs this because the two readers race: SessionMemoryWatch
  # polls every 10s, so a tick landing between the kernel's kill of the agent and the
  # monitor loop noticing the exit consumes the delta, and the exit path would then find
  # nothing unaccounted and fall back to "likely OOM or external kill" for a death that
  # WAS the bound. The window is wider than the race needs on purpose — misattributing a
  # signal death to memory costs a log line and a recovery prompt that is decent advice
  # either way, while missing one costs the explanation entirely.
  #
  # @param session [Session]
  # @param within [ActiveSupport::Duration]
  # @return [Boolean]
  def recently_oom_killed?(session, within:)
    metadata = session.metadata || {}
    return false unless metadata[INCARNATION_KEY] == incarnation

    at = metadata[LAST_KILL_AT_KEY]
    at.present? && Time.zone.parse(at.to_s) > within.ago
  rescue ArgumentError, TypeError
    false
  end

  def exists?
    File.directory?(path)
  end

  private

  def read_event(key) = read_event_at(path, key)

  # The flat layout every session cgroup had before the tiers, and the fallback #prepare!
  # takes when they cannot be made.
  def legacy_path
    File.join(self.class.parent_path, name)
  end

  # Move every process in one cgroup into another. Writing a pid to the target's
  # `cgroup.procs` is the migration; uid 1000 may make it because it owns the
  # `cgroup.procs` of the pool, the common ancestor of every location here. A pid that
  # exited between the read and the write is simply gone.
  def migrate_processes(from, to)
    return unless File.directory?(from)

    File.read(File.join(from, "cgroup.procs")).split.each do |pid|
      File.write(File.join(to, "cgroup.procs"), pid)
    rescue Errno::ESRCH
      next
    end
    self.class.remove_if_empty(from)
  rescue Errno::ENOENT
    nil
  end
end

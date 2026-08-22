# frozen_string_literal: true

# Answers one question about a session's agent process: is the process we last
# spawned for it still running *here*, where "here" is provable rather than assumed?
#
# WHY THIS EXISTS
# ---------------
# `JobLiveness` answers the same shape of question about a GoodJob row, and the
# supersede decision in `AgentSessionJob#perform` is built on it. But a job and the
# agent process it spawned do not die together. The CLI is a child of the worker
# process; if that process is killed (a GoodJob shutdown timeout killing the job
# thread, an OOM, a SIGKILL) the `ensure` block that terminates the child never runs,
# and the child is reparented and keeps running. GoodJob's bookkeeping reports the job
# as `:dead_worker` or `:interrupted`, the next job for that session supersedes it —
# correctly; nothing is executing that row — takes the fresh-start path, clones again,
# and spawns a second agent against the same branch, the same `$AO_SESSION_SCRATCH_DIR`
# and the same conversation. That is zimmer#395.
#
# Superseding less eagerly is not the fix. The two sides of that decision are asymmetric
# and both silent — skip a dead-looking corpse and the user's follow-up prompt is lost —
# and `JobLiveness`'s comments explain at length why the evidence it uses is the best
# evidence available *about a job*. So this class does not touch that decision. It closes
# the gap underneath it: before a spawn, prove the previous process is gone, and if it is
# not, end it. The new turn always proceeds, so no prompt is ever dropped.
#
# WHY `Process.kill(0, pid)` IS NOT ENOUGH — AND HOW THAT IS FIXED
# ---------------------------------------------------------------
# `JobLiveness` rejects a PID check, for two reasons that are both real:
#
#   * Zimmer runs Kamal roles as separate containers, each with its own PID namespace,
#     and can spread roles across hosts. A pid recorded by one is meaningless to
#     another: signal 0 answers about the *caller's* namespace, so it reports ESRCH for
#     a perfectly healthy process elsewhere.
#   * PIDs are recycled, so signal 0 reports "alive" for an unrelated process that
#     happened to inherit the number.
#
# Neither objection is to the check itself — both are to asking it about a pid whose
# provenance was never recorded. So we record the provenance. At spawn time
# {.identity_for} captures, alongside the pid:
#
#   * the kernel's **boot id** (`/proc/sys/kernel/random/boot_id`), a random UUID
#     regenerated on every boot of every machine;
#   * the **PID namespace** the spawner was in (`/proc/self/ns/pid`); and
#   * the process's **start time** (field 22 of `/proc/<pid>/stat`, in clock ticks since
#     boot), which distinguishes the process we spawned from any later process that
#     inherits its number.
#
# The boot id is what makes the namespace meaningful, and it is not optional. An nsfs
# inode number is unique only within one running kernel: `pid:[4026531836]` is the
# *initial* namespace on every Linux host, and the numbers restart after a reboot — when
# the start-time ticks have restarted from zero too. Namespace alone would therefore
# compare equal across two hosts running the same role, and across a reboot. Together the
# three mean "this kernel, this boot, this namespace, this process".
#
# With that the check is sound in both directions. A boot or namespace mismatch is
# reported as `:unknown` — we say we cannot tell, rather than guessing "dead" — and a
# start-time mismatch is `:recycled`, which is never signalled. We act only on `:alive`:
# same kernel, same namespace, present, and demonstrably the process we started.
#
# ZOMBIES. `Process.kill(0, pid)` succeeds for an exited child that nobody has reaped
# yet, which is why `ProcessTerminationService` reaps rather than signals to answer
# liveness. Reading `/proc/<pid>/stat` gives us the state character for free, so a
# zombie is classified `:dead` here without a signal being sent.
#
# WHERE `/proc` DOES NOT EXIST (macOS development) every probe returns nil, the status
# is `:unknown`, and the guard is inert — the same answer it gives for a pid from a
# machine or container that is gone. `docs/limitations.md` records both.
class AgentProcessLiveness
  # Session metadata key holding the identity of the most recently spawned agent process.
  # Written in the same statement as `process_pid` (see `Session#record_agent_process!`)
  # so the two can never drift apart.
  IDENTITY_KEY = "process_identity"

  # `/proc/<pid>/stat` field 3 (the state character) for an exited-but-unreaped process.
  ZOMBIE_STATE = "Z"

  # Index of field 22 (`starttime`) once `/proc/<pid>/stat` is split past the comm field.
  START_TIME_INDEX = 19

  # Statuses that permit a spawn without any intervention: there is provably nothing
  # left running, or nothing we are entitled to act on.
  INERT_STATUSES = %i[none unknown dead recycled].freeze

  class << self
    # Capture everything needed to re-identify `pid` later, from this machine.
    #
    # Any nil field is recorded as-is: {.classify} reads an incomplete identity as
    # `:unknown` and stands down, which is the safe direction.
    #
    # @param pid [Integer, nil]
    # @return [Hash, nil]
    def identity_for(pid)
      return nil if pid.blank?

      {
        "pid" => pid.to_i,
        "boot_id" => boot_id,
        "pid_namespace" => pid_namespace,
        "started_at_ticks" => process_snapshot(pid)&.fetch(:started_at_ticks, nil)
      }
    end

    # Classify the agent process recorded on `session`.
    #
    # @param session [Session]
    # @return [Symbol] see {.classify}
    def status(session)
      classify(recorded_identity(session))
    end

    # The recorded identity, read from the database rather than from the in-memory record.
    #
    # The session object on the spawn path is loaded when the job starts and then sits
    # through a clone, an MCP config write and a boot-task run. The write this check
    # exists to see is, by definition, made by a *different* process — so the attribute in
    # memory is exactly the copy that cannot have it. Reading it fresh is one indexed
    # SELECT per spawn, against a check whose whole value is not missing that write.
    #
    # @return [Hash, nil]
    def recorded_identity(session)
      return nil unless session

      persisted = Session.where(id: session.id).pick(:metadata) if session.persisted?
      (persisted || session.metadata || {})[IDENTITY_KEY]
    rescue StandardError
      session.metadata&.dig(IDENTITY_KEY)
    end

    # @param identity [Hash, nil] a `process_identity` blob
    # @return [Symbol] one of:
    #   :none     — no process has been recorded; there is nothing to check
    #   :unknown  — recorded on another boot or in another PID namespace, or `/proc` is
    #               unavailable. The pid means nothing here and is never signalled.
    #   :dead     — same kernel and namespace, and the process is gone (or is an unreaped
    #               zombie, which signal 0 would call alive)
    #   :recycled — same kernel and namespace, the number is in use, but by a different
    #               process than the one we spawned. Never signalled.
    #   :alive    — same kernel and namespace, present, and provably the process we spawned
    def classify(identity)
      return :none if identity.blank?

      pid = identity["pid"]
      recorded_boot = identity["boot_id"]
      recorded_namespace = identity["pid_namespace"]
      recorded_ticks = identity["started_at_ticks"]
      return :unknown if pid.blank? || recorded_boot.blank? || recorded_namespace.blank? || recorded_ticks.blank?
      return :unknown if boot_id.blank? || boot_id != recorded_boot
      return :unknown if pid_namespace.blank? || pid_namespace != recorded_namespace

      # One read answers both remaining questions, so the process cannot exit between
      # them and be reported as a live one whose start time merely fails to match.
      snapshot = process_snapshot(pid)
      return :dead if snapshot.nil? || snapshot[:state] == ZOMBIE_STATE || snapshot[:started_at_ticks].blank?

      snapshot[:started_at_ticks].to_s == recorded_ticks.to_s ? :alive : :recycled
    end

    # Guarantee that no agent process from a previous turn is still running before the
    # caller spawns a new one.
    #
    # Only `:alive` acts, and it terminates rather than refusing: the new turn carries a
    # prompt, and refusing to spawn would drop it silently — the failure this guard must
    # not trade one bug for. Termination is best-effort and bounded (SIGTERM, then
    # SIGKILL, then a process-group sweep, ~5s worst case); the caller spawns either way.
    #
    # Deliberately not alerted. Two things reach this branch and they are not
    # distinguishable here: a genuinely orphaned process, and a previous turn that is
    # simply a second or two from exiting on its own when a fast worker picks up the next
    # one. Paging on it would be a false alarm most of the time. Terminating is right in
    # both cases — by the time this runs the previous turn is over — so the record is a
    # session log line and a structured warning, which is where a session being debugged
    # is read from anyway.
    #
    # @param session [Session]
    # @param process_manager [ProcessManager, nil]
    # @param log_buffer [LogBuffer, nil]
    # @return [Symbol] the status that was acted on, for the caller to log or assert
    def ensure_no_live_process!(session, process_manager: nil, log_buffer: nil)
      identity = recorded_identity(session)
      state = classify(identity)
      return state if INERT_STATUSES.include?(state)

      pid = identity["pid"]
      add_log(
        log_buffer, session,
        "Previous turn's agent process (PID #{pid}) is still running — terminating it before " \
        "spawning, so this session never runs two agents at once",
        level: "warning"
      )
      logger(session).warn("Terminating orphaned agent process before spawn", process_pid: pid)

      result = ProcessTerminationService.new(
        process_pid: pid,
        process_manager: process_manager,
        log_buffer: log_buffer,
        session: session
      ).terminate

      unless result.success?
        add_log(
          log_buffer, session,
          "Could not terminate orphaned agent process #{pid}: #{result.message}. Spawning anyway — " \
          "the new turn must not be dropped, but this session may briefly run two agents.",
          level: "error"
        )
      end

      state
    rescue StandardError => e
      # This guard runs on the spawn path. A bug in it must never be the reason a
      # session fails to start — that would trade a rare double-run for a common
      # dead session.
      Rails.logger.error(
        "[AgentProcessLiveness] Orphan check failed for session #{session&.id}: #{e.class}: #{e.message}"
      )
      :error
    end

    # May the recovery path ADOPT `pid` as this session's agent process?
    #
    # {.ensure_no_live_process!} asks the opposite question — "is anything still alive
    # that I must kill" — and treats every uncertain status as inert, because the cost of
    # guessing wrong there is a terminated process. Adoption's costs run the other way. A
    # job that reconnects to a pid which is not ours reports a recovery that did not
    # happen, and the monitoring loop then reads the foreign process's death (or its own
    # first liveness poll) as this session's turn completing — which is how a session
    # whose turn was never delivered lands on the human's action queue looking finished.
    #
    # So `:dead` and `:recycled` are refusals; that is the whole point. `:alive` is the
    # only affirmative answer. Everything else means the identity cannot decide and the
    # caller's own liveness check stands, which is the behaviour that predates this guard:
    #
    #   * `:none` / a blank identity — nothing was recorded to compare against.
    #   * an identity recorded for a DIFFERENT pid than the one being adopted — the two
    #     have drifted, so the identity says nothing about this pid.
    #   * `:unknown` — another boot, another PID namespace, or no `/proc` at all (macOS
    #     development), where every probe returns nil and this guard is inert exactly as the
    #     spawn-side one is.
    #
    # @param session [Session, nil]
    # @param pid [Integer, nil] the pid the caller is about to start monitoring
    # @return [Boolean] false only when the recorded identity PROVES this is not our process
    def adoptable?(session, pid)
      return true if pid.blank?

      identity = recorded_identity(session)
      return true if identity.blank?
      return true unless identity["pid"].to_i == pid.to_i

      !%i[dead recycled].include?(classify(identity))
    rescue StandardError => e
      # Same posture as the spawn guard: a bug in the check must not be the reason a
      # recovery cannot reconnect to a process that is genuinely still running.
      Rails.logger.error(
        "[AgentProcessLiveness] Adoption check failed for session #{session&.id}: #{e.class}: #{e.message}"
      )
      true
    end

    # The kernel's boot id: a random UUID regenerated on every boot of every machine.
    # @return [String, nil] nil where `/proc` is unavailable
    def boot_id
      File.read("/proc/sys/kernel/random/boot_id").strip.presence
    rescue SystemCallError, IOError
      nil
    end

    # The PID namespace this process is in, as an opaque comparable id.
    # @return [String, nil] e.g. "pid:[4026531836]", or nil where `/proc` is unavailable
    def pid_namespace
      File.readlink("/proc/self/ns/pid")
    rescue SystemCallError, NotImplementedError
      nil
    end

    # The two facts about a running process that identify it, from a single read.
    #
    # @param pid [Integer, nil]
    # @return [Hash, nil] `{ state: "S", started_at_ticks: "260018677" }`, or nil when the
    #   process does not exist or `/proc` is unavailable
    def process_snapshot(pid)
      fields = stat_fields(pid)
      return nil if fields.nil?

      { state: fields.first, started_at_ticks: fields.at(START_TIME_INDEX) }
    end

    private

    # Fields of `/proc/<pid>/stat` from the state character onward — i.e. field 3
    # onward, so index i here is field i + 3.
    #
    # @return [Array<String>, nil]
    def stat_fields(pid)
      return nil if pid.blank?

      raw = File.read("/proc/#{pid.to_i}/stat")
      # Split after the LAST ")": the comm field is parenthesised and may itself contain
      # spaces and parentheses. A line with no ")" is not a stat line, and guessing an
      # offset into it would yield a confidently wrong start time.
      close = raw.rindex(")")
      return nil if close.nil?

      raw[(close + 1)..].to_s.split.presence
    rescue SystemCallError, IOError
      nil
    end

    def logger(session)
      StructuredLogger.new({ session_id: session&.id, service: "AgentProcessLiveness" })
    end

    def add_log(log_buffer, session, content, level:)
      if log_buffer
        log_buffer.add(content, level: level)
      elsif session
        session.logs.create!(content: content, level: level)
      else
        Rails.logger.warn("[AgentProcessLiveness] #{content}")
      end
    rescue StandardError => e
      Rails.logger.warn("[AgentProcessLiveness] Could not write session log: #{e.message}")
    end
  end
end

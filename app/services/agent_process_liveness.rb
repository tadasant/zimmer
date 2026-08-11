# frozen_string_literal: true

# Answers one question about a session's agent process: is the process we last
# spawned for it still running *here*, where "here" is provable rather than assumed?
#
# WHY THIS EXISTS
# ---------------
# `JobLiveness` answers the same shape of question about a GoodJob row, and the
# supersede decision in `AgentSessionJob#perform` is built on it. But a job and the
# agent process it spawned do not die together. The CLI is a child of the worker
# process; if that process is killed (GoodJob shutdown timeout kills the job thread,
# an OOM, a SIGKILL) the `ensure` block that terminates the child never runs, and the
# child is reparented and keeps running. GoodJob's bookkeeping then reports the job as
# `:dead_worker` or `:interrupted`, the next job for that session supersedes it — which
# is correct, nothing is executing that row — takes the fresh-start path, clones again,
# and spawns a second agent against the same branch, the same `$AO_SESSION_SCRATCH_DIR`
# and the same conversation. That is zimmer#395: two live agents for one session, for
# sixteen minutes, silently.
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
#   * Zimmer runs Kamal roles as separate containers, each with its own PID namespace.
#     A pid recorded by one is meaningless to another: signal 0 answers about the
#     *caller's* namespace, so it reports ESRCH for a perfectly healthy process
#     elsewhere.
#   * PIDs are recycled, so signal 0 reports "alive" for an unrelated process that
#     happened to inherit the number.
#
# Neither objection is to the check itself — both are to asking it about a pid whose
# provenance was never recorded. So we record the provenance. At spawn time
# {.identity_for} captures, alongside the pid:
#
#   * the PID namespace the spawner was in (`/proc/self/ns/pid`, an inode id that is
#     unique per namespace on the host and differs between two containers and between
#     a container and its replacement), and
#   * the process's start time (field 22 of `/proc/<pid>/stat`, in clock ticks since
#     boot), which distinguishes the process we spawned from any later process that
#     inherits its number.
#
# With those two facts the check becomes sound in both directions. A namespace mismatch
# is reported as `:unknown` — we say we cannot tell, instead of guessing "dead" — and a
# start-time mismatch is reported as `:recycled`, which is never signalled. We act only
# on `:alive`, which means: same namespace, process present, and demonstrably the same
# process we started.
#
# ZOMBIES. `Process.kill(0, pid)` succeeds for an exited child that nobody has reaped
# yet, which is why `ProcessTerminationService` reaps rather than signals to answer
# liveness. Reading `/proc/<pid>/stat` gives us the state character for free, so a
# zombie is classified `:dead` here without a signal being sent.
#
# WHERE `/proc` DOES NOT EXIST (macOS development) every probe returns nil, the status
# is `:unknown`, and the guard is inert — the same answer it gives for a pid from a
# container that is gone. `docs/limitations.md` records both.
class AgentProcessLiveness
  # Session metadata key holding the identity of the most recently spawned agent process.
  # Written in the same statement as `process_pid` (see `Session#record_agent_process!`)
  # so the two can never drift apart.
  IDENTITY_KEY = "process_identity"

  # Statuses that permit a spawn without any intervention: there is provably nothing
  # left running, or nothing we are entitled to act on.
  INERT_STATUSES = %i[none unknown dead recycled].freeze

  class << self
    # Capture everything needed to re-identify `pid` later, from this namespace.
    #
    # A nil return (no `/proc`, or the process exited between spawn and this call)
    # is recorded as-is: {.status} reads a missing or incomplete identity as
    # `:unknown` and stands down, which is the safe direction.
    #
    # @param pid [Integer, nil]
    # @return [Hash, nil]
    def identity_for(pid)
      return nil if pid.blank?

      {
        "pid" => pid.to_i,
        "pid_namespace" => pid_namespace,
        "started_at_ticks" => process_start_ticks(pid)
      }
    end

    # Classify the agent process recorded on `session`.
    #
    # @param session [Session]
    # @return [Symbol] one of:
    #   :none     — no process has been recorded; there is nothing to check
    #   :unknown  — recorded in a different PID namespace, or `/proc` is unavailable.
    #               The pid means nothing here and must never be signalled from here.
    #   :dead     — same namespace, and the process is gone (or is an unreaped zombie)
    #   :recycled — same namespace, the number is in use, but by a different process
    #               than the one we spawned. Never signalled.
    #   :alive    — same namespace, present, and provably the process we spawned
    def status(session)
      classify(recorded_identity(session))
    end

    # The recorded identity, read from the database rather than from the in-memory record.
    #
    # The session object on the spawn path was loaded when the job started and has since
    # sat through a clone, an MCP config write and a boot-task run. The write this check
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
    # @return [Symbol] see {.status}
    def classify(identity)
      return :none if identity.blank?

      pid = identity["pid"]
      recorded_namespace = identity["pid_namespace"]
      recorded_ticks = identity["started_at_ticks"]
      return :unknown if pid.blank? || recorded_namespace.blank? || recorded_ticks.blank?

      current_namespace = pid_namespace
      return :unknown if current_namespace.blank? || current_namespace != recorded_namespace

      return :dead if zombie?(pid)

      current_ticks = process_start_ticks(pid)
      return :dead if current_ticks.blank?

      current_ticks.to_s == recorded_ticks.to_s ? :alive : :recycled
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
      message = "Previous turn's agent process (PID #{pid}) is still running — terminating it before " \
                "spawning, so this session never runs two agents at once"
      add_log(log_buffer, session, message, level: "warning")
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

    # The PID namespace this process is in, as an opaque comparable id.
    # @return [String, nil] e.g. "pid:[4026531836]", or nil where `/proc` is unavailable
    def pid_namespace
      File.readlink("/proc/self/ns/pid")
    rescue SystemCallError, NotImplementedError
      nil
    end

    # Start time of `pid` in clock ticks since boot (field 22 of `/proc/<pid>/stat`).
    # Constant for the life of a process and different for any process that later
    # inherits the same number, which is what makes it a recycling check.
    #
    # @param pid [Integer, nil]
    # @return [String, nil] nil when the process does not exist or `/proc` is unavailable
    def process_start_ticks(pid)
      stat_fields(pid)&.at(19)
    end

    # Is `pid` an exited-but-unreaped child? `Process.kill(0, pid)` says "alive" for
    # these; `/proc` says "Z".
    # @return [Boolean]
    def zombie?(pid)
      stat_fields(pid)&.first == "Z"
    end

    private

    # Fields of `/proc/<pid>/stat` from the state character onward — i.e. field 3
    # onward, so index i here is field i + 3. Split after the last ")" because the
    # comm field is parenthesised and may itself contain spaces and parentheses.
    #
    # @return [Array<String>, nil]
    def stat_fields(pid)
      return nil if pid.blank?

      raw = File.read("/proc/#{pid.to_i}/stat")
      tail = raw[(raw.rindex(")") || -1) + 1..]
      fields = tail.to_s.split
      fields.presence
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

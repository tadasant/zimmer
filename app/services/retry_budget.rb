# frozen_string_literal: true

# One auto-recovery retry budget, declared once and read everywhere.
#
# Zimmer bounds eight distinct auto-recovery loops — SIGTERM retry, API-error retry,
# signal-death resume, MCP connection retry, context-length compact, session-id
# conflict recovery, empty-turn restart, lost-clone recovery. Each one counts its
# attempts in a `session.metadata` key, stamps when it last fired, has a maximum, and clears a set of
# keys once the process has been stable again for a while. Those four facts used to
# live in five different classes, in three naming conventions, with the reset logic
# written out three times and the metadata keys re-typed a fourth time as SQL inside
# HealthMonitorService.
#
# A budget is a declaration, not state: the state is the session's metadata, and every
# method here takes the session it is reading or writing. `RetryBudget.all` is the list
# the monitoring loop resets and the health surface enumerates, so a ninth failure
# class is one declaration rather than twenty copied lines plus two forgotten surfaces.
#
# It lives here rather than under `app/models/` because it is a value object over another
# model's column, not a record: `app/models/*.rb` is exclusively ActiveRecord, and
# test/contracts/supervisor_coverage_test.rb holds it to that by requiring an Administrate
# dashboard, a Supervisor controller and a route for everything in it.
#
# The values below are load-bearing. A wrong `key` silently counts nothing; a wrong
# `max` changes whether a real session recovers or fails permanently, and neither shows
# up until it happens to a long-running session in production.
class RetryBudget
  # How long a process must run without a fresh attempt before the budget is handed
  # back. The principle is the same for every loop: errors separated by a stable
  # stretch are separate incidents, not one crash-loop, and a session that OOMs once
  # every few hours should not accumulate toward its cap over its whole lifetime.
  DEFAULT_RESET_AFTER = 60

  # The empty-turn budget's own window, deliberately far above DEFAULT_RESET_AFTER.
  #
  # Every other budget is spent by a process that got going and then broke, so "this
  # process has been up for a minute" is real evidence the incident is over. The
  # empty-turn branch is the mirror image: it fires only while NEITHER transcript store
  # holds a conversation, so a process that is merely up proves nothing. A runtime can
  # sit for minutes bringing MCP servers up before it writes its first line — the
  # startup timeout Zimmer grants one is McpStartupTimeout::SECONDS — and handing
  # the budget back inside that window is exactly what would turn a bounded
  # empty-session failure into an unbounded restart loop, one cycle per startup
  # timeout, forever.
  #
  # 30 minutes clears the whole startup dead zone with room to spare, and is still
  # nothing against the case the resets exist for: a session that ran for a week and
  # then hit one unrelated incident (#727).
  EMPTY_TURN_RESET_AFTER = 30.minutes.to_i

  # What #reset_if_stable! reports when it actually cleared a counter, so the caller can
  # log what it was and how long the process had been up. nil means "nothing to do".
  Reset = Struct.new(:previous_count, :elapsed_seconds, keyword_init: true)

  @registry = {}

  class << self
    # Declare a budget. Returns the budget, which callers assign to a constant below.
    #
    # @param name [Symbol] stable identifier, used by .find and on the health surface
    # @param key [String] metadata key holding the attempt count
    # @param max [Integer] attempts allowed before the loop gives up
    # @param stamp [String] metadata key holding the ISO8601 time of the last attempt
    # @param clears [Array<String>] metadata keys dropped when the budget is handed back
    # @param label [String] human name of the failure class, for health output
    # @param counter_label [String] how the reset reads in a session log
    # @param reset_after [Integer] seconds of stability before the reset fires
    # @param terminal_status [Symbol] the status a session comes to rest in when this
    #   budget runs out, which is what #exhausted_sessions counts
    def define(name:, key:, max:, stamp:, clears:, label:, counter_label:,
               reset_after: DEFAULT_RESET_AFTER, terminal_status: :failed)
      raise ArgumentError, "retry budget #{name} is already declared" if @registry.key?(name)

      @registry[name] = new(
        name: name, key: key, max: max, stamp: stamp, clears: clears.dup.freeze,
        label: label, counter_label: counter_label, reset_after: reset_after,
        terminal_status: terminal_status
      )
    end

    # Every declared budget, in declaration order. The monitoring loop resets these and
    # the health surface reports these — adding a declaration is what wires both.
    # @return [Array<RetryBudget>]
    def all
      @registry.values
    end

    # @param name [Symbol]
    # @return [RetryBudget]
    def find(name)
      @registry.fetch(name)
    end
  end

  attr_reader :name, :key, :max, :stamp, :clears, :label, :counter_label, :reset_after,
    :terminal_status

  def initialize(name:, key:, max:, stamp:, clears:, label:, counter_label:, reset_after:,
                 terminal_status:)
    @name = name
    @key = key
    @max = max
    @stamp = stamp
    @clears = clears
    @label = label
    @counter_label = counter_label
    @reset_after = reset_after
    @terminal_status = terminal_status
    freeze
  end

  # Attempts already spent against this budget.
  # @param session [Session]
  # @return [Integer]
  def count_for(session)
    (session.metadata&.dig(key) || 0).to_i
  end

  # @param session [Session]
  # @return [Boolean] true when the loop must stop retrying and fail the session
  def exhausted?(session)
    count_for(session) >= max
  end

  # The attempt number the next retry will be — 1-based, as every log message renders it.
  # @param session [Session]
  # @return [Integer]
  def next_attempt(session)
    count_for(session) + 1
  end

  # When this budget last fired, or nil if it never has (or the stamp is unparseable).
  # @param session [Session]
  # @return [Time, nil]
  def last_attempt_at(session)
    raw = session.metadata&.dig(stamp)
    return nil if raw.blank?

    Time.parse(raw.to_s)
  rescue ArgumentError
    nil
  end

  # Spend one attempt: bump the count and stamp the time, atomically, leaving every key
  # this budget does not own alone.
  #
  # @param session [Session]
  # @param attempt [Integer, nil] the attempt number to record; defaults to one past the
  #   count currently stored. Callers that computed the number earlier — every retry
  #   service names it in a log line before it waits out a backoff — pass it explicitly
  #   so what was logged and what is stored cannot drift apart.
  # @param extra [Hash] additional metadata to write in the same statement — scan
  #   positions and continuation flags that belong to the caller, not to the budget
  # @return [Integer] the attempt number just recorded
  def record!(session, attempt: nil, extra: {})
    attempt ||= next_attempt(session)
    session.merge_metadata!(attempt_attributes(attempt).merge(extra.stringify_keys))
    attempt
  end

  # The count/stamp pair as a plain hash, for the one caller that has to fold it into a
  # wider `update!` alongside a non-metadata column.
  # @param attempt [Integer]
  # @return [Hash]
  def attempt_attributes(attempt)
    { key => attempt, stamp => Time.current.iso8601 }
  end

  # Hand the budget back if the process has been stable since its last attempt.
  #
  # @param session [Session]
  # @param since [Time, nil] when the last attempt happened; nil means nothing to reset
  # @param now [Time]
  # @return [Reset, nil] what was cleared, or nil if nothing was
  def reset_if_stable!(session, since:, now: Time.current)
    return nil unless since

    previous_count = count_for(session)
    return nil unless previous_count.positive?

    elapsed = now - since
    return nil unless elapsed >= reset_after

    session.remove_metadata!(clears)
    Reset.new(previous_count: previous_count, elapsed_seconds: elapsed)
  end

  # Sessions that have spent at least one attempt against this budget.
  # @return [ActiveRecord::Relation]
  def sessions
    Session.where("metadata->>? IS NOT NULL", key)
  end

  # Sessions carrying a parseable-or-not timestamp for this budget's last attempt.
  # The time filtering itself happens in Ruby, because metadata is not schema-checked
  # and a corrupt timestamp must not take the health page down.
  # @return [ActiveRecord::Relation]
  def stamped_sessions
    Session.where("metadata->>? IS NOT NULL", stamp)
  end

  # Sessions that came to rest with the budget fully spent — the "this session ran out
  # of attempts" number, which is the one an operator asking "why did it stop" is
  # looking for.
  #
  # `terminal_status` rather than a hardcoded `:failed`, because running out is not the
  # same ending for every loop: five of them fail the session, and the empty-turn
  # restart parks it in `needs_input` instead (ProcessLifecycleManager#handle_exit and
  # Sessions::RestartUnstartedTurn#abandon both come to rest rather than failing). A
  # `:failed` filter would report zero exhaustions for that budget no matter how many
  # sessions Zimmer gave up restarting.
  # @return [ActiveRecord::Relation]
  def exhausted_sessions
    sessions.where(status: terminal_status).where("(metadata->>?)::int >= ?", key, max)
  end

  # Sessions that spent the budget and did NOT come to rest in its terminal status —
  # the recovery worked. The complement of #exhausted_sessions' status filter, for the
  # same reason.
  # @return [ActiveRecord::Relation]
  def recovered_sessions
    sessions.where.not(status: terminal_status)
  end

  # --- The eight budgets ------------------------------------------------------------
  #
  # Key strings and maxima are exactly what each loop used before this object existed.

  SIGTERM = define(
    name: :sigterm,
    key: "sigterm_retry_count",
    max: 3,
    stamp: "last_sigterm_at",
    # The one budget whose cleared set is a named constant, because follow-up delivery
    # paths (triggers, the GitHub pollers) also hand a session a fresh SIGTERM budget.
    # It is left where it is deliberately: Session::STALE_RETRY_METADATA_KEYS is built
    # from it and is spread through sixteen `except(...)` call sites (issue #508).
    clears: Session::SIGTERM_RETRY_METADATA_KEYS,
    label: "SIGTERM retry",
    counter_label: "SIGTERM retry counter"
  )

  API_ERROR = define(
    name: :api_error,
    key: "api_error_retry_count",
    max: 6,
    stamp: "last_api_error_retry_at",
    # `api_error_last_checked_line` is deliberately NOT cleared: it is the transcript
    # scan position, not retry state, and re-processing old errors misclassifies a
    # transient rate limit as a quota limit.
    clears: %w[api_error_retry_count last_api_error_retry_at],
    label: "API error retry",
    counter_label: "API error retry counter"
  )

  SIGNAL_DEATH = define(
    name: :signal_death,
    key: "signal_death_retry_count",
    max: 3,
    stamp: "last_signal_death_at",
    clears: %w[signal_death_retry_count last_signal_death_at],
    label: "Signal-death resume",
    counter_label: "Signal-death resume counter"
  )

  MCP_CONNECTION = define(
    name: :mcp_connection,
    key: "mcp_retry_count",
    max: 3,
    stamp: "mcp_last_retry_at",
    # `mcp_failed_servers` stays: it names which servers failed, which is diagnosis
    # rather than budget, and the terminal failure path renders it.
    clears: %w[mcp_retry_count mcp_last_retry_at],
    label: "MCP connection retry",
    counter_label: "MCP connection retry counter"
  )

  CONTEXT_LENGTH = define(
    name: :context_length,
    key: "compact_retry_count",
    max: 2,
    stamp: "last_compact_at",
    # `pending_compact_continuation` and `context_length_last_checked_line` stay, for
    # the same reason the API-error scan position does: the first is a continuation
    # the compact still owes the user, the second is a scan position.
    clears: %w[compact_retry_count last_compact_at],
    label: "Context-length compact",
    counter_label: "Context-length compact counter"
  )

  # --- The recovery budgets (#727, #817) ---------------------------------------------
  #
  # Each bounds a recovery that can recur across a session's whole life, so each needs a
  # per-incident reset for the same reason the five above them do. Without one they are
  # lifetime caps: a session that survives two held-id conflicts in its first minute,
  # recovers and then works for a week fails permanently on the next unrelated conflict,
  # dropping the request it carries — `failed` rejects `follow_up`, so it cannot even be
  # resumed in place.

  # Left on DEFAULT_RESET_AFTER, and 60s is enough to terminate the looping case: the
  # refusal is a SPAWN-time one, reported and exited within seconds, so two conflicts in
  # one turn arrive seconds apart and no reset can land between them — every occurrence
  # in #519's recurrence table reached 2 inside a single turn. A process that has been up
  # for a full minute has, by construction, got past the spawn this budget bounds.
  SESSION_ID_CONFLICT = define(
    name: :session_id_conflict,
    key: "session_id_conflict_count",
    max: 2,
    stamp: "last_session_id_conflict_at",
    clears: %w[session_id_conflict_count last_session_id_conflict_at],
    label: "Session-id conflict recovery",
    counter_label: "Session-id conflict recovery counter"
  )

  # `unstarted_turn_restart_abandoned` is deliberately NOT cleared: it is the record of
  # a park Zimmer already announced, which is diagnosis rather than budget — the same
  # split that keeps `mcp_failed_servers` and the transcript scan positions.
  EMPTY_TURN = define(
    name: :empty_turn,
    key: "empty_turn_recovery_count",
    max: 2,
    stamp: "last_empty_turn_recovery_at",
    clears: %w[empty_turn_recovery_count last_empty_turn_recovery_at],
    label: "Empty-turn restart",
    counter_label: "Empty-turn restart counter",
    reset_after: EMPTY_TURN_RESET_AFTER,
    # The one budget whose exhaustion is a park, not a failure: both vantage points come
    # to rest in `needs_input` with the transcript empty rather than failing the session.
    terminal_status: :needs_input
  )

  # `lost_clone_recovery_abandoned` is deliberately NOT cleared, for the same reason
  # `unstarted_turn_restart_abandoned` is not: it records a failure Zimmer already
  # explained on the session's timeline, which is diagnosis rather than budget.
  #
  # On DEFAULT_RESET_AFTER, and unlike EMPTY_TURN a minute really is evidence here. The
  # recovery re-clones the working tree and resumes into it, so a process still up 60
  # seconds later is a process running inside a clone that exists — which is precisely
  # the condition whose absence spends this budget. Two clone losses an hour apart are
  # two incidents; two inside one minute are a loop, and the loop is what max bounds.
  LOST_CLONE = define(
    name: :lost_clone,
    key: "lost_clone_recovery_count",
    max: 2,
    stamp: "last_lost_clone_recovery_at",
    clears: %w[lost_clone_recovery_count last_lost_clone_recovery_at],
    label: "Lost-clone recovery",
    counter_label: "Lost-clone recovery counter"
  )
end

# frozen_string_literal: true

# The third cleanup lever for a runaway queue: discarding or rescheduling the
# jobs that are already enqueued.
#
# WHY THIS EXISTS
# ---------------
# QueueRecoveryMode halts the demand-side queues so somebody can act on the cause
# of a backlog. Two of the three levers were already reachable from every surface
# — disable the stampeding Trigger, archive the runaway sessions — and the third
# was not: discarding the enqueued rows themselves was only possible through
# GoodJob's own HTML dashboard at `/jobs`. An agent session started to work the
# incident could do two thirds of the job and then had to ask a human to click
# through a different app (#335). This service is the shared implementation
# behind the MCP action, the REST endpoint and the `/health` control, so the three
# cannot mean different things.
#
# WHAT IS AND IS NOT RECOVERABLE
# ------------------------------
# **A discard is not recoverable.** It writes `finished_at` and a DiscardJobError
# onto the row; the work never runs. For a poller tick that is exactly right — the
# next tick does the same work — and for anything carrying state it is not.
# **Reschedule is the reversible sibling**: it only moves `scheduled_at`, so the
# work still happens, later, and another call moves it back. Reach for reschedule
# unless you are certain the work is disposable.
#
# THE SCOPE PREDICATE IS THE DANGEROUS PART
# -----------------------------------------
# A bulk destructive op on `good_jobs` with an over-broad predicate strands live
# sessions and fails silently. So the predicate is narrow on four independent
# axes, each of which alone would be enough to keep a running session safe:
#
#   1. `finished_at IS NULL`  — finished and already-discarded history is never
#      touched, so this can neither rewrite the audit trail nor double-discard.
#   2. `performed_at IS NULL` — a row whose execution has STARTED is never
#      touched. GoodJob resets `performed_at` on retry, so this excludes exactly
#      the in-flight executions and keeps the waiting retries.
#   3. `locked_by_id IS NULL` — nor is a row a worker has claimed but not yet
#      started.
#   4. PROTECTED_QUEUES / PROTECTED_JOB_CLASSES — refused by name, up front, and
#      excluded again in the predicate.
#
# On top of that the caller must name a scope (an unscoped "discard everything"
# is refused), must state the row count it expects (a mismatch refuses and
# performs nothing), and cannot exceed MAX_PER_CALL in one call.
class QueuedJobMaintenance
  # The queues this refuses to touch, by name.
  #
  # `agents` holds two things that must not be discardable. An unfinished
  # `AgentSessionJob` row IS a live session, not a backlog entry — discarding it
  # strands the session with a job nothing will ever run. And
  # `QueueRecoveryModeExpiryJob`, the cron backstop that lifts a halt when its TTL
  # elapses, runs there precisely because `agents` is the queue recovery mode does
  # not pause: discarding it during an incident would remove the thing that
  # guarantees the halt ends.
  #
  # `auth` is deliberately NOT here. RuntimeLoginJob runs only when a human presses
  # a button, so it is not a source of backlog, and a discarded one costs a second
  # click rather than a stranded session.
  PROTECTED_QUEUES = %w[agents].freeze

  # The same two populations, by class, so moving either onto another queue does
  # not quietly make it discardable.
  PROTECTED_JOB_CLASSES = %w[AgentSessionJob QueueRecoveryModeExpiryJob].freeze

  # The hard cap on rows one call may affect. Not a performance limit: it is the
  # bound on how much damage a single wrong `job_class` can do. A genuine backlog
  # bigger than this is discarded in several calls, each of which has to state its
  # own count.
  MAX_PER_CALL = 2_000

  # How far out a reschedule may push work. A reschedule further out than this is
  # a discard wearing a disguise, and should be argued for as one.
  MAX_RESCHEDULE_DELAY = 7.days

  # How many distinct job classes / queues the preview names before collapsing the
  # rest into a labelled remainder.
  BREAKDOWN_LIMIT = 25

  ACTIONS = %i[discard reschedule].freeze

  # The label a NULL/blank `job_class` or `queue_name` is reported under, matching
  # HealthMonitorService's own breakdowns so the two pages agree.
  UNKNOWN = "(unknown)"

  # Raised for every refusal: an unscoped call, a protected target, a count that
  # does not match, a request over the cap. Every one of them happens BEFORE any
  # row is written, which is what "mismatch → refuse, no partial action" means.
  class Refused < StandardError; end

  # What a call did. `by_job_class` / `by_queue` are the audit the transcript
  # keeps: an operator reading it back knows what class was thrown away, not just
  # how many rows.
  Result = Data.define(
    :action, :job_class, :queue_name, :matched, :affected, :by_job_class, :by_queue,
    :skipped, :scheduled_at, :actor, :performed_at
  ) do
    def as_json(*)
      {
        action: action.to_s,
        scope: { job_class: job_class, queue_name: queue_name },
        matched: matched,
        affected: affected,
        by_job_class: by_job_class,
        by_queue: by_queue,
        skipped: skipped,
        scheduled_at: scheduled_at&.iso8601,
        actor: actor,
        performed_at: performed_at&.iso8601,
        recoverable: action == :reschedule
      }.compact
    end
  end

  # What a scope currently holds, without touching anything. The number the caller
  # then has to state back as `expected_count`.
  Preview = Data.define(:job_class, :queue_name, :matched, :by_job_class, :by_queue, :over_cap) do
    def over_cap? = over_cap

    def as_json(*)
      {
        scope: { job_class: job_class, queue_name: queue_name },
        matched: matched,
        by_job_class: by_job_class,
        by_queue: by_queue,
        over_cap: over_cap,
        max_per_call: MAX_PER_CALL
      }
    end
  end

  class << self
    # Count the eligible rows in a scope and break them down by class and queue.
    #
    # Read-only, and the read every other entry point here starts from: `/health`
    # renders it as the list of rows an operator can act on, and an MCP or REST
    # caller reads it to learn the `expected_count` the mutating calls require.
    #
    # @param job_class [String, nil] exact class name, or nil for any
    # @param queue_name [String, nil] exact queue name, or nil for any
    # @param require_scope [Boolean] false for the dashboard's whole-instance view,
    #   which is a read and so is allowed to be unscoped
    # @return [Preview]
    def preview(job_class: nil, queue_name: nil, require_scope: true)
      job_class = normalize(job_class)
      queue_name = normalize(queue_name)
      refuse_unscoped!(job_class, queue_name) if require_scope
      refuse_protected!(job_class, queue_name)

      by_job_class = Hash.new(0)
      by_queue = Hash.new(0)
      matched = 0

      eligible(job_class: job_class, queue_name: queue_name)
        .group(:job_class, :queue_name).count
        .each do |(klass, queue), count|
          by_job_class[klass.presence || UNKNOWN] += count
          by_queue[queue.presence || UNKNOWN] += count
          matched += count
        end

      Preview.new(
        job_class: job_class,
        queue_name: queue_name,
        matched: matched,
        by_job_class: top_counts(by_job_class),
        by_queue: top_counts(by_queue),
        over_cap: matched > MAX_PER_CALL
      )
    end

    # Every (job_class, queue_name) pair with eligible rows, biggest first.
    #
    # The `/health` panel's data: each row becomes one line with its own Discard
    # and Reschedule controls, scoped on BOTH columns so a click can never reach
    # further than the line it was next to. `Preview` deliberately does not carry
    # this — it reports the two axes separately, which is the right shape for a
    # tool response and the wrong one for a table.
    #
    # @param limit [Integer] rows to return; the tail is dropped rather than
    #   collapsed, because a control for "everything else" is not one anybody
    #   should be offered.
    # @return [Array<Hash>] :job_class, :queue_name, :count
    def breakdown(limit: BREAKDOWN_LIMIT)
      eligible.group(:job_class, :queue_name).count
        .map { |(klass, queue), count| { job_class: klass.presence, queue_name: queue.presence, count: count } }
        .sort_by { |row| [ -row[:count], row[:job_class].to_s, row[:queue_name].to_s ] }
        .first(limit)
    end

    # Discard every eligible row in the scope. NOT RECOVERABLE — see the class
    # comment; `reschedule!` is the reversible sibling.
    #
    # @param expected_count [Integer] the row count the caller believes it is
    #   acting on. A mismatch refuses and writes nothing.
    # @return [Result]
    def discard!(job_class: nil, queue_name: nil, expected_count:, actor: nil, reason: nil)
      message = "Discarded from Zimmer queue maintenance by #{actor.presence || 'unknown'}" \
                "#{": #{reason.to_s.strip}" if reason.present?}"

      apply!(
        :discard,
        job_class: job_class, queue_name: queue_name,
        expected_count: expected_count, actor: actor
      ) { |job| job.discard_job(message) }
    end

    # Move every eligible row in the scope to a new `scheduled_at`. The reversible
    # half of this service: the work still happens, and another call moves it back.
    #
    # @param scheduled_at [Time, nil] when the rows should next become eligible;
    #   nil means now. Clamped to now..MAX_RESCHEDULE_DELAY.
    # @return [Result]
    def reschedule!(job_class: nil, queue_name: nil, expected_count:, scheduled_at: nil, actor: nil)
      target = clamp_scheduled_at(scheduled_at)

      apply!(
        :reschedule,
        job_class: job_class, queue_name: queue_name,
        expected_count: expected_count, actor: actor, scheduled_at: target
      ) { |job| job.reschedule_job(target) }
    end

    # The eligible-row predicate, exposed so a test can assert directly on it and
    # so the dashboard can count without going through Preview.
    #
    # Every clause here is load-bearing — see the class comment. The two
    # `IS NULL OR NOT IN` spellings are deliberate: a plain `where.not` drops rows
    # whose column is NULL, which would silently exclude a job GoodJob left without
    # a queue name from a scope that is supposed to include it.
    def eligible(job_class: nil, queue_name: nil)
      scope = GoodJob::Job
        .where(finished_at: nil)
        .where(performed_at: nil)
        .where(locked_by_id: nil)
        .where("good_jobs.queue_name IS NULL OR good_jobs.queue_name NOT IN (?)", PROTECTED_QUEUES)
        .where("good_jobs.job_class IS NULL OR good_jobs.job_class NOT IN (?)", PROTECTED_JOB_CLASSES)

      scope = scope.where(job_class: job_class) if job_class.present?
      scope = scope.where(queue_name: queue_name) if queue_name.present?
      scope
    end

    # Clamp a caller-supplied time into now..MAX_RESCHEDULE_DELAY. A past time
    # becomes now (which is what "run it as soon as the queue allows" means), and
    # a time beyond the cap becomes the cap rather than an error, matching how
    # QueueRecoveryMode treats an out-of-range TTL.
    def clamp_scheduled_at(value)
      now = Time.current
      return now if value.blank?

      target = value.is_a?(Time) || value.is_a?(DateTime) ? value.to_time : Time.zone.parse(value.to_s)
      return now if target.nil?

      target.clamp(now, now + MAX_RESCHEDULE_DELAY)
    rescue ArgumentError, TypeError
      now
    end

    private

    # The one write path. Both public mutators funnel through it so the refusals —
    # unscoped, protected, over cap, count mismatch — cannot differ between them,
    # and so neither can skip one.
    def apply!(action, job_class:, queue_name:, expected_count:, actor:, scheduled_at: nil, &row)
      job_class = normalize(job_class)
      queue_name = normalize(queue_name)

      refuse_unscoped!(job_class, queue_name)
      refuse_protected!(job_class, queue_name)

      snapshot = preview(job_class: job_class, queue_name: queue_name)
      refuse_over_cap!(action, snapshot)
      refuse_count_mismatch!(action, snapshot, expected_count)

      # Re-read the ids AFTER every refusal has passed, and cap the read, so the
      # rows written are a bounded set drawn from the scope just counted rather
      # than whatever an unbounded cursor finds while the set is being mutated.
      ids = eligible(job_class: job_class, queue_name: queue_name).limit(MAX_PER_CALL).pluck(:id)

      by_job_class = Hash.new(0)
      by_queue = Hash.new(0)
      skipped = []

      ids.each_slice(200) do |slice|
        GoodJob::Job.where(id: slice).each do |job|
          row.call(job)
          by_job_class[job.job_class.presence || UNKNOWN] += 1
          by_queue[job.queue_name.presence || UNKNOWN] += 1
        rescue StandardError => e
          # A row a worker claimed between the count and the write, or one GoodJob
          # refuses for a state this predicate could not see. Reported, never
          # retried, and never fatal: the rest of the batch still gets done and the
          # receipt says how many did not.
          skipped << { id: job.id, job_class: job.job_class, reason: "#{e.class}: #{e.message}" }
        end
      end

      result = Result.new(
        action: action,
        job_class: job_class,
        queue_name: queue_name,
        matched: snapshot.matched,
        affected: by_job_class.values.sum,
        by_job_class: by_job_class.sort_by { |klass, count| [ -count, klass.to_s ] }.to_h,
        by_queue: by_queue.sort_by { |queue, count| [ -count, queue.to_s ] }.to_h,
        skipped: skipped,
        scheduled_at: scheduled_at,
        actor: actor.to_s.strip.presence,
        performed_at: Time.current
      )

      log(result)
      alert(result)
      result
    end

    def refuse_unscoped!(job_class, queue_name)
      return if job_class.present? || queue_name.present?

      raise Refused, "Refusing an unscoped job maintenance call: name a job_class, a queue_name, or both. " \
        "Acting on every queued job at once is never the intended request."
    end

    def refuse_protected!(job_class, queue_name)
      if queue_name.present? && PROTECTED_QUEUES.include?(queue_name)
        raise Refused, "The #{queue_name.inspect} queue is protected and cannot be touched from here. " \
          "An unfinished job on it is a live agent session or the backstop that lifts queue recovery mode, " \
          "not a backlog entry. Archive or kill the session instead (action_session / the sessions list)."
      end

      return unless job_class.present? && PROTECTED_JOB_CLASSES.include?(job_class)

      raise Refused, "#{job_class} is protected and cannot be discarded or rescheduled from here. " \
        "#{protected_class_reason(job_class)}"
    end

    def protected_class_reason(job_class)
      if job_class == "AgentSessionJob"
        "An unfinished AgentSessionJob row IS a live session — discarding it strands the session with a " \
          "job nothing will run. Archive or kill the session instead (action_session / the sessions list)."
      else
        "It is the cron backstop that lifts queue recovery mode when its TTL elapses; discarding it during " \
          "an incident removes the guarantee that the halt ends."
      end
    end

    def refuse_over_cap!(action, snapshot)
      return unless snapshot.over_cap?

      raise Refused, "#{snapshot.matched} rows match#{scope_phrase(snapshot)}, over the #{MAX_PER_CALL}-row " \
        "cap for one #{action} call. Narrow the scope (name a job_class as well as a queue_name) and repeat. " \
        "Breakdown by class: #{format_counts(snapshot.by_job_class)}."
    end

    def refuse_count_mismatch!(action, snapshot, expected_count)
      expected = coerce_count(expected_count)

      if expected.nil? || expected.negative?
        raise Refused, "expected_count is required and must be a non-negative integer: state how many rows you " \
          "believe this #{action} will affect. #{snapshot.matched} match#{scope_phrase(snapshot)} right now."
      end

      return if expected == snapshot.matched

      raise Refused, "Count confirmation failed: you expected #{expected} row#{'s' unless expected == 1}, " \
        "#{snapshot.matched} match#{scope_phrase(snapshot)}. Nothing was #{action == :discard ? 'discarded' : 'rescheduled'}. " \
        "Breakdown by class: #{format_counts(snapshot.by_job_class)}. By queue: #{format_counts(snapshot.by_queue)}. " \
        "Re-issue with expected_count=#{snapshot.matched} if that is what you meant."
    end

    # A count may arrive as an Integer (MCP), a String (an HTML form or a query
    # string), or a whole Float (a JSON number some clients render that way).
    # Anything else — nil, "all", 3.5 — is not a confirmation and must not be
    # treated as one.
    def coerce_count(value)
      case value
      when Integer then value
      when Numeric then value.to_i == value ? value.to_i : nil
      else Integer(value.to_s.strip, exception: false)
      end
    end

    def scope_phrase(snapshot)
      parts = []
      parts << "job_class=#{snapshot.job_class}" if snapshot.job_class.present?
      parts << "queue_name=#{snapshot.queue_name}" if snapshot.queue_name.present?
      parts.any? ? " #{parts.join(' ')}" : ""
    end

    def format_counts(counts)
      return "none" if counts.blank?

      counts.map { |key, count| "#{key}=#{count}" }.join(", ")
    end

    # Biggest first, with everything past BREAKDOWN_LIMIT collapsed into one
    # labelled remainder so a pathological instance cannot produce an unbounded
    # tool response.
    def top_counts(counts)
      ordered = counts.sort_by { |key, count| [ -count, key.to_s ] }
      return ordered.to_h if ordered.size <= BREAKDOWN_LIMIT

      kept = ordered.first(BREAKDOWN_LIMIT).to_h
      kept["(#{ordered.size - BREAKDOWN_LIMIT} more)"] = ordered.drop(BREAKDOWN_LIMIT).sum { |_, count| count }
      kept
    end

    def normalize(value)
      value.to_s.strip.presence
    end

    def log(result)
      Rails.logger.warn(
        "[queued_job_maintenance] #{result.action}: scope=#{{ job_class: result.job_class, queue_name: result.queue_name }.compact} " \
        "matched=#{result.matched} affected=#{result.affected} skipped=#{result.skipped.size} " \
        "by_class=#{result.by_job_class} actor=#{result.actor.inspect}"
      )
    end

    # A bulk write against `good_jobs` should be legible to somebody who was not
    # reading the transcript it happened in. Never fatal: the rows are already
    # written by the time this runs, and a Slack outage must not make a completed
    # action look like a failed one.
    def alert(result)
      return if result.affected.zero?

      verb = result.action == :discard ? "discarded" : "rescheduled"
      AlertService.raise_alert(
        "Queued jobs #{verb}: #{result.affected} row#{'s' unless result.affected == 1}",
        details: [
          "*#{result.affected}* queued job#{'s' unless result.affected == 1} #{verb} by #{result.actor || 'unknown'}.",
          "By class: #{format_counts(result.by_job_class)}",
          result.action == :reschedule ? "New scheduled_at: #{result.scheduled_at&.iso8601}" : nil,
          result.action == :discard ? "A discard is not recoverable — those jobs will never run." : nil,
          result.skipped.any? ? "Skipped #{result.skipped.size} row(s) that changed state mid-call." : nil
        ].compact.join("\n"),
        source: name,
        # Keyed by the instant, so two separate maintenance passes both announce
        # rather than the second being swallowed as a duplicate of the first.
        dedup_key: "queued_job_maintenance:#{result.action}:#{result.performed_at.to_i}"
      )
    rescue StandardError => e
      Rails.logger.error("[queued_job_maintenance] could not deliver alert: #{e.message}")
    end
  end
end

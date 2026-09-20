# frozen_string_literal: true

module Sessions
  # "Force": give a turn that is queued for a worker one of the pool's threads
  # NOW, by stopping the turn that most recently took one.
  #
  # == What it is for
  #
  # The `agents` lane runs `RunningTurns.worker_slots` threads and no more. When
  # every one of them is busy, a session a human is watching sits in `waiting`
  # behind turns nobody is waiting on, and nothing it can be told changes that:
  # Sessions::StartNow reports "its queued turn is already due" and stops, which
  # is the literal truth and no help at all. Making the session priority does not
  # help either — the spot gate decides WHETHER a turn may run, and thread
  # contention inside GoodJob is a different mechanism that applies to priority
  # sessions in exactly the same way.
  #
  # So this is the one lever that is actually about the pool: it takes a thread
  # off a turn that has one and gives it to a turn that does not. It is expensive
  # by construction, which is why it is a deliberate click and never a sweep.
  #
  # == Who the victim is
  #
  # The most recently started turn, by `performed_at` on its `agents` job. That
  # is the rule as asked for, and it is purely about recency: the turn that has
  # been on a thread for eleven seconds has the least to lose, and it is also the
  # one that most plausibly slipped in ahead of the session doing the forcing.
  #
  # **The victim's CLASS is not part of the rule.** A priority session running an
  # eleven-second-old turn is a candidate exactly as a spot session is. That is a
  # deliberate reading of the request rather than an oversight — see the PR that
  # introduced this class for the alternative (prefer spot victims, fall back to
  # priority) and why it was not substituted for what was asked for.
  #
  # Five exclusions, and each one is a case where taking the thread would buy
  # nothing or would break somebody else's record:
  #
  #   * **The forcing session itself.** Obvious, and cheap to get wrong.
  #   * **A job whose worker is not alive** (`JobLiveness` says anything but
  #     `:running`). Its thread is already gone; halting it frees nothing and the
  #     session belongs to a recovery sweep.
  #   * **A session that is not `running`.** A worker holding a job while it makes
  #     the clone has no agent process to stop, so Sessions::HaltRunningTurn would
  #     report `not_running` and the thread would stay taken.
  #   * **A session already carrying a spot pause or preempt record.** Its slot is
  #     already on its way back and SpotSessionPause's sweep is keyed on that
  #     record; writing a second story over it is how a session ends up with two
  #     resume owners (tadasant/zimmer#617).
  #   * **A status-summary fork.** It takes exactly one turn and is then done, so
  #     there is no conversation to put back in the queue — re-enqueuing one would
  #     hand it a second turn it has no use for.
  #
  # Plus a {COOLDOWN}: a session that was forced out in the last few minutes is
  # skipped in favour of the next candidate. Without it, forcing twice in a row
  # kills the same session both times — it is re-queued by the first force, picks
  # up the thread that frees next, and is then the most recently started turn
  # again.
  #
  # == What "killing" the victim means
  #
  # Its turn is stopped and PUT STRAIGHT BACK IN THE QUEUE. Nothing is cancelled
  # and no work is silently lost:
  #
  #   1. The force record goes on the victim's row FIRST (see
  #      Sessions::HaltRunningTurn on why callers park before they halt), so its
  #      own page and its own timeline say what happened to it and whose turn took
  #      its thread.
  #   2. Sessions::HaltRunningTurn stops the process and lands the session in
  #      `waiting` — the same cost a spot ceiling pause pays: work written to disk
  #      stays written, the tool call in flight is lost.
  #   3. `resume_for_system_recovery!` puts it straight back, which preserves the
  #      wake-ups it had armed (it did not choose to stop, so they are still
  #      exactly what it is waiting on), and a fresh AgentSessionJob carries it
  #      into the `agents` queue with a nudge that names what happened.
  #
  # The victim therefore ends where the forcing session began — `waiting`, with a
  # ready turn, behind the pool — which is the honest place for it. Its resume
  # owner is GoodJob's own poller, the same owner every queued turn has, so this
  # class adds no sweep and no second claim on the session. If step 3 fails after
  # step 2 succeeded, the victim is a `waiting` session with no turn, which is
  # exactly the population StrandedSleepRescue owns.
  #
  # == How the forced turn actually gets the thread
  #
  # Freeing a thread is not the same as getting it. GoodJob dequeues
  # `priority ASC NULLS LAST, created_at ASC`, and nothing in Zimmer sets a job
  # priority — so every AgentSessionJob carries GoodJob's own DEFAULT_PRIORITY of
  # 0, and the freed thread would go to whichever queued turn is oldest, which is
  # very unlikely to be this one. The forced job's priority is therefore set to
  # {FORCED_JOB_PRIORITY}, a negative number that sorts ahead of that. Two forced
  # turns tie there and fall back to `created_at`, which is first-come among forced
  # turns and is the order a human forcing two sessions in a row would expect.
  #
  # == What it does not promise
  #
  # A SPOT session's turn still answers to the spot gate when the worker picks it
  # up, exactly as Sessions::StartNow's does. Forcing gets it a thread; a quota
  # window over its target can still hold it the moment it has one — and then
  # another session's turn was stopped for nothing. The affordance says so before
  # the click and the result says so after it, rather than claiming a start it
  # cannot deliver.
  #
  # And Zimmer cannot tell what the victim is in the middle of. There is no signal
  # on a session row that says "this turn is half-way through an irreversible
  # external action", so no rule here pretends to know: the confirmation names the
  # victim and its age and leaves the judgement to the person clicking.
  class ForceTurnStart
    # `forced`    - a thread was taken and this session's turn has it
    # `no_victim` - nothing could be stopped; `message` says why
    # `refused`   - this session cannot be forced at all; `message` says why
    Result = Data.define(:outcome, :message, :victim) do
      def forced? = outcome == :forced
      def no_victim? = outcome == :no_victim
      def refused? = outcome == :refused
    end

    # What the banner needs to decide between an armed button and an honest line
    # about why there is nothing to force.
    #
    # `victim` is the session that WOULD be stopped, so the confirmation can name
    # it. It is a preview and not a promise — the pick is made again under a lock
    # when the button is pressed, and a turn that ended in between changes the
    # answer. The flash reports what actually happened.
    Preview = Data.define(:available, :victim, :victim_age, :message) do
      def available? = available
    end

    # How long after being forced out a session is passed over in favour of the
    # next candidate.
    #
    # Short, because it is not a fairness quota — it exists only to stop the
    # immediate loop where the session a force just re-queued is the very next
    # turn to start, and so is the next force's victim. Five minutes is longer
    # than the gap between a re-queued turn getting a thread and a human clicking
    # again, and short enough that it never empties a small fleet's candidate list
    # for long.
    COOLDOWN = 5.minutes

    # The durable half of the force ledger, kept out of every clearing set on
    # purpose: the whole point is to be readable on a session that has already
    # come back.
    FORCED_AT = "forced_out_at"
    FORCED_FOR_SESSION = "forced_out_for_session"
    FORCED_COUNT = "forced_out_count"

    # Sorts ahead of the 0 every AgentSessionJob carries — `GoodJob::Job`'s own
    # DEFAULT_PRIORITY, since nothing here calls `queue_with_priority`. Negative
    # rather than zero because zero would only tie, and nowhere near the integer
    # bounds so a future lane with priorities of its own has room on both sides.
    FORCED_JOB_PRIORITY = -100

    class << self
      # @param session [Session]
      # @param actor [String] who asked, for both sessions' logs
      # @return [Result]
      def call(session, actor: "a user")
        new(session, actor: actor).call
      end

      # @param session [Session]
      # @return [Preview, nil] nil when this session is not queued for a worker
      #   at all, which is when the banner this feeds is not drawn either
      def preview(session)
        new(session).preview
      end
    end

    def initialize(session, actor: "a user")
      @session = session
      @actor = actor
    end

    def call
      refusal = refusal_reason
      return Result.new(outcome: :refused, message: refusal, victim: nil) if refusal

      victim = choose_victim
      return Result.new(outcome: :no_victim, message: no_victim_message, victim: nil) if victim.nil?

      unless yield_the_thread!(victim)
        return Result.new(
          outcome: :no_victim, victim: nil,
          message: "Session #{victim.id}'s turn could not be stopped, so nothing was taken from it and " \
                   "session #{session.id} is still queued. See session #{victim.id}'s log, and try again."
        )
      end

      promote_the_queued_job

      session.logs.create!(level: "warning", content: forced_message(victim))
      Result.new(outcome: :forced, message: success_message(victim), victim: victim)
    end

    # @return [Preview, nil]
    def preview
      return nil unless queued_turn_ready?

      victim = choose_victim
      return Preview.new(available: false, victim: nil, victim_age: nil, message: no_victim_message) if victim.nil?

      Preview.new(available: true, victim: victim, victim_age: victim_turn_age(victim), message: nil)
    end

    private

    attr_reader :session, :actor

    # Why this session cannot be forced. Deliberately the SAME question the banner
    # is gated on, asked again at the click: the page a human is looking at can be
    # seconds old, and by far the commonest way to press this button is to press
    # it just as the turn started on its own.
    def refusal_reason
      return "Session #{session.id} is in the trash." if session.archived?
      unless session.waiting?
        return "Session #{session.id} is #{session.status} — only a session queued for a worker can be forced."
      end

      case queued_job_status
      when :queued
        nil
      when :running
        "Session #{session.id}'s turn already has a worker — it is making the clone and starting the " \
        "agent now. There is nothing to force."
      when :unreadable
        "Could not read the agents queue for session #{session.id}, so nothing was touched. Try again."
      else
        "Session #{session.id} has no turn queued for a worker, so there is no turn to force. " \
        "Start it, or send it a follow-up."
      end
    end

    # Why there is no victim, in the words the banner prints and the flash repeats.
    #
    # The two cases are genuinely different advice, which is why they are not one
    # sentence: a pool with a free thread needs no force at all, and a pool with no
    # stoppable turn on it cannot be helped by one.
    def no_victim_message
      if occupancy < RunningTurns.worker_slots
        "Nothing to force: #{occupancy} of Zimmer's #{RunningTurns.worker_slots} worker threads are busy, " \
        "so a thread is already free and session #{session.id}'s turn starts on GoodJob's next poll."
      else
        "Nothing to force: all #{RunningTurns.worker_slots} worker threads are busy, but none of the turns " \
        "on them can be stopped right now — they are being set up, already parked, or were forced out in " \
        "the last #{COOLDOWN.inspect}. Session #{session.id} keeps its place in the queue."
      end
    end

    # === Choosing the victim ==================================================

    # The most recently started turn that may be stopped, or nil.
    #
    # Nil whenever the pool is NOT full, before any candidate is even considered:
    # a free thread means GoodJob's next poll starts this turn anyway, and
    # stopping somebody for a thread that was already coming is pure loss.
    def choose_victim
      return nil if occupancy < RunningTurns.worker_slots

      live_turns.each do |job, candidate|
        next unless stoppable?(candidate)

        return candidate
      end
      nil
    rescue StandardError => e
      # Every failure direction in this class is "force nothing". A read that
      # cannot be made is not evidence that a turn may be stopped.
      Rails.logger.warn("[Sessions::ForceTurnStart] Could not choose a victim for session " \
                        "#{session&.id} (#{e.class}: #{e.message}) — forcing nothing")
      nil
    end

    def stoppable?(candidate)
      return false if candidate.id == session.id
      return false unless candidate.running?
      return false if candidate.status_summary_fork?
      return false if SpotSessionPause.pause_record?(candidate)
      return false if cooling_down?(candidate)

      true
    end

    def cooling_down?(candidate)
      forced_at = parse_time((candidate.metadata || {})[FORCED_AT])
      forced_at.present? && forced_at + COOLDOWN > Time.current
    end

    # The turns a worker is actually executing, newest first, paired with their
    # sessions.
    #
    # `performed_at` picks the population and `JobLiveness` narrows it: a job whose
    # lock holder has gone still has a `performed_at` forever, and its thread died
    # with the capsule that held it. See RunningTurns for why the two facts are
    # both needed.
    def live_turns
      @live_turns ||= begin
        jobs = GoodJob::Job
          .where(job_class: AgentSessionJob.name, finished_at: nil)
          .where.not(performed_at: nil)
          .order(performed_at: :desc)
          .to_a
          .select { |job| JobLiveness.status(job) == :running }

        sessions = Session.where(id: jobs.map { |job| session_id_of(job) }.compact).index_by(&:id)
        jobs.filter_map do |job|
          candidate = sessions[session_id_of(job)]
          [ job, candidate ] if candidate
        end
      end
    end

    # How many of the pool's threads are held right now.
    #
    # Counted off the same reading the victim search uses rather than through
    # `Session.running_turns`, so the button's two claims — "the pool is full" and
    # "this is the turn that would be stopped" — can never come from two different
    # snapshots.
    #
    # And deliberately NOT `RunningTurns`' occupancy, which is narrower: that one
    # counts turns an agent process is executing, because its callers are ceilings
    # on concurrent work. The question here is "is a thread free", and a worker
    # holding a job while it makes the clone is using a thread just as surely as
    # one running an agent. Counting it the ceilings' way would report a free
    # thread that does not exist and refuse a force that was justified.
    def occupancy
      @occupancy ||= live_turns.size
    end

    def victim_turn_age(victim)
      job, = live_turns.find { |_job, candidate| candidate.id == victim.id }
      return nil if job&.performed_at.blank?

      Time.current - job.performed_at
    end

    # === Taking the thread ====================================================

    # Stop the victim's turn and put it straight back in the queue.
    #
    # @return [Boolean] whether the thread was actually taken
    def yield_the_thread!(victim)
      record_the_force(victim)

      result = Sessions::HaltRunningTurn.call(
        session: victim, reason: Sessions::HaltRunningTurn::FORCED_TURN_START
      )
      unless result.halted
        Rails.logger.info("[Sessions::ForceTurnStart] Session #{victim.id}'s turn was not halted " \
                          "(#{result.reason}) — session #{session.id} keeps its place in the queue")
        return false
      end

      victim.logs.create!(level: "warning", content: victim_message)
      requeue(victim)
      true
    end

    # The victim's own record of what happened to it, written BEFORE the halt.
    #
    # Sessions::HaltRunningTurn documents the order: park first, halt second, so a
    # halt that only partly succeeds degrades to a session whose row already says
    # why rather than to one that stopped for no recorded reason. `FORCED_COUNT` is
    # cumulative and survives the resume below, which is what {COOLDOWN}'s sibling
    # stamp and any later fairness question would be read off.
    def record_the_force(victim)
      victim.merge_metadata!(
        FORCED_AT => Time.current.utc.iso8601,
        FORCED_FOR_SESSION => session.id,
        FORCED_COUNT => (victim.metadata || {})[FORCED_COUNT].to_i + 1
      )
    end

    # Back into the `agents` queue, in the same gesture that stopped it.
    #
    # `resume_for_system_recovery!` rather than a plain resume: this session did not
    # choose to stop, so the wake-ups it had armed are still exactly what it is
    # waiting on, and consuming them is what strands an orchestrator watching
    # children (see SessionStateMachine#system_recovery_resume).
    def requeue(victim)
      victim.reload
      unless victim.waiting? && victim.may_resume?
        Rails.logger.warn("[Sessions::ForceTurnStart] Session #{victim.id} is #{victim.status} after its " \
                          "turn was forced out — leaving it to Zimmer's stranded-sleep rescue")
        return
      end

      victim.resume_for_system_recovery!
      AgentSessionJob.enqueue_with_prompt(
        victim.id,
        AutomatedPrompts.system_recovery(
          reason: "Zimmer stopped this session's turn to give its worker thread to session " \
                  "#{session.id}, which a human had been waiting on, and put this turn straight back " \
                  "in the queue"
        )
      )
    rescue StandardError => e
      # The halt already happened, so this cannot be unwound. A `waiting` session
      # with no turn is StrandedSleepRescue's population, which is the backstop
      # this deliberately falls to rather than inventing a second one.
      Rails.logger.warn("[Sessions::ForceTurnStart] Could not put session #{victim.id}'s turn back in the " \
                        "queue (#{e.class}: #{e.message}) — leaving it to Zimmer's stranded-sleep rescue")
    end

    # Put the forced turn at the head of the `agents` queue.
    #
    # Conditional on the row still being unclaimed and unfinished, in the UPDATE
    # itself: between the read at the top of this call and here a worker may have
    # picked the turn up anyway, and re-prioritising a job that is already running
    # is meaningless — but it would also be a write against a row GoodJob holds a
    # lock on, which is worth not doing.
    def promote_the_queued_job
      job = queued_job
      return if job.nil?

      GoodJob::Job.where(id: job.id, finished_at: nil, performed_at: nil, locked_by_id: nil)
                  .update_all(priority: FORCED_JOB_PRIORITY)
    rescue StandardError => e
      # The thread is free either way, and this session's turn is in the queue for
      # it. Losing the bump costs it the race against whatever else is queued, not
      # the turn.
      Rails.logger.warn("[Sessions::ForceTurnStart] Could not prioritise session #{session.id}'s queued " \
                        "turn (#{e.class}: #{e.message}) — it keeps its place in the queue")
    end

    # === This session's own queued turn =======================================

    # The `agents` job this session is waiting on, the same one
    # SessionWaitingReason reads to draw the banner. `nil` when there is none.
    def queued_job
      return @queued_job if defined?(@queued_job)

      jobs = Sessions::LiveTurn.unfinished_turns(session)
        .reject { |job| AgentJobIntent.clone_only?(job) }
      classified = jobs.map { |job| [ job, JobLiveness.status(job) ] }
      @queued_job = (classified.find { |_job, st| st == :running } ||
                     classified.find { |_job, st| st == :queued })&.first
    end

    # @return [Symbol] :queued, :running, :none, or :unreadable
    def queued_job_status
      job = queued_job
      return :none if job.nil?

      JobLiveness.status(job)
    rescue StandardError => e
      Rails.logger.warn("[Sessions::ForceTurnStart] Could not read the agents queue for session " \
                        "#{session.id} (#{e.class}: #{e.message})")
      :unreadable
    end

    def queued_turn_ready?
      session.waiting? && !session.archived? && queued_job_status == :queued
    end

    # === Prose ================================================================

    # What the victim's timeline says. Leads with the cost, because the session
    # cannot report this itself — its process is already gone — and names who took
    # the thread, so a reader of this row never has to guess.
    def victim_message
      "[Forced] This turn was stopped to give its worker thread to session #{session.id}, which #{actor} " \
      "had been waiting on. Work already written to disk survives; the tool call in flight does not. " \
      "The turn was not cancelled — it went straight back into the agents queue and runs again as soon " \
      "as a thread frees up."
    end

    # What the forcing session's own timeline says. The same event from the other
    # side, and it names the victim for the same reason.
    def forced_message(victim)
      "Forced to the front of the agents queue by #{actor}. Session #{victim.id}'s turn was stopped to " \
      "free a worker thread; its turn was put back in the queue."
    end

    def success_message(victim)
      base = "Session #{victim.id}'s turn was stopped and put back in the queue, and session " \
             "#{session.id}'s turn is first in line for the thread it freed."
      return base unless session.spot?

      "#{base} It stays spot, so the gate is asked again when a worker picks it up — a quota window " \
      "still over its target holds it even now."
    end

    def session_id_of(job)
      job.serialized_params&.dig("arguments")&.first&.to_i
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end

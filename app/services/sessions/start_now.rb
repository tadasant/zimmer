# frozen_string_literal: true

module Sessions
  # "Start it now": take a waiting session's next turn immediately, instead of
  # whenever the scheduler next gets round to it.
  #
  # This is the operation behind the Ranked view's **Start** menu entry, and the
  # one a promote to priority performs on the row it just promoted. Both answer
  # the same complaint: the spot gate's hold message already promises that
  # "making this one session priority" starts it now, and until this existed it
  # did not. Promoting removed the *reason* the session was held and changed
  # nothing about *when* it would be asked again — the deferred re-check still
  # sat up to an hour out, so a session a human had just decided was urgent went
  # on waiting exactly as long as before.
  #
  # A waiting session is dormant in one of three shapes, and each has its own
  # door back in. This class is the one place that knows which is which.
  #
  # == Held at the starting line: pull the queued turn forward
  #
  # A held session is not a session with nothing scheduled. SpotSessionHold takes
  # custody of the refused turn and rides it on a delayed AgentSessionJob — with
  # its prompt, images and files attached — so the work is already queued, just
  # for later. Enqueuing a fresh job alongside it would create two jobs for one
  # session, and only the first is protected: AgentSessionJob's concurrency guard
  # stands a job down while `running_job_id` points at a LIVE job, so the
  # deferred one is dropped if it fires mid-turn — but it fires whenever it
  # likes, and a session that has already finished its turn and gone back to
  # `waiting` has no live job to stand it down. That second turn would run for
  # real, spending quota re-delivering a prompt.
  #
  # So the queued job is rescheduled to now, through GoodJob's own
  # `reschedule_job`, which takes the row's lock and refuses a finished job. One
  # job, one turn, the prompt intact.
  #
  # == Paused mid-run, or parked from "Pause Until → Spot Queue": resume it
  #
  # Those sessions have no queued job at all — the ceiling took their turn away
  # and the resume sweep is what gives it back, on a locked re-check that also
  # restores the prompt a human left with the park. Starting one is that same
  # resume, asked for by hand, so it goes through SpotSessionPause rather than
  # being reimplemented here. Clearing the pause record without resuming would be
  # the worst of both: it is the marker the sweep's population is keyed on, so
  # the session would drop out of the queue it is waiting in and never be
  # resumed by anything.
  #
  # == Neither: there is nothing to pull forward
  #
  # A session that has run before and has nothing scheduled is stranded rather
  # than queued, and no amount of rescheduling produces a turn for it. That is
  # reported as `nothing_queued` for the caller to decide on: the web UI nudges
  # it with the same continue prompt Refresh sends, a promote leaves it alone.
  #
  # == What it refuses
  #
  # A pause with a wake-up ARMED. That wake is the session's next event and it
  # carries its own prompt; starting the session underneath it would race the
  # two. AgentSessionJob refuses such a start on its own — this only says so
  # before the click rather than after it.
  class StartNow
    # `started`        - a turn is on its way now
    # `nothing_queued` - nothing is scheduled and the session has run before, so
    #                    there is no turn to pull forward
    # `refused`        - it cannot start; `message` says why
    Result = Data.define(:outcome, :message) do
      def started? = outcome == :started
      def refused? = outcome == :refused
      def nothing_queued? = outcome == :nothing_queued
    end

    # Jobs that spend a turn. `resume_monitoring` re-attaches to a process that
    # is already running and `clone_only` prepares a clone without spawning an
    # agent, so neither is the thing a human means by "start it".
    TURN_TAKING_CONDITIONS = [
      "COALESCE(serialized_params->'arguments'->2->>'resume_monitoring', 'false') = 'false'",
      "COALESCE(serialized_params->'arguments'->2->>'clone_only', 'false') = 'false'"
    ].freeze

    # @param session [Session]
    # @param actor [String] who asked, for the session's own log
    # @return [Result]
    def self.call(session, actor: "a user")
      new(session, actor: actor).call
    end

    def initialize(session, actor: "a user")
      @session = session
      @actor = actor
    end

    def call
      refusal = refusal_reason
      return Result.new(outcome: :refused, message: refusal) if refusal

      return resume_from_the_queue if SpotSessionPause.paused?(session)

      # The hold's re-check time is what the banner promises, and it is no longer
      # what starts this session. Dropping it also resets the backoff ladder,
      # which is what SpotSessionHold already says an explicit start should do.
      SpotSessionHold.clear(session)

      # A turn that is already due is a turn on its way, so it is left where it
      # is rather than being enqueued a second time. Only one that is scheduled
      # into the future is moved.
      queued = queued_turns.to_a
      if queued.any?
        pulled = pull_forward(queued)
        return started(pulled.positive? ? "its queued turn was pulled forward" : "its queued turn is already due")
      end

      # Nothing queued and nothing ever started: this session has no turn at all,
      # which is the one case where enqueuing is the right answer rather than a
      # duplicate.
      if session.session_id.blank?
        AgentSessionJob.enqueue_new_session(session.id)
        return started("its first turn was enqueued")
      end

      Result.new(
        outcome: :nothing_queued,
        message: "Nothing is queued for session #{session.id}, and it has run before."
      )
    end

    private

    attr_reader :session, :actor

    def refusal_reason
      return "Session #{session.id} is in the trash." if session.archived?
      unless session.waiting?
        return "Session #{session.id} is #{session.status} — only a waiting session can be started."
      end
      return nil unless session.paused_until_scheduled_time?

      "Session #{session.id} is paused: #{session.pending_wake_phrase}. " \
        "A pause outranks the queue, so cancel it to start this session now."
    rescue ActiveRecord::ActiveRecordError => e
      # `paused_until_scheduled_time?` deliberately does not rescue: a start path
      # that swallowed the error would claim a pause that may not exist. Refusing
      # is the safe direction — the button can be pressed again — and this is a
      # human waiting on an answer, not a sweep that can 500.
      Rails.logger.warn("[Sessions::StartNow] Could not read wake-ups for session #{session.id}: #{e.message}")
      "Could not read session #{session.id}'s pending wake-ups, so it was left alone. Try again."
    end

    def resume_from_the_queue
      if SpotSessionPause.resume_now!(session, actor: actor)
        Result.new(outcome: :started, message: "Session #{session.id} is starting now: resumed from the spot queue.")
      else
        Result.new(
          outcome: :refused,
          message: "Could not resume session #{session.id} from the spot queue — see its log."
        )
      end
    end

    # @return [Integer] how many of these queued turns were brought forward
    def pull_forward(jobs)
      now = Time.current
      jobs.count do |job|
        next false if job.scheduled_at.present? && job.scheduled_at <= now

        job.reschedule_job(now)
        true
      end
    rescue StandardError => e
      # A job that finished between the query and the reschedule is a turn that
      # is already under way, which is what was asked for; anything else leaves
      # the deferred re-check exactly where it was.
      Rails.logger.warn(
        "[Sessions::StartNow] Could not reschedule a queued turn for session #{session.id}: #{e.class}: #{e.message}"
      )
      0
    end

    def queued_turns
      TURN_TAKING_CONDITIONS.reduce(
        GoodJob::Job.where(finished_at: nil, performed_at: nil, job_class: "AgentSessionJob")
                    .where("serialized_params->'arguments'->0 = ?", session.id.to_json)
      ) { |scope, condition| scope.where(condition) }
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[Sessions::StartNow] Could not read queued turns for session #{session.id}: #{e.message}")
      GoodJob::Job.none
    end

    def started(how)
      message = "Session #{session.id} is starting now: #{how}."
      session.logs.create!(level: "info", content: "Started now by #{actor} — #{how}.")
      Result.new(outcome: :started, message: message)
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[Sessions::StartNow] Could not log the start of session #{session.id}: #{e.message}")
      Result.new(outcome: :started, message: message)
    end
  end
end

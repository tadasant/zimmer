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
  # One narrow gap is left, and named rather than papered over: a hold job that
  # is mid-execution is excluded by `performed_at: nil`, so a session whose only
  # queued turn is that job looks empty here. A session that has never run then
  # takes the enqueue branch and can end up with two. AgentSessionJob's
  # concurrency guard covers the overlap while the first job holds
  # `running_job_id`; nothing covers the case where it has already let go.
  #
  # Moving a turn is not the same as passing the gate. A spot session's turn
  # answers to SpotSessionHold whenever it runs, so this changes WHEN it is asked
  # and not WHETHER it is allowed — a window still over its target holds it
  # again, back at the bottom of the backoff ladder. The message says so rather
  # than claiming a start it cannot promise; promotion, which the hold banner
  # already points at, is what removes the gate.
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
  # == The first turn carries its attachments
  #
  # The one branch that builds a job out of nothing — a session that has never run
  # and has nothing queued — re-reads the session's images and files off the
  # durable volume (Sessions::FirstTurnAttachments) and puts them on the job.
  # AgentSessionJob reads attachments ONLY out of its job arguments, so enqueuing
  # without them started a session whose prompt was "here is the screenshot, fix
  # this" with the prompt and without the screenshot (#739). The other two
  # branches move a job that already carries its own, and must not re-read: that
  # would attach a second copy.
  #
  # The narrow duplicate-job gap named above rides along with it. A session that
  # takes this branch while a hold job is mid-execution can end up with two turns,
  # and both now carry the attachments — the second re-delivers the screenshot
  # rather than arriving bare. That is the existing gap costing slightly more, not
  # a new one: the fix for it is the same fix it always was.
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

      # A read that FAILED must not be mistaken for "nothing is queued": that is
      # the one confusion that produces the second turn this class exists to
      # prevent, and a held first-turn session — blank session_id, deferred job
      # pending — is precisely the shape it would hit.
      queued = queued_turns
      if queued.nil?
        return Result.new(
          outcome: :refused,
          message: "Could not read what is queued for session #{session.id}, so nothing was touched. Try again."
        )
      end

      # A turn that is already due is a turn on its way, so it is left where it
      # is rather than being enqueued a second time. Only one that is scheduled
      # into the future is moved.
      if queued.any?
        pulled, failed = pull_forward(queued)
        if failed
          return Result.new(
            outcome: :refused,
            message: "Could not bring session #{session.id}'s queued turn forward. It still runs at its scheduled time."
          )
        end

        return started(pulled.positive? ? "its queued turn was pulled forward" : "its queued turn is already due")
      end

      # Nothing queued and nothing ever started: this session has no turn at all,
      # which is the one case where enqueuing is the right answer rather than a
      # duplicate.
      if session.session_id.blank?
        images, files = first_turn_attachments
        AgentSessionJob.enqueue_new_session(session.id, images: images.presence, files: files.presence)
        return started("its first turn was enqueued#{attachment_phrase(images, files)}")
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

    # The attachments the first turn was created with, read back off disk.
    #
    # This branch is the only one that builds a job out of nothing. The other two
    # move a job that already exists, and a queued AgentSessionJob carries its own
    # `images:`/`files:` arguments — so re-reading storage for them would attach a
    # second copy of what is already on the turn.
    #
    # What Sessions::FirstTurnAttachments reads is "everything on disk, minus what
    # the queue owns" rather than a recorded list of the first turn's own
    # attachments — nothing records one. The two coincide here because this branch
    # is reached only when `session_id` is blank, which is what "has never run"
    # means everywhere in recovery, so no earlier turn can have consumed any of it.
    #
    # @return [Array(Array<Hash>, Array<Hash>)] images, files
    def first_turn_attachments
      Sessions::FirstTurnAttachments.for(session)
    end

    # What the session's log says the turn is carrying.
    def attachment_phrase(images, files)
      Sessions::FirstTurnAttachments.carrying_clause(images, files)
    end

    def resume_from_the_queue
      if SpotSessionPause.resume_now!(session, actor: actor)
        Result.new(outcome: :started, message: "Session #{session.id}'s next turn is due now: resumed from the spot queue.")
      else
        Result.new(
          outcome: :refused,
          message: "Could not resume session #{session.id} from the spot queue — see its log."
        )
      end
    end

    # Per job rather than around the loop: one job that finished between the read
    # and the write says nothing about the next one, and a rescue that spans the
    # whole loop would abandon the rest and still report a tidy zero.
    #
    # @return [Array(Integer, Boolean)] how many were brought forward, and whether
    #   anything failed for a reason other than "that turn is already under way"
    def pull_forward(jobs)
      now = Time.current
      pulled = 0

      jobs.each do |job|
        next if job.scheduled_at.present? && job.scheduled_at <= now

        begin
          job.reschedule_job(now)
          pulled += 1
        rescue GoodJob::Job::ActionForStateMismatchError
          # It finished while we were looking at it, which is the thing that was
          # asked for.
          next
        rescue StandardError => e
          Rails.logger.warn(
            "[Sessions::StartNow] Could not reschedule a queued turn for session #{session.id}: #{e.class}: #{e.message}"
          )
          return [ pulled, true ]
        end
      end

      [ pulled, false ]
    end

    # @return [Array<GoodJob::Job>, nil] nil when the queue could not be read —
    #   which is NOT the same answer as an empty list, and must not be treated
    #   as one
    def queued_turns
      TURN_TAKING_CONDITIONS.reduce(
        GoodJob::Job.where(finished_at: nil, performed_at: nil, job_class: "AgentSessionJob")
                    .where("serialized_params->'arguments'->0 = ?", session.id.to_json)
      ) { |scope, condition| scope.where(condition) }.to_a
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[Sessions::StartNow] Could not read queued turns for session #{session.id}: #{e.message}")
      nil
    end

    # Only once a turn is actually on its way. Clearing the hold on a session
    # that turned out to have nothing queued would strip the banner explaining
    # why it is dormant and put nothing in its place.
    #
    # Dropping HELD_COUNT with it resets the backoff ladder, which is what
    # SpotSessionHold says an explicit request to start should do — the same
    # reset the Restart button gets.
    def started(how)
      message = start_message(how)
      SpotSessionHold.clear(session)
      session.logs.create!(level: "info", content: "Started now by #{actor} — #{how}.")
      Result.new(outcome: :started, message: message)
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[Sessions::StartNow] Could not finish starting session #{session.id}: #{e.message}")
      Result.new(outcome: :started, message: message)
    end

    # A spot session's turn answers to the gate whenever it runs, and this moves
    # WHEN it is asked, not WHETHER it is allowed. Saying "starting now" to a
    # queue of sessions the gate is holding would be a row of buttons that each
    # claim a start and deliver a re-check — so a spot row is told what it
    # actually got. A promote reaches this having already made the session
    # priority, so it gets the plain sentence.
    def start_message(how)
      base = "Session #{session.id}'s next turn is due now: #{how}."
      return base unless session.spot?

      "#{base} It stays spot, so the gate decides whether it runs — a window still over its target holds it again."
    end
  end
end

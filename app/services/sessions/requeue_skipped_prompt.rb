# frozen_string_literal: true

module Sessions
  # A job carrying a prompt lost the concurrency guard in `AgentSessionJob#perform`,
  # so its turn will never run. Put the prompt back in the session's durable queue
  # instead of dropping it on the floor.
  #
  # ## The hole this closes (#983)
  #
  # `EnqueuedMessageProcessorService#process_next_message` destroys the
  # `enqueued_messages` row inside the same transaction that enqueues the
  # `AgentSessionJob` carrying its content. From that moment the prompt exists only
  # as that job's argument — the row is gone, and this path deliberately does not
  # route through `Session#deliver_follow_up!`, so `pending_follow_up_prompt` is
  # never stamped either. Every other delivery route has the same property once the
  # job is enqueued: the prompt is a job argument and nothing else.
  #
  # If that job then reaches the guard and finds a genuinely live job holding the
  # session, the guard did exactly what it was designed to do — and the prompt was
  # still lost. The else-branch was a bare `return`: nothing re-queued it, nothing
  # retried it, and nothing recorded that it had ever existed. Session 13229 lost a
  # `wake_me_up_later` prompt this way on 2026-09-05 and only resumed eight minutes
  # later on a generic recovery nudge, with the scheduled work never done.
  #
  # It is wider than wake-ups. Any prompt reaching the guard is droppable the same
  # way: a human's follow-up typed into the web UI, a poller's PR-merged notice, a
  # fired trigger. The guard's own comment already names the failure mode ("the
  # user's follow-up prompt is dropped with no feedback") for the case where a dead
  # job is misread as live. This is the other case, where the recorded job really
  # was alive.
  #
  # ## Late rather than lost
  #
  # The queue is the right place because the holder of the session is, by
  # construction, a live turn — and a live turn drains the queue when it ends. Three
  # independent routes deliver the row afterwards: the pre-pause handoff in
  # `AgentSessionJob`, `drain_enqueued_messages_after_pause` on the `pause`
  # transition, and `EnqueuedMessage#deliver_if_session_already_idle` for the race
  # where the holder came to rest between the guard's read and this write.
  #
  # This does NOT retry the job. Re-enqueuing the same job would either lose the
  # same race again or, if it won, run a second agent process against one clone —
  # the failure the guard exists to prevent. The queue delivers exactly one turn,
  # after the one already running.
  #
  # ## The four prompts it deliberately does not queue
  #
  # Each of these would be queued into an outcome worse than the drop:
  #
  # 1. **A nudge** (`AutomatedPrompts.nudge?`) — `SYSTEM_RECOVERY` and `HEARTBEAT`.
  #    Both ask "are you alive, carry on if you were mid-task". The live job the
  #    guard just found IS the answer, so queuing it buys a barge: the holder ends
  #    its turn, comes to rest, and is immediately woken by a question already
  #    answered. `AgentSessionJob` makes the same judgement two guards later, where
  #    a queued message outranks a recovery nudge the job is carrying (#566).
  # 2. **An archived session's prompt.** `archive` retires the pending queue at the
  #    transition, so a row written afterwards is one nothing will ever deliver —
  #    and a `caller` row stranded on an archived session is precisely what the
  #    archive-strand alert pages on. `#refuse_archived_session` would have refused
  #    this turn a few lines further down anyway.
  # 3. **A status-summary fork's NON-summary prompt.** A fork answers one question
  #    and refuses every other turn (`#refuse_non_summary_fork_turn`), and it must
  #    never take a slot in the action queue or page anyone — the same carve-out
  #    `SessionStateMachine`'s `pause` callback makes. The summary request itself is
  #    exempted here just as that guard exempts it, so the one turn a fork may take
  #    is queued rather than dropped.
  # 4. **A prompt already sitting in the queue verbatim.** Two jobs carrying one
  #    prompt is a real shape here — a trigger that queued a row and a delivery job
  #    that raced it — and a second copy costs the session a duplicate turn. The
  #    same coalesce `Trigger#follow_up_session!` makes on its own `running?` branch.
  #    Best-effort rather than a guarantee: two skipped jobs carrying one prompt can
  #    both read an empty queue before either writes, and a caller who deliberately
  #    sends the same text twice has the second copy coalesced into the first. Both
  #    outcomes are logged, so neither is silent.
  #
  # Every one of those is LOGGED on the session's own timeline rather than passed
  # over, because "why did nothing happen to this session" is asked from there.
  # Silence is the defect being fixed; a drop that is written down is not this bug.
  class RequeueSkippedPrompt
    # Cap on the prompt echoed into the session's timeline when the prompt IS
    # queued. Short on purpose: the log line only has to identify which prompt was
    # saved, and the queue row next to it holds the whole thing. Matches the cap the
    # job's other refusal paths use.
    PROMPT_LOG_MAX_CHARS = AgentSessionJob::REFUSED_PROMPT_LOG_MAX_CHARS

    # Cap used when the prompt was NOT queued. Generous, because in that case this
    # log line is the only surviving copy and a human re-sends it by hand — the same
    # reasoning, and the same number, as Sessions::ParkUndeliveredTurn.
    UNDELIVERED_PROMPT_LOG_MAX_CHARS = 4_000

    # @param session [Session] the session whose turn was skipped
    # @param prompt [String, nil] the prompt the skipped job was carrying
    # @param holder_job_id [String, nil] the `running_job_id` the guard deferred to
    # @param images [Array, nil] attachments the skipped job was carrying
    # @param files [Array, nil] attachments the skipped job was carrying
    # @param log_buffer [LogBuffer, nil] the caller's buffer, so the disposition
    #   lands on the session's timeline next to the "Skipping job" line it explains
    # @return [Symbol] what happened — :queued, :no_prompt, :nudge, :archived,
    #   :summary_fork, :already_queued or :failed
    def self.call(session, **kwargs)
      new(session, **kwargs).call
    end

    def initialize(session, prompt:, holder_job_id: nil, images: nil, files: nil, log_buffer: nil)
      @session = session
      @prompt = prompt
      @holder_job_id = holder_job_id
      @images = images
      @files = files
      @log_buffer = log_buffer
    end

    def call
      return :no_prompt if @prompt.blank?

      reason = refusal_reason
      return refuse(reason) if reason

      position = queue!
      release_pending_marker
      add_log(
        "The prompt this job was carrying was NOT lost: it is queued at position #{position} and is " \
        "delivered when job #{@holder_job_id || "the one holding this session"} ends its turn. " \
        "#{quoted_prompt(PROMPT_LOG_MAX_CHARS)}",
        level: "warning"
      )
      Rails.logger.warn(
        "[Sessions::RequeueSkippedPrompt] Session #{@session.id} queued a prompt at position #{position} " \
        "after its job was skipped by the concurrency guard (holder=#{@holder_job_id.inspect})"
      )
      broadcast_queue
      :queued
    rescue => e
      # Never let the requeue become the thing that breaks the guard. The prompt is
      # lost either way at this point, so the one thing that must still happen is
      # that the loss is written down.
      Rails.logger.error(
        "[Sessions::RequeueSkippedPrompt] Could not queue the skipped prompt for session " \
        "#{@session&.id}: #{e.class}: #{e.message}"
      )
      add_log(
        "The prompt this job was carrying could NOT be queued (#{e.class}: #{e.message}) and was not " \
        "delivered. #{quoted_prompt}",
        level: "error"
      )
      :failed
    end

    private

    # Which of the four carve-outs applies, or nil to queue. Ordered cheapest and
    # most decisive first: a nudge is refused whatever state the session is in.
    def refusal_reason
      return :nudge if AutomatedPrompts.nudge?(@prompt)

      # Re-read the row before deciding from it: the guard read a `session` the job
      # has been carrying, and archive/fork are facts about the row now.
      @session.reload
      return :archived if @session.archived?
      # Exempt the one prompt a fork IS allowed to take, exactly as
      # AgentSessionJob#refuse_non_summary_fork_turn exempts it. Without this the
      # carve-out would be wider than the guard it mirrors, and a re-delivered
      # summary request would be dropped rather than queued.
      if @session.status_summary_fork? && !SessionStatusSummaryGenerator.fork_prompt?(@prompt)
        return :summary_fork
      end
      return :already_queued if @session.enqueued_messages.pending.exists?(content: @prompt)

      nil
    end

    def refuse(reason)
      message, level = refusal_log(reason)
      add_log(message, level: level)
      Rails.logger.info(
        "[Sessions::RequeueSkippedPrompt] Session #{@session.id} did not queue the skipped prompt (#{reason})"
      )
      reason
    end

    def refusal_log(reason)
      case reason
      when :nudge
        [ "The prompt this job was carrying was an automated nudge asking whether this session is still " \
          "working. The live turn already holding the session is the answer, so the nudge is dropped " \
          "rather than queued behind it.", "info" ]
      when :archived
        [ "The prompt this job was carrying was not delivered and was not queued: this session is in the " \
          "trash, and nothing delivers a queued message to an archived session. #{quoted_prompt}",
          "warning" ]
      when :summary_fork
        [ "The prompt this job was carrying was not queued: this is a status-summary fork, which takes " \
          "exactly one turn and must not appear in the action queue. #{quoted_prompt}", "info" ]
      when :already_queued
        [ "The prompt this job was carrying is already queued on this session, so it was not queued a " \
          "second time — it is delivered once, when the turn holding the session ends.", "info" ]
      end
    end

    # How many times a lost position race is re-tried before the prompt is given up
    # on. `max(position) + 1` is read outside any lock — the same shape the two other
    # writers of this queue use — so two guard-skipped jobs landing together, or a
    # race with the renumbering loop in EnqueuedMessageProcessorService, can both
    # compute the same number and lose the deferred `(session_id, position)`
    # constraint. That is exactly the concurrency this code lives in, and losing the
    # prompt to it would reproduce the bug being fixed one layer down. Recomputing
    # and retrying resolves it: the loser reads the winner's row and takes the next
    # slot.
    QUEUE_WRITE_ATTEMPTS = 3

    # Tail of the queue: the turn already running is ahead of this prompt, and so is
    # anything queued before it. Same shape SpotSessionHold writes.
    def queue!
      attempts = 0
      begin
        attempts += 1
        create_at_tail!
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < QUEUE_WRITE_ATTEMPTS
        raise
      end
    end

    def create_at_tail!
      position = (@session.enqueued_messages.maximum(:position) || 0) + 1
      @session.enqueued_messages.create!(
        content: @prompt,
        position: position,
        status: "pending",
        images: Array(Sessions::AttachmentDescriptors.for_the_record(
          @images, keys: Sessions::AttachmentDescriptors::IMAGE_KEYS
        )),
        files: Array(Sessions::AttachmentDescriptors.for_the_record(
          @files, keys: Sessions::AttachmentDescriptors::FILE_KEYS
        )),
        origin: EnqueuedMessage.origin_for_prompt(@prompt)
      )
      position
    end

    # @param max_chars [Integer] PROMPT_LOG_MAX_CHARS when the prompt survives in the
    #   queue, UNDELIVERED_PROMPT_LOG_MAX_CHARS when this line is the only copy left.
    def quoted_prompt(max_chars = UNDELIVERED_PROMPT_LOG_MAX_CHARS)
      "The prompt was: #{@prompt.to_s.truncate(max_chars)}"
    end

    # The queue now owns this prompt, so the session must stop holding it too.
    #
    # `pending_follow_up_prompt` means "a prompt was accepted for a job that has not
    # picked it up yet", and every route that accepts a follow-up into an idle
    # session stamps it (#1023). The job that was just skipped is that job, so once
    # its prompt is in the durable queue the marker names a delivery that is now
    # somebody else's — and two live copies is two turns: the queue drains one, and
    # the next recovery resume reads the marker and delivers the other.
    #
    # Only when the marker holds THIS prompt. A different value belongs to a
    # different, still-undelivered turn, and dropping it would be the loss this
    # class exists to prevent, arriving from the inside.
    #
    # Best-effort: the prompt is already durable in the queue, so a failure here
    # costs at worst a duplicate turn — never a lost one.
    def release_pending_marker
      return unless @session.metadata&.dig("pending_follow_up_prompt") == @prompt

      @session.remove_metadata!(%w[pending_follow_up_prompt pending_follow_up_sent_at])
    rescue => e
      Rails.logger.warn(
        "[Sessions::RequeueSkippedPrompt] Could not release the pending marker for session " \
        "#{@session.id}: #{e.message}"
      )
    end

    # Push the new row to the session page's queue panel, the way every other
    # writer of this queue does. Without it the parked prompt is there but invisible
    # until something else redraws — and invisibility is the defect being fixed.
    # Isolated from the answer: a broadcast that fails must not turn a prompt that
    # was saved into one reported as lost.
    def broadcast_queue
      BroadcastService.new.enqueued_messages_list(@session)
    rescue => e
      Rails.logger.warn(
        "[Sessions::RequeueSkippedPrompt] Could not broadcast the queue for session #{@session.id}: #{e.message}"
      )
    end

    def add_log(content, level:)
      if @log_buffer
        @log_buffer.add(content, level: level)
      else
        @session.logs.create!(content: content, level: level)
      end
    rescue => e
      Rails.logger.warn("[Sessions::RequeueSkippedPrompt] Could not log the disposition: #{e.message}")
    end
  end
end

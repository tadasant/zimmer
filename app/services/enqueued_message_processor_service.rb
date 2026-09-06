# Service for processing enqueued messages for a session
#
# This service is responsible for:
# - Retiring queued notices whose reason for existing expired while they sat in
#   the queue (EnqueuedMessage#stale?)
# - Atomically claiming the next pending enqueued message
# - Updating session's goal if the message carries a non-blank one (blank/nil preserves session goal)
# - Resetting SIGTERM retry state for fresh execution
# - Transitioning the session back to running
# - Enqueuing a new job with the message content
#
# Race condition prevention:
# - Uses FOR UPDATE SKIP LOCKED in session.process_next_enqueued_message! to atomically claim messages
# - Session row is locked to prevent concurrent state transitions
# - Message content is captured before deletion to ensure job enqueuing succeeds
#
# Usage:
#   service = EnqueuedMessageProcessorService.new(session, log_buffer: log_buffer)
#   if service.process_next_message
#     # A new job was enqueued to process the message
#   end
class EnqueuedMessageProcessorService
  include DatabaseRetry

  # How long the whole staleness sweep may spend re-reading GitHub, across all
  # of a session's queued notices.
  #
  # The reader's own bound (Github::PrSnapshot::TIMEOUT) covers ONE `gh` child;
  # this bounds the loop, which a session with several conflicting PRs would
  # otherwise multiply out. Past the deadline the remaining notices are treated
  # as not stale and delivered — the same fail-open answer an unreadable PR gets.
  STALENESS_SWEEP_BUDGET_SECONDS = 25

  attr_reader :session, :log_buffer, :broadcast_service

  # @param revalidate [Boolean] whether to re-read poller notices against GitHub
  #   before claiming one — see #drop_stale_messages. Pass false from a caller
  #   that has already decided WHICH row to deliver: Sessions::InterruptService
  #   promotes a specific message to the front and reports on that message by
  #   name, so a sweep that retired it under the service's feet would make it
  #   deliver one message and claim it had delivered another.
  def initialize(session, log_buffer: nil, broadcast_service: nil, revalidate: true)
    @session = session
    @log_buffer = log_buffer
    @broadcast_service = broadcast_service
    @revalidate = revalidate
  end

  # Process the next enqueued message if available
  #
  # Callable from two paths:
  # - Post-pause (default): the AgentSessionJob has already paused the session,
  #   so it is in needs_input. The service claims the message and resumes the
  #   session back to running.
  # - Pre-pause (handoff): the AgentSessionJob is still running but the Claude
  #   CLI process has just exited. Calling here BEFORE pause! avoids a transient
  #   running → needs_input → running flap that fires ao_event watchers and
  #   other one-shot subscribers spuriously. When the session is already
  #   running, no resume! is needed — the session simply stays running while
  #   the next AgentSessionJob takes over.
  #
  # If there are pending enqueued messages, it will:
  # 1. Atomically claim the next message using FOR UPDATE SKIP LOCKED
  # 2. Update the session's goal if the message carries a non-blank one
  # 3. Reset SIGTERM retry state for fresh execution
  # 4. Resume the session — into `waiting`, where a session whose turn is queued
  #    for a worker belongs (the handoff branch writes that state directly)
  # 5. Delete the message and enqueue a new job with the message content
  #
  # @return [Boolean] true if a message was processed, false otherwise
  def process_next_message
    drop_stale_messages

    message = nil
    message_content = nil

    begin
      ActiveRecord::Base.transaction do
        # Reload first to clear any dirty state from AASM's update_all persistence
        # (AASM with skip_validation_on_save uses update_all which doesn't clear dirty tracking)
        session.reload
        # Lock session row to prevent race conditions with concurrent jobs
        session.lock!

        # Process if the session is needs_input (post-pause path), running
        # (pre-pause handoff path — see method comment), or waiting (the interrupt
        # path on a not-yet-started session — Sessions::InterruptService — and the
        # ordinary rest state of a session whose turn is queued). `may_resume?` is
        # true for `needs_input` and `waiting`; the `running` case is the handoff
        # branch below, which returns the session to `waiting` itself.
        return false unless session.needs_input? || session.running? || session.waiting?

        # Track whether we're entering via the handoff path (running already).
        # If so, no pause! → resume! cycle happens, so the cleanup_running_job
        # (after pause!) and reset_elapsed_time_counter (after resume!) callbacks
        # never fire. We have to apply their effects — and the return to
        # `waiting` — manually below to avoid:
        # - Orphaning the new AgentSessionJob: without clearing running_job_id,
        #   the new job sees the old (still-finishing) job as the lock holder
        #   and skips itself via the concurrency guard in AgentSessionJob#perform.
        # - Stale UI elapsed-time: without resetting last_timeline_entry_at,
        #   the "time since" indicator keeps counting from the previous turn.
        handoff_from_running = session.running?

        # Atomically claim the next pending enqueued message
        # process_next_enqueued_message! uses FOR UPDATE SKIP LOCKED to prevent
        # race conditions where multiple workers grab the same message
        message = session.process_next_enqueued_message!
        return false unless message

        # Capture message content before any modifications
        # This ensures we have the content even if something goes wrong later
        message_content = message.content
        message_position = message.position
        # Capture attachments before deletion. Both columns default to [].
        message_images = Sessions::AttachmentDescriptors.for_a_job(
          message.images, keys: Sessions::AttachmentDescriptors::IMAGE_KEYS
        )
        message_files = Sessions::AttachmentDescriptors.for_a_job(
          message.files, keys: Sessions::AttachmentDescriptors::FILE_KEYS
        )

        add_log(
          "Processing enqueued message at position #{message_position}",
          level: "info"
        )

        # Only overwrite the session's goal when the enqueued message explicitly
        # carries one. A message with no goal is not a "clear" signal —
        # preserving the session's existing goal avoids surprise clearing when
        # a follow-up enqueued without a goal is processed. To explicitly clear,
        # update the session goal via PATCH /api/v1/sessions/:id.
        if message.goal.present? && message.goal != session.goal
          session.update!(goal: message.goal)
          add_log(
            "Goal updated from enqueued message",
            level: "info"
          )
        end

        # Reset SIGTERM retry state for fresh execution
        if session.metadata&.dig("sigterm_retry_count").present?
          session.remove_metadata!(%w[
            sigterm_retry_count
            sigterm_retry_timestamps
            last_sigterm_at
          ])
        end

        # Transition session back to running (no-op when already running via handoff).
        # When may_resume? is true (post-pause path), the after-callbacks fire and clean
        # up running_job_id (cleanup_running_job from the prior pause) and reset the
        # elapsed-time counter. When may_resume? is false (handoff path), apply those
        # effects manually below.
        #
        # A follow-up resume, not a plain one: the message being delivered came
        # from somewhere other than this session's own wait — a router's queued
        # `follow_up`, a human's message typed while the agent was busy — so the
        # session's pending wake-ups survive it (#898). Delivery through the queue
        # is the SAME event as a direct follow-up; only the timing differs.
        session.resume_for_follow_up!

        if handoff_from_running
          # Handoff path: clear the outgoing job's lock, refresh the elapsed-time
          # counter for the new turn, and put the session back in `waiting`.
          #
          # `waiting` because that is what is true from here until a worker picks
          # the job up below: the outgoing turn's process has exited and the next
          # turn is a row in the `agents` queue. Leaving it `running` across this
          # window is the handoff half of #1036 — and it is not a short window on a
          # busy deployment, because the new job joins the BACK of a queue that may
          # already be deeper than the pool.
          #
          # `update!` rather than `update_columns` for exactly that reason: the
          # status really changed, so the card has to re-broadcast. It is a direct
          # write rather than an AASM event because `resume` is refused from
          # `running` on purpose (see Session#claim_system_recovery_turn!), and
          # SpotSessionHold#return_to_queue! already returns a running session to
          # the queue the same way.
          session.update!(
            status: :waiting,
            running_job_id: nil,
            last_timeline_entry_at: Time.current
          )
        end

        # Log the message being sent
        truncated_content = message_content.length > 200 ? "#{message_content[0..197]}..." : message_content
        add_log(
          "Sending enqueued message: #{truncated_content}",
          level: "info"
        )

        # Mark message as sent and delete it
        message.mark_as_sent!
        message.destroy!

        # Re-number remaining messages with higher positions
        # Update in order from lowest to highest position to avoid unique constraint violations
        # (e.g., position 2 -> 1 must happen before position 3 -> 2)
        session.enqueued_messages
               .where("position > ?", message_position)
               .order(position: :asc)
               .each { |m| m.update!(position: m.position - 1) }

        # A prompt the session is STILL HOLDING must not swallow the one we just
        # claimed. `AgentSessionJob`'s follow-up arm resolves this turn's prompt as
        # `pending_follow_up_prompt || follow_up_prompt`, so a marker standing here
        # would win over `message_content` — and the row that carried
        # `message_content` has just been destroyed, so it would be gone. See
        # #displace_pending_follow_up_prompt.
        displace_pending_follow_up_prompt(message_content)

        # Enqueue job to continue the session with the captured message content.
        # Attachments stored on the EnqueuedMessage ride along so queued messages
        # deliver images/files exactly the same way as immediate follow-ups.
        AgentSessionJob.enqueue_with_prompt(
          session.id,
          message_content,
          images: message_images,
          files: message_files
        )
      end

      flush_log_buffer

      # Broadcast updated enqueued messages list to UI
      broadcast_service&.enqueued_messages_list(session)

      true
    rescue => e
      Rails.logger.error "[EnqueuedMessageProcessorService] Error processing enqueued message: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
      add_log(
        "Failed to process enqueued message: #{e.message}",
        level: "error"
      )
      flush_log_buffer
      false
    end
  end

  private

  # Get the session's held follow-up out of the way of the message we just claimed,
  # without losing either of them.
  #
  # `pending_follow_up_prompt` means "a prompt was accepted for a job that has not
  # picked it up yet", and every route that accepts a follow-up into an idle
  # session stamps it (tadasant/zimmer#1023). It is read in preference to a job's
  # own argument, which is what makes it work for a resume carrying a nudge — and
  # what makes it dangerous here: the message this service claimed exists only as
  # the argument of the job below, its queue row having been destroyed a few lines
  # up, so a marker left standing would be delivered *instead* and the claimed
  # message would be gone with no record of it. Two undelivered prompts, one turn,
  # one survivor.
  #
  # Both survive instead. The held prompt goes to the tail of the queue and drains
  # at the end of the turn the claimed message is about to take, in the order they
  # were accepted; the marker is released either way, because the queue now owns
  # it. Three cases collapse to just releasing it:
  #
  # - **It IS the claimed message.** The queue row was this same prompt (the guard
  #   path in `AgentSessionJob` requeues a skipped job's prompt verbatim), so
  #   re-queuing would give the session the same turn twice.
  # - **A copy is already queued.** Same coalesce, one step wider.
  # - **It is a nudge.** "You may have been interrupted, carry on" has nothing to
  #   add to a real message that is about to be delivered — the same judgement
  #   `Sessions::RequeueSkippedPrompt` and `AgentSessionJob#queued_message_took_over?`
  #   both make.
  #
  # The queue write and the release are ONE savepoint, and that is the whole of
  # what makes this safe. A half-applied pair is worse than either outcome on its
  # own: a row written and the marker left standing gives the session two live
  # copies, so the job below delivers the held prompt (the marker outranks
  # `message_content`) and the queue drains it a second time at the end of the
  # turn — the claimed message lost AND the held one doubled, which is both of the
  # failures this PR exists to close, at once. Rolling the pair back leaves the
  # pre-existing behaviour instead: the marker stands and swallows the claimed
  # message, with the rescue's log line to say so.
  #
  # The rescue cannot see a position collision, and that is fine rather than a
  # gap: the `(session_id, position)` unique constraint is DEFERRABLE INITIALLY
  # DEFERRED, so a race with another writer of this queue surfaces at COMMIT of the
  # outer transaction, which rolls the whole claim back. The message stays
  # `pending` and is redelivered — late, not lost.
  #
  # @param message_content [String] the message this turn is about to deliver
  # @return [void]
  def displace_pending_follow_up_prompt(message_content)
    held = session.metadata&.dig("pending_follow_up_prompt").presence
    return if held.blank?

    ActiveRecord::Base.transaction(requires_new: true) do
      if held != message_content && !AutomatedPrompts.nudge?(held) &&
         !session.enqueued_messages.pending.exists?(content: held)
        position = (session.enqueued_messages.maximum(:position) || 0) + 1
        session.enqueued_messages.create!(
          content: held,
          position: position,
          status: "pending",
          origin: EnqueuedMessage.origin_for_prompt(held)
        )
        add_log(
          "This session was also holding an undelivered follow-up prompt, which would have been " \
          "delivered in place of the message above. It is queued at position #{position} instead, so " \
          "both are delivered — this one now, that one at the end of this turn.",
          level: "warning"
        )
      end

      session.remove_metadata!(%w[pending_follow_up_prompt pending_follow_up_sent_at])
    end
  rescue => e
    Rails.logger.error(
      "[EnqueuedMessageProcessorService] Could not displace the held follow-up prompt for session " \
      "#{session.id}: #{e.class}: #{e.message}"
    )
    add_log(
      "This session is holding an undelivered follow-up prompt that could not be moved aside " \
      "(#{e.class}: #{e.message}). The turn starting now may deliver it in place of the queued " \
      "message above.",
      level: "error"
    )
  end

  # Retire queued notices whose reason for existing has expired, before claiming
  # one to deliver. This is the point the check has to live at: the poller that
  # wrote the notice enqueued it because the session was mid-turn or asleep, and
  # the row then sat here until this turn boundary — minutes in which the state
  # it reports can have moved on (tadasant/zimmer#835). See
  # EnqueuedMessage#stale? for what "moved on" means and why it fails open.
  #
  # Scoped to `staleness_checked` so the cost is bounded to the origins that
  # actually have something to re-read: an ordinary `caller` message is somebody
  # waiting on delivery, and nothing about it can go out of date.
  #
  # Runs BEFORE the transaction below, deliberately. EnqueuedMessage#stale?
  # shells out to GitHub, and a network round trip should not be held inside a
  # transaction that also holds this session's row lock — every poller that
  # wants to enqueue against this session takes the same lock.
  #
  # No caller reaches this inside a transaction of its own. The one that runs
  # everything under Session.with_session_lock, Sessions::InterruptService,
  # passes `revalidate: false` — so the sweep and the outer transaction are
  # mutually exclusive rather than nested, and the read is bounded twice over
  # (per call and per sweep) for the paths that do run it.
  def drop_stale_messages
    return unless @revalidate
    # Mirrors the state gate inside the transaction below. A session in any other
    # state cannot be handed a message however the sweep goes, so paying for a
    # `gh` round trip — and retiring a notice that was never going to be claimed
    # — would be work done for nothing.
    return unless session.needs_input? || session.running? || session.waiting?

    candidates = session.enqueued_messages.pending.staleness_checked.ordered.to_a
    return if candidates.empty?

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STALENESS_SWEEP_BUDGET_SECONDS
    retired = candidates.select { |message| stale_within_budget?(message, deadline) && message.retire_as_stale! }
    return if retired.empty?

    retired.each do |message|
      add_log(
        "Queued #{message.origin} message at position #{message.position} was not delivered: the state it " \
        "reports has moved on since the poller saw it, so it is retired undelivered rather than costing " \
        "the session a turn",
        level: "info"
      )
    end
    flush_log_buffer
    broadcast_service&.enqueued_messages_list(session)
  end

  # The fail-open boundary, kept as narrow as the thing that can fail.
  #
  # Only the GitHub read is wrapped: an unreadable PR must not cost the session
  # its message, which is the same posture EnqueuedMessage#stale? takes
  # internally. A failure in the retirement or the logging that follows is NOT
  # swallowed here — a blanket rescue around the whole sweep would report
  # "delivering the queue unchanged" after a retirement had already committed,
  # and would hide a database error rather than let the caller's own handling
  # see it.
  def stale_within_budget?(message, deadline)
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      Rails.logger.warn(
        "[EnqueuedMessageProcessorService] Staleness sweep for session #{session.id} ran past its " \
        "#{STALENESS_SWEEP_BUDGET_SECONDS}s budget — delivering message #{message.id} unchecked"
      )
      return false
    end

    message.stale?
  rescue => e
    Rails.logger.error(
      "[EnqueuedMessageProcessorService] Could not re-read the state behind message #{message.id} for " \
      "session #{session.id} (#{e.class}: #{e.message}) — delivering it unchanged"
    )
    false
  end

  # Add log entry to session
  # Uses log_buffer if available, otherwise creates log directly
  def add_log(content, level: "info")
    if log_buffer
      log_buffer.add(content, level: level)
    else
      with_db_retry do
        session.logs.create!(content: content, level: level)
      end
    end
  end

  # Flush log buffer if available
  def flush_log_buffer
    log_buffer&.flush
  end
end

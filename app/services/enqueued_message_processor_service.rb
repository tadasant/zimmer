# Service for processing enqueued messages for a session
#
# This service is responsible for:
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

  attr_reader :session, :log_buffer, :broadcast_service

  def initialize(session, log_buffer: nil, broadcast_service: nil)
    @session = session
    @log_buffer = log_buffer
    @broadcast_service = broadcast_service
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
  # 4. Resume the session back to running (only if it was needs_input)
  # 5. Delete the message and enqueue a new job with the message content
  #
  # @return [Boolean] true if a message was processed, false otherwise
  def process_next_message
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
        # (pre-pause handoff path — see method comment), or waiting (interrupt
        # path on a not-yet-started session — Sessions::InterruptService). All
        # three are accepted because session.may_resume? returns true for
        # each (resume transitions waiting/needs_input/failed → running).
        return false unless session.needs_input? || session.running? || session.waiting?

        # Track whether we're entering via the handoff path (running already).
        # If so, no pause! → resume! cycle happens, so the cleanup_running_job
        # (after pause!) and reset_elapsed_time_counter (after resume!) callbacks
        # never fire. We have to apply their effects manually below to avoid:
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
        message_images = symbolize_attachments(message.images, %i[path media_type])
        message_files = symbolize_attachments(message.files, %i[path original_filename size])

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
          session.update!(
            metadata: (session.metadata || {}).except(
              "sigterm_retry_count",
              "sigterm_retry_timestamps",
              "last_sigterm_at"
            )
          )
        end

        # Transition session back to running (no-op when already running via handoff).
        # When may_resume? is true (post-pause path), the after-callbacks fire and clean
        # up running_job_id (cleanup_running_job from the prior pause) and reset the
        # elapsed-time counter. When may_resume? is false (handoff path), apply those
        # effects manually below.
        session.resume! if session.may_resume?

        if handoff_from_running
          # Handoff path: clear the outgoing job's lock and refresh the
          # elapsed-time counter for the new turn. Use update_columns to avoid
          # firing model callbacks (which would re-broadcast status, etc.).
          session.update_columns(
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

  # Convert jsonb-stored attachment hashes (string keys) into the symbol-keyed
  # form AgentSessionJob.enqueue_with_prompt expects.
  def symbolize_attachments(raw, keys)
    return nil if raw.blank?

    Array(raw).filter_map do |entry|
      next unless entry.is_a?(Hash) || entry.is_a?(ActionController::Parameters)
      symbolized = keys.each_with_object({}) do |key, acc|
        value = entry[key.to_s] || entry[key]
        acc[key] = value unless value.nil?
      end
      symbolized.presence
    end.presence
  end
end

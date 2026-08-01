# frozen_string_literal: true

require "aasm"

# SessionStateMachine manages the lifecycle states and transitions for agent sessions.
# It uses AASM (Acts As State Machine) to enforce valid state transitions and prevent
# invalid state changes that could lead to data corruption or orphaned processes.
#
# State Definitions:
# - waiting: Initial state, session is queued but not yet running
# - running: Agent is actively executing
# - needs_input: Agent has paused and is waiting for user input (follow-up prompt)
# - failed: Session encountered an error and cannot proceed
# - archived: Session has been archived by user (terminal state)
#
# Valid Transitions:
# - start: waiting -> running (when job begins execution and process is spawned)
# - sleep: needs_input -> waiting (when session defers work for later wake-up)
# - pause: running -> needs_input (when agent completes a turn)
# - resume: needs_input -> running (when follow-up prompt is sent)
# - fail: waiting/running/needs_input -> failed (when error occurs)
# - archive: needs_input/failed -> archived (when user archives session)
#
# Guards and Callbacks:
# - Guards prevent transitions when preconditions aren't met
# - Callbacks handle side effects like logging and cleanup
#
module SessionStateMachine
  extend ActiveSupport::Concern

  included do
    include AASM

    # Map AASM states to the existing ActiveRecord enum
    # Order must match the existing database integer values:
    # 0=running, 1=waiting, 2=needs_input, 3=archived, 4=failed
    # NOTE: corrupted (5) was removed - sessions now transition to failed instead
    aasm column: :status, enum: true do
      state :running         # 0
      state :waiting, initial: true  # 1
      state :needs_input     # 2
      state :archived        # 3
      state :failed          # 4

      # Start execution from waiting state
      event :start do
        transitions from: :waiting, to: :running, guard: :can_start?
        after do
          reset_elapsed_time_counter
          log_state_change("Session started")
        end
      end

      # Sleep: defer work for later, transitioning to dormant waiting state.
      # Used by the "wake me up later" workflow — the session becomes dormant
      # and a one-time schedule trigger will resume it at the specified time.
      event :sleep do
        transitions from: :needs_input, to: :waiting
        after do
          log_state_change("Session sleeping, waiting for scheduled wake-up")
        end
      end

      # Pause when agent completes a turn and needs user input
      event :pause do
        transitions from: :running, to: :needs_input
        after do
          log_state_change("Session paused, waiting for input")
          cleanup_running_job
          clear_auth_recovery_budget
          fire_ao_event_triggers("session_needs_input")
          enqueue_debounced_needs_input_push_notification
          enqueue_session_inference_if_needed
          execute_pending_sleep
        end
      end

      # Resume execution with follow-up prompt or restart
      # Also allows resuming from waiting state (for clone-only sessions receiving first prompt)
      #
      # Deliberately unguarded: the preconditions for resuming (a clone that
      # exists, a runtime session id to resume, a live process) are established or
      # validated by AgentSessionJob, which resumes what it can and fails the
      # session with a specific failure_reason when it cannot. Re-checking them
      # here would only strand sessions the job knows how to recover.
      event :resume do
        transitions from: [ :waiting, :needs_input, :failed ], to: :running
        after do
          clear_stale_mcp_failure_metadata
          clear_paused_by_metadata
          clear_blocked_on_elicitation_marker
          clear_pending_sleep
          reset_elapsed_time_counter
          mark_notifications_stale
          cancel_pending_one_time_wake_triggers
          log_state_change("Session resumed")
        end
      end

      # Block on a pending MCP elicitation.
      #
      # Unlike `pause` (turn completion), the live agent process is STILL RUNNING —
      # it made a synchronous MCP elicitation request and is blocked awaiting the
      # user's accept/decline/cancel response. We surface the session as needs_input
      # so it appears in the user's homepage action queue and gets the same Slack /
      # Zimmer-event visibility a normal pause gets, but we deliberately do NOT call
      # `cleanup_running_job` — that would terminate the process and break the
      # elicitation round-trip. The push notification for this case is the immediate
      # `elicitation_pending` push enqueued at elicitation-create time, so we do not
      # also enqueue the debounced needs_input push (which would double-notify).
      #
      # A metadata marker (`blocked_on_elicitation`) records that this needs_input
      # was caused by an elicitation, so the flip back to running is distinguishable
      # from a normal turn-completion pause.
      event :block_on_elicitation do
        transitions from: :running, to: :needs_input
        after do
          log_state_change("Session blocked on MCP elicitation, waiting for user response")
          set_blocked_on_elicitation_marker
          fire_ao_event_triggers("session_needs_input")
        end
      end

      # Unblock from elicitation: flip back to running once no active elicitation
      # remains (resolved via accept/decline/cancel, or expired). The agent process
      # never stopped, so this is NOT a fresh `resume` — we skip the counter resets
      # and MCP-metadata clearing that resume performs. We only clear the marker and
      # pull the now-stale notifications out of the user's queue.
      #
      # Guarded by `blocked_on_elicitation?` so a session that reached needs_input
      # via a normal turn-completion pause is never flipped back to running here.
      event :unblock_from_elicitation do
        transitions from: :needs_input, to: :running, guard: :blocked_on_elicitation?
        after do
          clear_blocked_on_elicitation_marker
          mark_notifications_stale
          log_state_change("Session unblocked from MCP elicitation, resuming agent turn")
        end
      end

      # Fail due to error during execution or input
      # Can also fail from waiting if job fails before process is spawned
      event :fail do
        transitions from: [ :waiting, :running, :needs_input ], to: :failed
        after do
          log_state_change("Session failed: #{metadata['failure_reason']}")
          cleanup_running_job
          preserve_debug_info
          fire_ao_event_triggers("session_failed")
          enqueue_failure_push_notification
          enqueue_session_inference_if_needed
        end
      end

      # Archive session (moves to trash)
      # Can archive from any non-archived state (including running, which may be a user
      # force-archiving a stuck session)
      #
      # The clone is deleted after the undo window (10 seconds) by DeferredCloneCleanupJob.
      # If unpushed artifacts exist, they are preserved for 14 days before deletion.
      # Clean clones are deleted immediately with no retention period.
      event :archive do
        transitions from: [ :waiting, :running, :needs_input, :failed ], to: :archived
        after do
          set_archived_at
          log_state_change("Session moved to trash")
          cleanup_running_job
          dismiss_notifications
          fire_ao_event_triggers("session_archived")
          cleanup_watched_session_ao_event_triggers
          set_trash_expiry
        end
      end

      # Restore session from trash (unarchive from archived state)
      # Transitions to waiting or failed based on session history
      # Clears trash_after to prevent automatic cleanup
      event :unarchive_to_waiting do
        transitions from: :archived, to: :waiting
        after do
          clear_trash_expiry
          log_state_change("Session restored from trash to waiting")
        end
      end

      event :unarchive_to_failed do
        transitions from: :archived, to: :failed
        after do
          clear_trash_expiry
          log_state_change("Session restored from trash to failed")
        end
      end

      event :unarchive_to_needs_input do
        transitions from: :archived, to: :needs_input
        after do
          clear_trash_expiry
          log_state_change("Session restored from trash to needs_input")
        end
      end
    end
  end

  class_methods do
    # Of +session_ids+, the ids whose session is deliberately asleep on a wake-up
    # that has not come due — the batch form of #awaiting_scheduled_wake?.
    #
    # Bulk refresh asks this about every candidate `waiting` session at once, and
    # the per-session predicate costs one joined query each. Two queries for the
    # whole set keeps a dashboard full of waiting sessions from turning a refresh
    # into an N+1 inside a synchronous request.
    #
    # @param session_ids [Array<Integer>] candidate session ids
    # @return [Set<Integer>] the subset that is sleeping on a pending wake-up
    def ids_awaiting_scheduled_wake(session_ids)
      ids = Array(session_ids).compact
      return Set.new if ids.empty?

      TriggerCondition
        .joins(:trigger)
        .includes(:trigger)
        .where(condition_type: %w[schedule ao_event], last_triggered_at: nil)
        .where(triggers: { last_session_id: ids, reuse_session: true, status: "enabled" })
        .select { |condition| one_time_wake_pending?(condition) }
        .map { |condition| condition.trigger.last_session_id }
        .to_set
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error("[SessionStateMachine] Failed to batch-check pending wake-ups: #{e.message}")
      # Fail safe, as in #awaiting_scheduled_wake?: an unreadable trigger table
      # means every candidate is treated as asleep rather than nudged awake.
      ids.to_set
    end

    # Whether +condition+ is a per-session wake-up this session is still waiting on.
    #
    # A session-scoped ao_event has no time component — it fires whenever the
    # watched session transitions — so an unfired one is always still ahead.
    # A one-time schedule is only still ahead while it has not come due;
    # TriggerCondition#schedule_due? is the same reading the firing path uses, so
    # "sleeping" here means exactly "the scheduler has yet to reach it".
    def one_time_wake_pending?(condition)
      return true if condition.session_scoped_ao_event?
      return false unless condition.one_time_schedule?

      !condition.schedule_due?
    end
  end

  # Guard: Check if session can start
  # Requires git_root to be present
  def can_start?
    git_root.present?
  end

  # Whether this session's needs_input state was caused by a pending MCP
  # elicitation (vs a normal turn-completion pause). Used as the guard for
  # `unblock_from_elicitation` and to drive elicitation-specific UI labels.
  def blocked_on_elicitation?
    metadata&.dig("blocked_on_elicitation") == true
  end

  # Whether a one-time wake-up targeting this session is still ahead of it — i.e.
  # the session is deliberately asleep, waiting for its `wake_me_up_later` /
  # `wake_me_up_when_session_changes_state` trigger.
  #
  # This reads the same conditions `cancel_pending_one_time_wake_triggers`
  # consumes on resume, asked as a question instead of consumed. A manual refresh
  # uses it to tell a deliberately-sleeping `waiting` session apart from one that
  # is merely stalled, so refreshing does not wake a session early.
  #
  # Note the asymmetry with that cancel path, which is deliberate: cancelling
  # takes every unfired one-time wake, while sleeping takes only the ones that
  # have not come due. A one-time schedule whose moment has already passed
  # without firing (a stopped scheduler, a crashed trigger job) describes a
  # session that is stuck, not one that is resting — and that is exactly the
  # session a refresh exists to rescue.
  def awaiting_scheduled_wake?
    pending_one_time_wake_conditions.any? { |condition| self.class.one_time_wake_pending?(condition) }
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error(
      "[SessionStateMachine] Failed to check pending wake-up triggers for session #{id}: #{e.message}"
    )
    # Fail safe: treat an unreadable trigger table as "asleep on purpose" so a
    # refresh never wakes a sleeping session on the strength of a DB error.
    true
  end

  # Whether a manual refresh of this session should send the automated continue
  # nudge (AutomatedPrompts::SYSTEM_RECOVERY) instead of only re-syncing its
  # transcript. Applies to `waiting` sessions that have a conversation to resume
  # and are not deliberately asleep:
  #
  # - a session with no `session_id` has never started, so there is nothing to
  #   continue — the spawn pipeline still owns it;
  # - a session with a wake-up still ahead of it is sleeping on purpose, and
  #   nudging it would fire the work early.
  def continue_nudge_on_refresh?
    return false unless waiting?
    return false if session_id.blank?

    !awaiting_scheduled_wake?
  end

  # Reconcile the session's status with its active (pending, unexpired)
  # elicitations. Called from Elicitation lifecycle callbacks on every path that
  # creates, resolves, or expires an elicitation.
  #
  # - If any active elicitation exists and the session is running, block it
  #   (running -> needs_input) without tearing down the live agent process.
  # - If no active elicitation remains and the session was blocked on one,
  #   unblock it (needs_input -> running).
  #
  # Both transitions are guarded by `may_*?` so this is a safe no-op when the
  # session is in a state where the transition does not apply (e.g. already
  # needs_input for a normal pause, archived, failed, or running without a
  # marker). Multiple concurrent elicitations are handled naturally: the second
  # create is a no-op (already needs_input), and unblock only fires once the last
  # active elicitation is gone.
  def sync_elicitation_blocking_state!
    if elicitations.active.exists?
      block_on_elicitation! if may_block_on_elicitation?
    elsif blocked_on_elicitation?
      unblock_from_elicitation! if may_unblock_from_elicitation?
    end
  rescue AASM::InvalidTransition => e
    Rails.logger.warn "[SessionStateMachine] Skipped elicitation block sync for session #{id}: #{e.message}"
  end

  # Reconcile a *stranded* elicitation block: the `blocked_on_elicitation` marker
  # is set but no active elicitation remains.
  #
  # The block/unblock lifecycle normally reconciles reactively via
  # Elicitation#after_commit -> sync_elicitation_blocking_state!. If that reactive
  # pass is ever missed the marker is left set with nothing to re-run it, and the
  # session is stranded in needs_input showing a phantom "blocked on elicitation"
  # that never clears. This happens when:
  #   - a swallowed AASM::InvalidTransition (state race) skips the unblock `after`
  #     block that would have cleared the marker, or
  #   - the MCP server crashes / is killed mid round-trip, so no resolve or expire
  #     commit ever fires the after_commit callback.
  #
  # CleanupExpiredElicitationsJob calls this periodically to restore the invariant
  # "blocked_on_elicitation marker set => an active elicitation exists".
  #
  # Unlike unblock_from_elicitation (a user RESOLVED the elicitation, so the still
  # live agent process resumes to :running), a stranded marker discovered minutes
  # later has no live round-trip to resume into. We therefore only strip the marker
  # and LEAVE the session in needs_input for the user to act on — flipping it to
  # :running would create a phantom running session with no monitoring job (an
  # orphan) and could trigger a recovery nudge that retries the failed action.
  #
  # @return [Boolean] true if a stale marker was cleared, false otherwise
  def clear_stale_elicitation_block!
    cleared = false
    # Lock the row and re-read inside the transaction before clearing. The sweep
    # loads the session, then clears the marker — an elicitation created (or the
    # marker re-armed) in that window would otherwise be silently clobbered
    # (its still-live block dropped, or a concurrent metadata write on the same
    # json column lost). with_lock reloads first, so the re-check sees committed
    # state and clear_blocked_on_elicitation_marker computes `except` off it.
    with_lock do
      next unless blocked_on_elicitation? && !elicitations.active.exists?

      clear_blocked_on_elicitation_marker
      log_state_change("Cleared stale elicitation block: marker was set with no active elicitation remaining")
      cleared = true
    end
    cleared
  end

  private

  # Report a transition side effect that failed and was swallowed.
  #
  # Every callback below runs inside an AASM `after` block and rescues its own
  # errors, because a broken notification service must not be able to wedge a
  # session mid-transition. That trade is still the right one — but it used to be
  # paid entirely in silence: cleanup did not happen, the state advanced anyway,
  # and the only trace was a log line nobody reads.
  #
  # `alert: true` marks the failures that leave persistent state inconsistent
  # with nothing else to reconcile them; those page #eng-alerts. `alert: false`
  # marks the ones that are cosmetic, best-effort by design, or already covered
  # by a reconciling sweep — those stay log-only, because a second alert path to
  # an event that already self-heals is just noise. Each call site says which it
  # is and why.
  #
  # The dedup key is the operation, NOT the session: a systemic failure (a sick
  # database, a dead Redis) hits this callback for every session in flight and
  # must collapse into one alert per AlertService::DEDUP_WINDOW, not thousands.
  #
  # @param operation [Symbol] the callback that failed — pass `__method__`
  # @param error [Exception] the swallowed error
  # @param alert [Boolean] whether this failure also pages #eng-alerts
  def report_swallowed_side_effect(operation, error, alert:)
    Rails.logger.error(
      "[SessionStateMachine] Failed to #{operation} for session #{id}: #{error.class}: #{error.message}"
    )
    return unless alert

    AlertService.raise_alert(
      "Session state-machine side effect failed",
      details: "`#{operation}` raised during a state transition and was swallowed, so the " \
               "transition completed with this side effect missing.\n\n" \
               "*Session:* #{id}\n" \
               "*Error:* #{error.class}: #{error.message}\n\n" \
               "<#{AppUrl.base_url}/sessions/#{id}|View session in Zimmer>",
      source: "SessionStateMachine##{operation}",
      dedup_key: "session_state_machine_side_effect_#{operation}"
    )
  rescue => reporting_error
    # Reporting must never become a new way for a transition to blow up. This
    # runs inside an AASM `after` block, so an exception escaping here would
    # abort the transition mid-flight — the exact wedge these rescues exist to
    # prevent. The inner rescue covers the case where the logger itself is what
    # is broken, which is also the most likely reason the line above raised.
    begin
      Rails.logger.error(
        "[SessionStateMachine] Failed to report swallowed side effect #{operation}: #{reporting_error.message}"
      )
    rescue StandardError
      nil
    end
  end

  # Reset the elapsed time counter by updating last_timeline_entry_at to current time
  # This ensures the time-since Stimulus controller shows fresh "0m" instead of
  # stale time from previous runs when transitioning to running state.
  # The status broadcast callback in Session model will re-render the follow_up_form
  # partial with the updated timestamp.
  def reset_elapsed_time_counter
    update_column(:last_timeline_entry_at, Time.current)
  rescue => e
    # Log-only: the counter is a display timestamp. A stale "12m" on a freshly
    # started session is cosmetic and the next transition overwrites it.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Record when the session was archived. Runs as a state machine callback
  # so all archive paths (web UI, API, health monitor, bulk) set it consistently.
  def set_archived_at
    update_column(:archived_at, Time.current)
  rescue => e
    # Alert: archived_at is what the trash UI and DeferredCloneCleanupJob both
    # date from. A session archived with a nil archived_at is inconsistent
    # persistent state and nothing back-fills it.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Log state transition to database
  def log_state_change(message)
    logs.create!(
      content: "[State Machine] #{message}",
      level: "info"
    )
  rescue => e
    # Log-only, deliberately. This fires on every transition, so it is the single
    # noisiest callback here — and the failure it reports (losing one timeline
    # line) changes no state. Anything systemic enough to break it also breaks
    # the alerting callbacks below, which do page.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Check if clone directory exists
  def clone_exists?
    clone_path = metadata&.dig("clone_path")
    return false unless clone_path

    File.directory?(clone_path)
  end

  # Clear running_job_id when session is no longer running
  def cleanup_running_job
    update_column(:running_job_id, nil) if running_job_id.present?
  rescue => e
    # Alert: a needs_input/failed/archived session still carrying a running_job_id
    # looks owned to the orphan sweep and to ownership-supersede checks, which is
    # how a session ends up unable to be resumed.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Preserve debug information on failure
  def preserve_debug_info
    # Debug info is already in metadata (process_pid, clone_path, etc.)
    # This is a hook for future enhancements (e.g., snapshot transcript)
    Rails.logger.info "[SessionStateMachine] Debug info preserved for session #{id}"
  end

  # Clear stale MCP failure flags from custom_metadata when resuming a session.
  # This allows MCP connections to be re-checked fresh on restart, even if
  # the previous attempt failed. Without this, the new job would immediately
  # see the old should_fail_session=true flag and fail again.
  #
  # Clears: should_fail_session, mcp_connection_checked, mcp_failed_servers,
  #         mcp_failure_reason, mcp_servers_status
  def clear_stale_mcp_failure_metadata
    return unless custom_metadata.present?

    mcp_keys = %w[
      should_fail_session
      mcp_connection_checked
      mcp_failed_servers
      mcp_failure_reason
      mcp_servers_status
    ]

    # Only update if there are MCP keys to clear
    keys_to_clear = mcp_keys & custom_metadata.keys
    return if keys_to_clear.empty?

    # Note: Using update_column bypasses optimistic locking, but this is acceptable
    # since resume only happens from non-monitoring states (needs_input, failed, waiting)
    # where MCP metadata isn't being actively written.
    cleaned_metadata = custom_metadata.except(*mcp_keys)
    update_column(:custom_metadata, cleaned_metadata)

    Rails.logger.info "[SessionStateMachine] Cleared stale MCP failure metadata for session #{id}: #{keys_to_clear.join(', ')}"
  rescue => e
    # Alert: this is the callback whose whole purpose is to stop the *next* run
    # from re-failing on a stale should_fail_session flag. Swallowed, the resume
    # succeeds and the session immediately fails again for a reason that is no
    # longer true.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # A completed turn is the only unambiguous evidence that auth recovery worked:
  # the process got past the "Not logged in" wall and ran to a normal exit. The
  # re-spawned process merely staying alive is not — it spends its first seconds
  # connecting MCP servers before it makes the API call that fails — which is why
  # AuthRecoveryService cannot clear its own budget and does it from here.
  #
  # Without this, a long-running session that survives several genuine account
  # rotations inside AuthRecoveryService::CONSECUTIVE_WINDOW would exhaust a
  # budget every one of those recoveries had actually earned back.
  def clear_auth_recovery_budget
    keys = %w[auth_recovery_count last_auth_recovery_at auth_recovery_adoptions last_auth_adoption_at]
    return unless keys.any? { |key| metadata&.key?(key) }

    update_column(:metadata, metadata.except(*keys))
  rescue => e
    # Alert: the budget is only ever cleared here. Swallowed, a long-running
    # session accumulates recovery attempts it has already earned back and is
    # eventually parked for an outage that has long since cleared.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Execute a deferred sleep if the session was flagged for pending sleep.
  # Called from the pause callback — when an agent calls wake_me_up_later
  # while running, the controller sets pending_sleep in metadata. After the
  # turn completes and pause! transitions to needs_input, this method
  # automatically transitions to waiting.
  def execute_pending_sleep
    return unless metadata&.dig("pending_sleep") == true

    sleep!
    update_column(:metadata, metadata.except("pending_sleep"))
  rescue => e
    # Alert: the session asked to sleep and did not. It sits in needs_input on
    # the user's homepage as if it wanted attention, and the pending_sleep flag
    # survives to surprise-sleep it after some later turn.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Cancel any pending one-time wake-up conditions that were targeting this
  # session. When a session resumes (via any path — user follow-up,
  # force_immediate, restart, or the trigger itself firing), these conditions
  # should not fire again on an already-active session.
  #
  # We "consume" each matching condition by setting last_triggered_at = now,
  # which makes the firing path skip it. The trigger itself stays enabled (it
  # may have other conditions).
  #
  # Scoped to: conditions on triggers where this session is the reuse target,
  # that haven't fired yet, and that are one-time wake-ups — either a one-time
  # schedule (scheduled_at present) or a session-scoped ao_event
  # (watched_session_id present). Recurring schedules and broadcast ao_events
  # are left alone.
  def cancel_pending_one_time_wake_triggers
    pending_one_time_wake_conditions.find_each do |condition|
      next unless condition.one_time_schedule? || condition.session_scoped_ao_event?
      condition.update!(last_triggered_at: Time.current)
      Rails.logger.info(
        "[SessionStateMachine] Cancelled pending one-time wake-up " \
        "(trigger_condition #{condition.id}) for resumed session #{id}"
      )
    end
  rescue => e
    # Don't raise — trigger cleanup failures shouldn't block the resume. But do
    # alert: an uncancelled one-time wake stays armed and fires later against an
    # already-active session, injecting a wake-up prompt into live work.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Unfired trigger conditions that could still wake this session: conditions on
  # triggers where this session is the reuse target, that haven't fired yet.
  # Callers still filter to the one-time shapes (one-time schedule or
  # session-scoped ao_event) — recurring schedules and broadcast ao_events are
  # not per-session wake-ups and are left alone.
  def pending_one_time_wake_conditions
    TriggerCondition
      .joins(:trigger)
      .where(condition_type: %w[schedule ao_event], last_triggered_at: nil)
      .where(triggers: { last_session_id: id, reuse_session: true, status: "enabled" })
  end

  # Clear any pending_sleep flag when the session is resumed. The flag is set
  # by the "auto-sleep on running session" path (Trigger#sleep_target_session_if_applicable)
  # and normally consumed when the running turn pauses. If the session fails
  # instead of pausing, the flag can linger in metadata — a later resume →
  # run → pause would then surprise-transition the session back to waiting.
  # Clearing on resume makes the user's explicit "keep this active" action
  # win over any stale auto-sleep intent.
  def clear_pending_sleep
    return unless metadata&.dig("pending_sleep") == true

    update_column(:metadata, metadata.except("pending_sleep"))
    Rails.logger.info "[SessionStateMachine] Cleared pending_sleep on resume for session #{id}"
  rescue => e
    # Alert: the user explicitly said "keep this active" and the stale auto-sleep
    # intent survived. The next pause silently drops the session to waiting.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Mark that this session's needs_input state is caused by a pending MCP
  # elicitation. Mirrors the paused_by / pending_sleep metadata-marker pattern;
  # uses update_column so it does not re-trigger save callbacks during the AASM
  # transition that just persisted the status change.
  def set_blocked_on_elicitation_marker
    update_column(:metadata, (metadata || {}).merge("blocked_on_elicitation" => true))
    Rails.logger.info "[SessionStateMachine] Set blocked_on_elicitation marker for session #{id}"
  rescue => e
    # Alert: without the marker the session is in needs_input with no record of
    # why, so `unblock_from_elicitation`'s guard can never fire. Resolving the
    # elicitation leaves the agent process blocked with nothing to flip it back.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Clear the blocked_on_elicitation marker (on unblock or on a real resume).
  def clear_blocked_on_elicitation_marker
    return unless metadata&.dig("blocked_on_elicitation")

    update_column(:metadata, metadata.except("blocked_on_elicitation"))
    Rails.logger.info "[SessionStateMachine] Cleared blocked_on_elicitation marker for session #{id}"
  rescue => e
    # Log-only: a stranded marker is exactly what CleanupExpiredElicitationsJob
    # reconciles via #clear_stale_elicitation_block!. Alerting here would page
    # for a condition that already has a sweep, which is the noise this change
    # is trying not to create.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Clear paused_by metadata when resuming a session.
  # This is used by the web UI pause button to track user-initiated pauses.
  def clear_paused_by_metadata
    return unless metadata&.dig("paused_by").present?

    cleaned_metadata = metadata.except("paused_by")
    update_column(:metadata, cleaned_metadata)

    Rails.logger.info "[SessionStateMachine] Cleared paused_by metadata for session #{id}"
  rescue => e
    # Log-only: paused_by drives a UI label ("paused by you"). A stale one is
    # wrong on screen but drives no behavior, and the next pause overwrites it.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Mark all notifications for this session as stale and broadcast badge update.
  # Called when the session is actioned (resumed, archived, etc.) to "pull out"
  # the notification from the user's queue since it's no longer relevant.
  # Also broadcasts the updated badge count so any page showing the notification
  # badge updates in real-time.
  def mark_notifications_stale
    Notification.mark_session_stale(self)
    Rails.logger.info "[SessionStateMachine] Marked notifications as stale for session #{id}"

    # Broadcast badge update so the count decrements in real-time
    BroadcastService.new.notification_badge(Notification.pending_count)
  rescue => e
    # Log-only: the notification queue is a derived surface with its own
    # lifecycle — the next action on the session re-runs this, and archival
    # destroys the rows outright. A lingering badge is not inconsistent state.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Dismiss (destroy) all notifications for this session and broadcast badge update.
  # Called when the session is archived to completely remove notifications from the
  # user's queue since the session is in a terminal state.
  def dismiss_notifications
    notifications.destroy_all
    Rails.logger.info "[SessionStateMachine] Dismissed all notifications for session #{id}"

    # Broadcast badge update so the count decrements in real-time
    BroadcastService.new.notification_badge(Notification.pending_count)
  rescue => e
    # Log-only, for the same reason as mark_notifications_stale: the rows are
    # cascade-destroyed with the session and the badge count is recomputed on
    # every load, so an undismissed notification self-corrects.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # When a watched session is archived, ao_event conditions scoped to it
  # (watched_session_id == self.id) can no longer fire usefully — the watched
  # session won't transition again. Delete those conditions to keep the
  # trigger list clean and avoid orphan rows.
  #
  # Exception: conditions whose event_name is "session_archived" are EXACTLY
  # the ones that should fire on this archival. AoEventTriggerJob is enqueued
  # via after_all_transactions_commit and runs after this synchronous cleanup,
  # so destroying those conditions here would race the job and prevent it from
  # firing. The job's own one_time_reuse_trigger? cleanup will delete the
  # trigger after firing.
  #
  # If a trigger had ONLY the scoped condition (single-purpose wake-up),
  # destroy the whole trigger. If it had other conditions (slack, recurring
  # schedule, broadcast ao_event — OR semantics), preserve the trigger and
  # just remove the now-stale condition.
  def cleanup_watched_session_ao_event_triggers
    archived_session_id = id

    conditions = TriggerCondition
      .where(condition_type: "ao_event")
      .where("configuration @> ?", { watched_session_id: archived_session_id }.to_json)
      .includes(:trigger)

    return if conditions.empty?

    destroyed_trigger_ids = []
    destroyed_condition_ids = []

    conditions.find_each do |condition|
      # Skip session_archived conditions — they need to fire on this very event.
      next if condition.ao_event_name == "session_archived"

      trigger = condition.trigger
      siblings_count = trigger.trigger_conditions.where.not(id: condition.id).count

      if siblings_count.zero?
        trigger.destroy!
        destroyed_trigger_ids << trigger.id
      else
        condition.destroy!
        destroyed_condition_ids << condition.id
      end
    end

    Rails.logger.info(
      "[SessionStateMachine] Watched-session #{archived_session_id} archived: " \
      "destroyed triggers #{destroyed_trigger_ids.inspect}, " \
      "destroyed conditions #{destroyed_condition_ids.inspect}"
    )
  rescue => e
    # Don't raise - cleanup failures shouldn't block archival. Alert, though:
    # the leftover conditions target a session that can never transition again,
    # so they are orphans no sweep collects, and any session waiting on one
    # sleeps until its deadline backstop instead of being woken.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Fire Zimmer event triggers when session transitions to a watchable state.
  # Defers the job until after the current transaction commits to ensure:
  # 1. The session record is persisted and visible to the job
  # 2. No synchronous cascading in system tests using perform_enqueued_jobs
  #
  # ActiveRecord.after_all_transactions_commit (Rails 7.2+) runs the block
  # immediately when no transaction is open, otherwise defers it until the
  # outermost transaction commits. The previous implementation called
  # connection.after_transaction_commit, which does not exist on
  # PostgreSQLAdapter and silently raised NoMethodError, preventing this job
  # from ever being enqueued in production.
  def fire_ao_event_triggers(event_name)
    session_id = id
    ActiveRecord.after_all_transactions_commit do
      AoEventTriggerJob.perform_later(event_name, session_id)
    end
  rescue => e
    # Don't raise - trigger failures shouldn't block state transitions. Alert:
    # this is the callback that already failed silently once, when
    # connection.after_transaction_commit raised NoMethodError on every call and
    # no Zimmer event trigger fired in production at all (see the comment above).
    # A swallowed enqueue here means every watcher of this session misses the
    # transition, with nothing to retry it.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Enqueue a push notification when the session reaches the terminal `failed`
  # state. Unlike routine completion/needs_input alerts, a terminal failure is a
  # final, non-self-resolving event — by the time `fail!` fires, any retries
  # (e.g. the MCP connection backoff) are already exhausted. The user would
  # otherwise experience this as a silent status flip, so it bypasses the
  # per-session push_notifications_enabled opt-in (which gates the high-frequency
  # needs_input path) and always fires. WebPushService no-ops gracefully when no
  # push subscriptions exist or VAPID keys are unconfigured.
  def enqueue_failure_push_notification
    SendPushNotificationJob.perform_later(id, :session_failed)
  rescue => e
    # Log-only: push delivery is best-effort by construction (WebPushService
    # no-ops without subscriptions or VAPID keys), and the failed session is
    # already on the user's homepage queue regardless.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Debounce window for needs_input push notifications. Sessions sometimes
  # transition running → needs_input → running between turns; without debouncing
  # those flaps generate spurious pushes. The deferred job re-checks state at
  # execution time and only fires if the session is still idle.
  NEEDS_INPUT_DEBOUNCE = 60.seconds

  # Enqueue a debounced needs_input push notification.
  #
  # Increments a transition counter in custom_metadata so the deferred job can
  # detect whether the session has churned through additional state changes
  # during the wait window. If a flap (resume → pause) happens during the
  # window, the original job's marker won't match the new counter and the
  # job will no-op; the new pause will schedule its own debounced job.
  def enqueue_debounced_needs_input_push_notification
    return unless push_notifications_enabled?

    marker = bump_needs_input_transition_counter
    # The NEEDS_INPUT_DEBOUNCE wait is long enough that the AASM
    # state-transition transaction commits before the worker dequeues the
    # job, so the marker row is visible by then. ActiveJob's
    # enqueue_after_transaction_commit is false by default in Rails 8 (the
    # 7.2+ default of true was reverted), so the enqueue itself is not
    # deferred — the wait window is what guarantees the marker is committed.
    SendPushNotificationJob
      .set(wait: NEEDS_INPUT_DEBOUNCE)
      .perform_later(id, :needs_input, nil, marker)
  rescue => e
    # Log-only, as with the failure push: best-effort delivery, and the homepage
    # action queue is the durable surface for a session needing input.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Increment and persist the needs_input transition counter, returning the
  # new value. Used as a debounce marker for the deferred push job. The
  # counter is monotonic across the session's lifetime; it is never reset on
  # resume, so values are unique per transition but not minimal.
  def bump_needs_input_transition_counter
    metadata_hash = custom_metadata.presence || {}
    next_count = metadata_hash["needs_input_count"].to_i + 1
    update_column(:custom_metadata, metadata_hash.merge("needs_input_count" => next_count))
    next_count
  end

  # Enqueue SessionTitleJob (which both titles and categorizes) when either
  # piece of work is still pending. Firing on a pause/fail transition runs it
  # promptly once a transcript exists — the strongest signal for both the title
  # and the category. Also catches sessions created without a prompt (e.g.
  # clone-only sessions that later received one), where the after_create_commit
  # callback skipped enqueuing because the prompt was blank at creation time.
  def enqueue_session_inference_if_needed
    title_pending = metadata&.dig("auto_generated_title") == true
    category_pending = category_id.blank? && prompt.present? && Category.where(is_frozen: false).exists?
    return unless title_pending || category_pending

    SessionTitleJob.perform_later(id)
  rescue => e
    # Log-only: a missing title or category is cosmetic, and the next pause or
    # fail transition re-runs this for as long as either is still pending.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Retention period for preserved artifacts (unpushed commits + uncommitted changes).
  # Clean clones have no retention — they are deleted immediately after the undo window.
  # Only dirty clones get artifacts preserved, and those artifacts are kept for this period.
  TRASH_RETENTION_PERIOD = 4.days

  def clear_trash_expiry
    update_column(:trash_after, nil)
    Rails.logger.info "[SessionStateMachine] Cleared trash expiry for session #{id}"
  rescue => e
    # Alert: this runs on the three unarchive events. A restored session that
    # keeps its trash_after is queued for deletion again — EmptyTrashJob will
    # re-trash the very session the user just pulled out of the trash, and its
    # clone with it.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Set a temporary trash_after as safety net and enqueue deferred cleanup.
  # DeferredCloneCleanupJob runs after the undo window and either:
  # - Clears trash_after (clean clone, no retention needed)
  # - Resets trash_after to TRASH_RETENTION_PERIOD (dirty clone, artifacts preserved)
  def set_trash_expiry
    update_column(:trash_after, TRASH_RETENTION_PERIOD.from_now)
    enqueue_deferred_cleanup
    Rails.logger.info "[SessionStateMachine] Set trash expiry and enqueued cleanup for session #{id}"
  rescue => e
    # Log-only: StaleCloneCleanupJob catches sessions where trash_after is nil,
    # which is the documented safety net for exactly this failure.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Enqueue the deferred cleanup job to run after the undo window.
  # The job checks for unpushed artifacts, preserves them if needed, then deletes the clone.
  def enqueue_deferred_cleanup
    archived_at_iso = archived_at&.iso8601 || Time.current.iso8601
    DeferredCloneCleanupJob.set(wait: DeferredCloneCleanupJob::CLEANUP_DELAY).perform_later(id, archived_at_iso)
  rescue => e
    # Log-only: if the enqueue fails, EmptyTrashJob handles cleanup once
    # trash_after expires — again a documented, existing fallback.
    report_swallowed_side_effect(__method__, e, alert: false)
  end
end

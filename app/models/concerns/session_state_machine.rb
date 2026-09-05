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

  # Marks the in-flight `resume` as Zimmer restarting this session's own process
  # after an interruption (a deployment restart, an orphaned process, a hung
  # process reaped) rather than a human or an agent deliberately waking it.
  #
  # The two are not the same event and must not have the same side effects. A
  # deliberate resume means "someone has taken this session over" — its pending
  # wake-ups are moot and get consumed. A system-recovery resume means "the
  # process died and we started it again"; the session never chose to wake, so
  # its sleep intent and its pending wake-ups are still exactly what it is
  # waiting on. Consuming them there is what strands an orchestrator: it comes
  # back with nothing armed, ends its turn, and sits in needs_input forever with
  # children it was supposed to be watching.
  #
  # Transient (never persisted) and scoped to a single resume by
  # Session#resume_for_system_recovery!.
  attr_accessor :system_recovery_resume

  # True for exactly the resume a one-time WAKE caused — a `wake_me_up_later`
  # deadline or a `wake_me_up_when_session_changes_state` watcher firing through
  # Trigger#follow_up_session!.
  #
  # It selects the third branch of #cancel_pending_one_time_wake_triggers: hold
  # the rest of the wake group rather than consuming it. A deliberate resume (a
  # human follow-up, a restart, force_immediate) leaves this false and consumes
  # as before, because a session someone deliberately woke has no wait left to
  # protect. Transient, never persisted, cleared in an `ensure` by its one writer.
  attr_accessor :wake_fire_resume

  # Metadata marker written alongside `pending_sleep` by the system-recovery
  # preserve branch. It means "sleep only if something is still armed to wake
  # you", and distinguishes that conditional intent from a deliberate sleep,
  # which is executed whether or not any wake-up exists.
  PENDING_SLEEP_REQUIRES_WAKE = "pending_sleep_requires_wake"

  # Who fired `archive`, in the words the session's own timeline will use.
  #
  # Every other transition has one obvious cause: a process spawned, a turn
  # ended, an error was raised. `archive` has six unrelated callers — the web
  # UI, the REST API, the MCP API, the stale-session sweep, status-summary fork
  # cleanup, and a session archiving itself — and they all used to leave the
  # same five words behind. That made "why did my session get archived?"
  # unanswerable from the session page: a human clicking Trash and another agent
  # archiving this session out from under its unfinished work were indis-
  # tinguishable, and telling them apart meant reading another session's raw
  # transcript off disk.
  #
  # Set by the caller immediately before `archive!`. Transient, never persisted.
  # Nothing enforces it — an archive from a console or a test says it has no
  # recorded actor rather than claiming one it does not have.
  attr_accessor :archive_actor

  # What the archive line says when the caller set no actor.
  ARCHIVE_ACTOR_UNRECORDED = "an unrecorded caller"

  # How many retired row ids the strand ledger line names before it summarises
  # the rest. See record_strand_ledger.
  STRAND_LEDGER_IDS_LOGGED = 20

  # Whether this archive was a caller overriding Sessions::ArchiveGuard.
  #
  # Only the caller-facing surfaces set it — the MCP `archive` and
  # `bulk_archive` actions, `POST /api/v1/sessions/:id/archive` and its bulk
  # twin, and the web Trash button. Those are exactly the surfaces that consult
  # the guard, so `true` means the caller was refused, shown the queued
  # messages, and re-called anyway.
  #
  # System-initiated archives never set it, and that asymmetry is what it is
  # for. HealthMonitorService's stale sweep, SessionStatusSummaryHarvestJob and
  # the status-summary fork cleanup archive unconditionally without consulting
  # the guard, so nobody has read the queue on those paths — which is why
  # strand_pending_enqueued_messages still pages for them, and only for them. It
  # is deliberately NOT `archive_actor.present?`: those sweeps set an actor too.
  #
  # Set by the caller immediately before `archive!`. Transient, never persisted.
  attr_accessor :archive_forced

  # PR statuses GitHubPullRequestPollerJob treats as the end of the story. Any
  # other recorded status means Zimmer still expected the PR to move.
  TERMINAL_PR_STATUSES = %w[merged closed].freeze

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
          record_experimental_setting_flags
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
          # Deferred on exactly the pauses the announcement below is deferred on,
          # and for the same reason: a recovery pause is Zimmer restarting its own
          # interrupted process, so nothing about this session's PR work is
          # settled and nobody is being told about the pause anyway. The budget is
          # one warning per session, so spending it here spends it at the moment it
          # carries the least information — every PR-goal session has no PR at
          # minute six. Session 5679 spent its whole budget on a deploy interrupt
          # six minutes in, ran for two more days, opened a PR through a route the
          # hook did not recognise, and came to rest with nothing recorded and
          # nothing said (#558).
          warn_if_pr_goal_captured_no_url unless announcement_deferred_to_recovery_sweep?
          cleanup_running_job
          clear_auth_recovery_budget
          if status_summary_fork?
            # A status-summary fork pausing means its one turn is done. It is
            # Zimmer's own bookkeeping, not work the operator is waiting on, so
            # it gets harvested — not a push notification, a trigger fire, and a
            # slot in the action queue.
            harvest_status_summary
          else
            # One bump, two consumers. Both the wake fan-out and the push are
            # debounced against the same counter, so bumping it twice would make
            # each one's marker stale to the other and suppress both.
            #
            # The bump happens even when the announcement below is suppressed. It
            # is what supersedes an earlier pause's still-pending settled event,
            # and a session that recovery-paused inside that window is precisely
            # one that has churned — leaving the counter alone would let the older
            # event survive its own settle check and fire.
            marker = bump_needs_input_transition_counter
            announce_needs_input(marker) unless announcement_deferred_to_recovery_sweep?
            enqueue_session_inference_if_needed
            enqueue_status_summary_refresh
          end
          # Before execute_pending_sleep, which asks #armed_one_time_wake? whether
          # a preserved re-sleep still has something to undo it. A wake this turn
          # was woken by must not answer that question — it belongs to the wait
          # that is now over.
          #
          # A pause Zimmer entered on a turn's behalf is not a turn coming to
          # rest, and it is the exact case #569 is about: retiring the group there
          # would re-open the no-trigger window at the one moment it must stay
          # shut. See #turn_stood_down_before_it_ran?.
          retire_held_wake_triggers unless turn_stood_down_before_it_ran?
          execute_pending_sleep
          # Last, and after execute_pending_sleep: a session that just went
          # dormant is not idling on its queue, it is asleep, and the check
          # below reads the state the sleep left behind.
          drain_enqueued_messages_after_pause
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
          clear_undelivered_turn_park
          clear_paused_by_metadata
          clear_enqueued_drain_attempts
          clear_blocked_on_elicitation_marker
          clear_lost_elicitation_marker
          clear_pending_sleep
          reset_elapsed_time_counter
          record_experimental_setting_flags
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
          # Settled like the pause path: an elicitation the user answers in
          # seconds flips straight back to `running` via unblock_from_elicitation,
          # which is a turn-boundary flap by another name.
          fire_settled_needs_input_ao_event(bump_needs_input_transition_counter)
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
          # The round-trip completed, so any earlier "this one was lost" banner is
          # stale. An expiry re-records it right after this runs (see
          # Elicitation#sync_session_elicitation_state) — expiry is an unblock the
          # user still needs told about.
          clear_lost_elicitation_marker
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
          if status_summary_fork?
            harvest_status_summary(failed: true)
          else
            fire_ao_event_triggers("session_failed")
            enqueue_failure_push_notification
            enqueue_session_inference_if_needed
            enqueue_status_summary_refresh
          end
          # A session that dies mid-turn never reaches `pause`, so without this
          # the miss is recorded nowhere. Placed last because the cleanup above
          # is load-bearing and predates this call — nothing here should be able
          # to disturb it.
          warn_if_pr_goal_captured_no_url
        end
      end

      # Archive session (moves to trash)
      # Can archive from any non-archived state (including running, which may be a user
      # force-archiving a stuck session)
      #
      # The clone is deleted after the undo window (10 seconds) by DeferredCloneCleanupJob.
      # If unpushed artifacts exist, they are preserved for TRASH_RETENTION_PERIOD (4 days)
      # before deletion.
      # Clean clones are deleted immediately with no retention period.
      event :archive do
        transitions from: [ :waiting, :running, :needs_input, :failed ], to: :archived
        after do
          set_archived_at
          # Retired before the log line, which names what was retired.
          log_state_change(archive_log_message(strand_pending_enqueued_messages))
          # Consumed by the line above, and single-use: an instance archived,
          # unarchived and archived again must not reuse the first actor — or
          # the first caller's override.
          self.archive_actor = nil
          self.archive_forced = nil
          cleanup_running_job
          dismiss_notifications
          fire_ao_event_triggers("session_archived")
          cleanup_watched_session_ao_event_triggers
          # The other side of the same bookkeeping: the wakes this session was
          # itself waiting on. An archive is a rest like any other, so a group
          # held across a turn is retired here rather than lingering as enabled
          # rows against a session nobody will follow up into.
          retire_held_wake_triggers
          set_trash_expiry
          # Same reasoning as on `fail`: a session trashed straight from
          # `needs_input` is one nobody comes back to, and the trash bookkeeping
          # above must run whatever happens here.
          warn_if_pr_goal_captured_no_url
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

    # Re-arm the `no_sessions_in_progress` system event: the fleet is demonstrably
    # not idle.
    #
    # An after_commit on the status column rather than a hook on `start` and
    # `resume`, because the fact FleetIdleMonitor needs is "a session is running",
    # and every path that produces it has to count — both AASM events, an
    # elicitation unblocking, a session created directly in `running`. Missing one
    # would leave the latch spent against a fleet that had gone back to work.
    #
    # It does NOT cover `update_column`/`update_all`, which skip callbacks; no
    # caller writes `status` that way, and the sweep re-arms on its next tick
    # regardless, so the hook is the fast path rather than the only one.
    #
    # After the commit, so a transition is never slowed or rolled back by this
    # bookkeeping; FleetIdleMonitor.record_busy! swallows its own failures for the
    # same reason.
    after_commit :rearm_fleet_idle_event, if: -> { saved_change_to_status? && running? }
  end

  # See the after_commit above.
  def rearm_fleet_idle_event
    FleetIdleMonitor.record_busy!
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

      conditions = TriggerCondition
        .joins(:trigger)
        .includes(:trigger)
        .where(condition_type: %w[schedule ao_event], last_triggered_at: nil)
        .where(triggers: { last_session_id: ids, reuse_session: true, status: "enabled" })
        .to_a

      # Third query, and it keeps the promise the doc comment above makes. Asking
      # #ao_event_wake_fireable? to look its own watched session up would put one
      # SELECT per ao_event condition inside a synchronous bulk refresh, which is
      # the N+1 this method exists to avoid.
      watched = watched_session_statuses(conditions)

      conditions
        .select { |condition| one_time_wake_pending?(condition, watched_statuses: watched) }
        .map { |condition| condition.trigger.last_session_id }
        .to_set
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error("[SessionStateMachine] Failed to batch-check pending wake-ups: #{e.message}")
      # Fail safe, as in #awaiting_scheduled_wake?: an unreadable trigger table
      # means every candidate is treated as asleep rather than nudged awake.
      ids.to_set
    end

    # Of +session_ids+, the ids paused until a wall-clock time that has not come
    # yet — the batch form of #paused_until_scheduled_time?, and the START guard's
    # question rather than the refresh guard's.
    #
    # Deliberately NARROWER than #ids_awaiting_scheduled_wake, and the difference
    # is the whole reason both exist. A one-time schedule expires: past its moment
    # the session is no longer paused and every guard built on this stops applying,
    # which is what makes a pause a deferral rather than a cancellation. A
    # session-scoped `ao_event` wake has no time at all — it is still "ahead of"
    # the session forever if the watched session never transitions again (it
    # failed, it was archived). Refusing to START on that would make one dead
    # watcher enough to put a session permanently beyond every automated path,
    # which is a worse failure than the early start it prevents.
    #
    # @param session_ids [Array<Integer>] candidate session ids
    # @return [Set<Integer>] the subset paused until a time still ahead of it
    # @raise [ActiveRecord::ActiveRecordError] deliberately not rescued — see
    #   #paused_until_scheduled_time?
    def ids_paused_until_scheduled_time(session_ids)
      ids = Array(session_ids).compact
      return Set.new if ids.empty?

      TriggerCondition
        .joins(:trigger)
        .includes(:trigger)
        .where(condition_type: "schedule", last_triggered_at: nil)
        .where(triggers: { last_session_id: ids, reuse_session: true, status: "enabled" })
        .select { |condition| condition.one_time_schedule? && !condition.schedule_due? }
        .map { |condition| condition.trigger.last_session_id }
        .to_set
    end

    # Whether +condition+ is a per-session wake-up this session is still waiting on.
    #
    # A session-scoped ao_event fires whenever the watched session transitions, so
    # an unfired one is still ahead — unless the watched session can no longer
    # make the transition, which is the case this asks about. A one-time schedule
    # is only still ahead while it has not come due; TriggerCondition#schedule_due?
    # is the same reading the firing path uses, so "sleeping" here means exactly
    # "the scheduler has yet to reach it".
    # @param watched_statuses [Hash{Integer=>String}, nil] preloaded watched-session
    #   statuses, for a caller asking about many conditions at once. Nil means
    #   "look it up", which is right for the one-or-two conditions a single
    #   session carries and wrong for a dashboard full of them.
    def one_time_wake_pending?(condition, watched_statuses: nil)
      if condition.session_scoped_ao_event?
        return ao_event_wake_fireable?(condition, watched_statuses: watched_statuses)
      end
      return false unless condition.one_time_schedule?

      !condition.schedule_due?
    end

    # The statuses of every session watched by the session-scoped `ao_event`
    # conditions in +conditions+, keyed by id. A watched session that no longer
    # exists is simply absent, which #ao_event_wake_fireable? reads as unfireable
    # — the same answer a lookup would give.
    def watched_session_statuses(conditions)
      ids = conditions.filter_map do |condition|
        condition.watched_session_id.to_i if condition.session_scoped_ao_event? && condition.watched_session_id.present?
      end.uniq
      return {} if ids.empty?

      Session.where(id: ids).pluck(:id, :status).to_h
    end

    # Whether a session-scoped `ao_event` wake can still fire at all.
    #
    # An unfired wake row is not the same thing as a wake that will happen, and
    # tadasant/zimmer#855 is what the difference costs. A router slept on a
    # three-event watcher; the watched session archived; the archive callback
    # (#cleanup_watched_session_ao_event_triggers) removed the two conditions that
    # could no longer fire and left the `session_archived` one — which had already
    # missed its only chance. The row survived, `enabled`, `last_triggered_at`
    # nil, and every reader of it — the trigger list, `search_triggers`,
    # #awaiting_scheduled_wake? and so every sweep built on it — reported a
    # session sleeping on purpose. It slept for 38.7 hours and a human found it.
    #
    # So the question is not "has this fired" but "can it". The firing path keys
    # on TRANSITIONS into the watched state (see
    # Mcp::Tools::WakeMeUpWhenSessionChangesState#reject_unfireable_watched_state!,
    # which refuses to arm one of these for the same reason), and an archived
    # session makes no more of them.
    #
    # Deliberately narrow, and it fails SAFE in every direction it is unsure
    # about: only a watched session that is gone or `archived` counts as
    # unfireable. A `failed` one is left alone — a human can restart it, and it
    # can still be archived, so a `session_archived` watcher on it is live. Any
    # other status is a session that can still transition. An unreadable row is
    # treated as fireable, because a wrong "not fireable" wakes a session that
    # meant to sleep, while a wrong "fireable" only delays a rescue.
    def ao_event_wake_fireable?(condition, watched_statuses: nil)
      watched_id = condition.watched_session_id
      return true if watched_id.blank?

      status =
        if watched_statuses
          watched_statuses[watched_id.to_i]
        else
          Session.where(id: watched_id).pick(:status)
        end
      return false if status.nil?

      # Through Session.status_label rather than #to_s, for the reason that method
      # documents: Rails casts an enum column to its label on `pluck`, so this is
      # normally the identity — but if it ever were not, a raw integer would
      # compare unequal to "archived", every watcher would read fireable, and #855
      # would come back silently.
      Session.status_label(status) != "archived"
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error(
        "[SessionStateMachine] Could not read watched session #{condition.watched_session_id} " \
        "for trigger condition #{condition.id}: #{e.message}"
      )
      true
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

  # The last approval round-trip that ended without a human answer, or nil.
  #
  # Written by `record_lost_elicitation!` and cleared the moment the session moves
  # on (a resume, a new block, a resolved elicitation). Shape:
  #
  #   { "reason" => "expired" | "stranded", "at" => iso8601,
  #     "request_id" => String | nil, "summary" => String | nil }
  #
  # @return [Hash, nil]
  def lost_elicitation
    marker = metadata&.dig("lost_elicitation")
    marker.is_a?(Hash) ? marker : nil
  end

  # Whether this session's last approval request ended without an answer — it
  # expired, or its round-trip was lost. Drives the session-detail banner that
  # replaces the phantom: a session sitting in needs_input with nothing on screen
  # to say why.
  def lost_elicitation?
    lost_elicitation.present?
  end

  # When the lost round-trip was recorded, or nil when there is nothing to show.
  # Parsed here rather than in the view so a malformed stored value renders as an
  # absent timestamp instead of raising inside a Turbo broadcast.
  def lost_elicitation_at
    raw = lost_elicitation&.dig("at")
    return nil if raw.blank?

    Time.zone.parse(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Record that an approval round-trip ended without a human answer.
  #
  # Two reasons reach here:
  #
  # - "expired" — the clock ran out. The MCP server's next poll is answered
  #   `expired`, so the agent does get an answer of a kind, and the session flips
  #   back to running. The user still needs to know their approval request went
  #   unanswered and the agent proceeded without it.
  # - "stranded" — the marker outlived its elicitation entirely (see
  #   `clear_stale_elicitation_block!`). There is no round-trip left to complete.
  #
  # Best-effort by design: this is an explanation attached to a state that has
  # already been reconciled, so a write failure must not take the reconciliation
  # (or the caller's commit) down with it.
  #
  # @param reason [String] "expired" or "stranded"
  # @param elicitation [Elicitation, nil] the request that was lost, when known
  # @param broadcast [Boolean] false to write the marker without pushing the
  #   banner, for a caller holding a lock or an open transaction that will
  #   broadcast once it has committed
  # @return [Boolean] true if the marker was written
  def record_lost_elicitation!(reason:, elicitation: nil, broadcast: true)
    marker = {
      "reason" => reason,
      "at" => Time.current.iso8601,
      "request_id" => elicitation&.request_id,
      "summary" => elicitation&.summary
    }.compact

    update_column(:metadata, (metadata || {}).merge("lost_elicitation" => marker))
    log_state_change(
      reason == "expired" ?
        "Elicitation expired without a response — the agent was told the approval request timed out" :
        "Elicitation round-trip lost — the approval request was never answered and no longer has an MCP server waiting on it"
    )
    broadcast_lost_elicitation_banner if broadcast
    true
  rescue => e
    Rails.logger.error "[SessionStateMachine] Failed to record lost elicitation for session #{id}: #{e.message}"
    false
  end

  # Drop the lost-elicitation marker. Called wherever the session moves past the
  # dead round-trip: a resume, a fresh block, or an elicitation that actually got
  # answered.
  def clear_lost_elicitation_marker
    return unless metadata&.key?("lost_elicitation")

    update_column(:metadata, metadata.except("lost_elicitation"))
    broadcast_lost_elicitation_banner
  rescue => e
    Rails.logger.error "[SessionStateMachine] Failed to clear lost elicitation marker for session #{id}: #{e.message}"
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
  # can still fire. A one-time schedule whose moment has already passed without
  # firing (a stopped scheduler, a crashed trigger job), or an `ao_event` watcher
  # whose watched session is archived and will never transition again, describes
  # a session that is stuck, not one that is resting — and that is exactly the
  # session a refresh, and StrandedSleepRescue, exist to rescue.
  def awaiting_scheduled_wake?
    conditions = pending_one_time_wake_conditions.to_a
    watched = self.class.watched_session_statuses(conditions)
    conditions.any? { |condition| self.class.one_time_wake_pending?(condition, watched_statuses: watched) }
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error(
      "[SessionStateMachine] Failed to check pending wake-up triggers for session #{id}: #{e.message}"
    )
    # Fail safe: treat an unreadable trigger table as "asleep on purpose" so a
    # refresh never wakes a sleeping session on the strength of a DB error.
    true
  end

  # Whether this session is paused until a wall-clock time it has not reached.
  #
  # This is what every START path asks. #awaiting_scheduled_wake? answers the
  # broader "is this session resting on purpose", which is the right question for
  # a refresh nudge and the wrong one for a refusal to start — see
  # .ids_paused_until_scheduled_time for why an `ao_event` wake must not make a
  # session unstartable.
  #
  # Deliberately NOT rescued. The batch form's callers are sweeps that re-read
  # from scratch minutes later, so treating an unreadable trigger table as "asleep"
  # costs one pass and errs toward leaving work alone. A start path has no such
  # next pass: standing down there does not re-enqueue, so swallowing the error
  # would turn a transient blip into a session that never starts, and would say so
  # in a log line claiming a pause that does not exist. Callers handle the raise.
  def paused_until_scheduled_time?
    pending_one_time_wake_conditions
      .where(condition_type: "schedule")
      .any? { |condition| condition.one_time_schedule? && !condition.schedule_due? }
  end

  # When the earliest pending one-time wake fires, or nil.
  #
  # Nil is not "nothing is armed": a session-scoped ao_event wake has no time
  # component at all (it fires when the watched session transitions), and a
  # schedule whose timezone or timestamp will not parse has no answer to give.
  # #awaiting_scheduled_wake? remains the predicate; this is only for the surfaces
  # that want to SAY when — a log line, the MCP queue listing, an operator banner.
  #
  # @return [ActiveSupport::TimeWithZone, nil]
  def pending_wake_at
    pending_one_time_wake_conditions
      .where(condition_type: "schedule")
      .select { |condition| condition.one_time_schedule? && !condition.schedule_due? }
      .filter_map do |condition|
        zone = ActiveSupport::TimeZone[condition.schedule_timezone]
        zone&.parse(condition.scheduled_at.to_s) rescue nil
      end
      .min
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error(
      "[SessionStateMachine] Failed to read the pending wake time for session #{id}: #{e.message}"
    )
    nil
  end

  # How a message names the pause: the time if there is one to name, and a plain
  # statement otherwise. Shared by AgentSessionJob's stand-down log and the
  # `action_session restart` refusal, so a caller refused by one and then reading
  # the other's log sees the same sentence.
  def pending_wake_phrase
    at = pending_wake_at
    at ? "it is paused until #{at.utc.iso8601}" : "it is asleep on a pending wake-up"
  end

  # Whether a manual refresh of this session should send the automated continue
  # nudge (AutomatedPrompts::SYSTEM_RECOVERY) instead of only re-syncing its
  # transcript. Applies to `waiting` sessions that have a conversation to resume
  # and are not deliberately asleep:
  #
  # - a session with no `session_id` has never started, so there is nothing to
  #   continue — the spawn pipeline still owns it;
  # - a session with a wake-up still ahead of it is sleeping on purpose, and
  #   nudging it would fire the work early;
  # - a session dormant in the spot queue is also asleep on purpose, and it has
  #   no wake-up to give it away: nudging one the ceiling paused puts it straight
  #   back on the window that stopped it, and nudging one that was parked there
  #   deliberately undoes the thing that park asked for. Both come back
  #   through SpotSessionPause's sweep — or immediately, on "Make this session
  #   priority". The bulk-refresh path already excluded these; this is the same
  #   rule for a single session.
  def continue_nudge_on_refresh?
    return false unless waiting?
    return false if session_id.blank?
    return false if SpotSessionPause.paused?(self)

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
      # Unconditional, and outside the transition: a live request supersedes
      # whatever the previous one died of, whether or not this session is in a
      # state that can fire block_on_elicitation. A session already needs_input
      # from a normal pause takes no transition here, and would otherwise show a
      # stale "the request was lost" banner directly above a live approval form.
      clear_lost_elicitation_marker
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
  # Stripping the marker alone would still leave a lie on screen: a session parked
  # in needs_input with nothing to say why, indistinguishable from one idling after
  # a normal turn. So a needs_input session also gets a `lost_elicitation` marker
  # naming what happened, which the session page renders as a banner. A `running`
  # session gets the marker cleared only — its agent never stopped, so there is
  # nothing for the user to act on and a banner would be noise.
  #
  # @return [Boolean] true if a stale marker was cleared, false otherwise
  def clear_stale_elicitation_block!
    cleared = false
    surfaced = false
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

      # Written under the same lock as the clear above, so the two metadata
      # writes on this one JSON column can't interleave with a concurrent one.
      # The elicitation named is this session's most recent — the request the
      # stranded marker was almost certainly holding open.
      #
      # The banner is NOT pushed from in here: broadcasting inside the lock would
      # publish HTML for state a rollback could still discard, and its retry
      # backoff would sleep with the row locked.
      if needs_input?
        surfaced = record_lost_elicitation!(
          reason: "stranded",
          elicitation: elicitations.order(:created_at).last,
          broadcast: false
        )
      end
    end
    broadcast_lost_elicitation_banner if surfaced
    cleared
  end

  # Whether this session is still AT REST in `needs_input`, as opposed to having
  # merely passed through it at a turn boundary.
  #
  # Read by AoEventSubject::SessionSubject#stale? once the settle window has
  # elapsed, and it asks about STATUS only. That is deliberate, and it is the
  # narrowest question that does the job:
  #
  # - The turn boundaries this exists to suppress all leave `needs_input` for
  #   somewhere else. A session that slept on its own wake is `waiting` (its
  #   `execute_pending_sleep` runs synchronously inside the pause callback, long
  #   before this is asked); one whose queued message drained is `running` (that
  #   drain is scheduled at EnqueuedMessageDrainJob::DELAY, well inside the
  #   window). Status catches both.
  # - Every richer disqualifier considered — a lingering `pending_sleep`, a
  #   still-pending enqueued message — can only still be true HERE when the thing
  #   that was going to move the session has failed or given up. `sleep!` raised;
  #   the drain exhausted its attempts and left the rows pending; a `skip_reason`
  #   is holding the message indefinitely. Those are exactly the sessions that
  #   are stuck at rest, and a watcher must be told about them. This event is
  #   emitted once and `pause` only fires from `running`, so nothing re-emits it:
  #   suppressing there would not delay the wake, it would lose it for good.
  #
  # The cost is an occasionally early wake — a drain whose first attempt failed
  # resumes the session at DELAY + RETRY_DELAY, just past this window. That trade
  # is the right way round: a wake that arrives seconds early is a re-poll, and a
  # wake that never arrives is a router asleep until its backstop.
  def resting_in_needs_input?
    needs_input?
  end

  # The current value of the counter #bump_needs_input_transition_counter writes.
  def needs_input_transition_count
    custom_metadata&.dig("needs_input_count").to_i
  end

  # True when the pause this session is sitting in — or about to enter — is Zimmer
  # restarting its own interrupted process, rather than the agent finishing a turn.
  #
  # The marker is written by every recovery path immediately before `pause!`:
  # AgentSessionJob's dead-process branch and its GoodJob::InterruptError handler,
  # and SessionRecoveryService#transition_to_needs_input. It is cleared again by
  # `resume` (clear_paused_by_metadata) and by the sweeps' continuation path, which
  # drops the whole of Session::STALE_RETRY_METADATA_KEYS. So it is true for exactly
  # the window in which Zimmer owes this session a restart.
  #
  # NEEDS_INPUT_SETTLE_WINDOW does not cover this on its own, and the arithmetic is
  # the reason this predicate exists. The boundaries that window suppresses leave
  # `needs_input` within microseconds (a self-wake) or ten seconds (a queued-message
  # drain). A recovery pause does not: nothing moves the session until
  # CleanupOrphanedSessionsJob's five-minute cron reaches it, so at settle time it is
  # still sitting in `needs_input` and #resting_in_needs_input? — which asks about
  # status and nothing else, by design — says yes.
  #
  # Deliberately an equality test on "recovery" rather than "anything but a human".
  # The other `paused_by` values are different situations with different audiences:
  # "user" is a human holding the session, "spot_quota" is the spot gate, "mcp_retry"
  # is a delayed retry job. None of them is swept by CleanupOrphanedSessionsJob or
  # DeploymentRecoveryJob, both of which match `paused_by = 'recovery'` exactly — so
  # none of them has the auto-continue promise that makes this suppression safe.
  def recovery_pause?
    metadata&.dig("paused_by") == "recovery"
  end

  # True when the pause this session is entering is Zimmer standing a turn down
  # before the agent ever ran it, rather than a turn finishing.
  #
  # Three markers, three paths, one shape: `paused_by = "recovery"` for a process
  # Zimmer restarted out from under a live turn; `failure_reason =
  # "undelivered_turn"` for a turn that raised during setup, which
  # Sessions::ParkUndeliveredTurn states explicitly writes no `paused_by`; and
  # `auth_outage_reason` for a turn stood down because the account pool was empty.
  # All three reach `pause!` with the prompt undelivered.
  #
  # #retire_held_wake_triggers is the caller, and undelivered is exactly what
  # matters to it: a WOKEN turn that never ran has not had its chance to re-arm,
  # so the wake group handed to it is still the only thing that will wake the
  # session. All three markers are cleared by the resume that follows, so this is
  # true for exactly the window in which the turn is owed a re-run.
  def turn_stood_down_before_it_ran?
    recovery_pause? ||
      metadata&.dig("failure_reason") == Sessions::ParkUndeliveredTurn::FAILURE_REASON ||
      metadata&.dig("auth_outage_reason").present?
  end

  # Announce a `needs_input` the `pause` callback deliberately did not.
  #
  # A recovery pause says nothing to watchers and sends no push, on the promise that
  # a recovery sweep will continue the session. SessionContinuation is where that
  # promise can expire: once it has spent MAX_CONTINUE_ATTEMPTS it drops the marker
  # and stops sweeping, and the session is then resting in the action queue with
  # nobody coming for it. Announcing here is what keeps the carve-out from being able
  # to hide a stuck session — the watcher's wake set survives the flap and still
  # fires, exactly once, at the moment the session became a human's problem.
  #
  # Bumps its own marker rather than taking one, because it is not part of a
  # transition and has no other consumer to share with.
  def announce_deferred_needs_input!
    announce_needs_input(bump_needs_input_transition_counter)
  end

  # Say so when a session whose goal is about opening a pull request reaches a
  # rest state with no PR recorded. Zimmer's GitHub integrations all key off
  # custom_metadata["github_pull_request_urls"], and an empty list looks exactly
  # like a session that had no PR to record — so the warning is the only thing
  # that distinguishes "nothing to do" from "the association never happened".
  # The rule and the wording live with the hook that populates the list.
  #
  # Called from `pause`, `fail` and `archive` — the three transitions after
  # which nothing runs unless a person comes back. `pause` catches the miss
  # while the session can still act on it; `fail` and `archive` catch the
  # sessions `pause` never sees. The hook deduplicates on the warning log
  # itself, so a session that pauses, warns and later archives is warned once,
  # not twice.
  #
  # `pause` skips the call on a recovery pause, which is not a rest state at all
  # (#558). Public because the make-good for that skip is not a transition:
  # SessionContinuation calls this when the recovery promise expires, which is
  # the moment the deferred warning comes due. Since the budget is one warning
  # per session, the call site that spends it decides where in the session's life
  # the warning lands.
  #
  # The rescue is not redundant with the hook's own: the hook's guard cannot
  # cover the constant lookup that reaches it, and on `fail` and `archive` an
  # escaping exception would abort a transition that is cleaning up.
  def warn_if_pr_goal_captured_no_url
    TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(self)
  rescue => e
    Rails.logger.error "[SessionStateMachine] Failed to check for a missing PR URL: #{e.message}"
  end

  # Whether a `needs_input` announcement for this session is being DEFERRED to a
  # recovery sweep, rather than skipped outright. That distinction is the whole
  # safety argument, so it is the question every caller asks.
  #
  # Public because there are two doors into the same wake, and both have to answer
  # it the same way. The `pause` callback asks it at the transition. Trigger's
  # #fire_ao_event_immediately_if_state_matches asks it when a watcher is armed on a
  # session that is ALREADY sitting in the pause — a status-only test there fires the
  # wake the callback just declined to fire, which is the same spurious wake reached
  # a few seconds later.
  #
  # A recovery pause qualifies only when a sweep will actually reach the session.
  # Both CleanupOrphanedSessionsJob and DeploymentRecoveryJob scope every query
  # through Session.not_in_frozen_category, so a session parked in a frozen category
  # is one neither will ever select. AgentSessionJob's two recovery-pause writers do
  # not check the category — they run inside the session's own job rather than in a
  # bulk recovery flow, unlike SessionRecoveryService, which bails on a frozen
  # category before it ever pauses — so this pause really can happen there.
  # Suppressing it would not defer the announcement, it would delete it: no sweep
  # continues the session, so SessionContinuation never runs and the give-up branch
  # that makes the deferred announcement is never reached either. That session is
  # stuck, and stuck is exactly what a watcher has to hear about.
  def announcement_deferred_to_recovery_sweep?
    recovery_pause? && !category&.is_frozen?
  end

  # The tracked PR urls whose last recorded status is not terminal — the PRs this
  # session is still expecting to move. An url with no recorded status counts as
  # unresolved: the poller has not established otherwise yet.
  #
  # Public because two callers need the same answer for opposite reasons. The
  # archive line reports them as PRs that will now never be announced;
  # GitHubPullRequestPollerJob reads them as "this session is waiting on a
  # specific event", which is what stops PollBackoff's idle-decay from applying
  # to a session whose idleness IS the waiting.
  def unresolved_pr_urls
    urls = custom_metadata&.dig("github_pull_request_urls")
    return [] unless urls.is_a?(Array)

    statuses = custom_metadata&.dig("github_pull_request_statuses")
    statuses = {} unless statuses.is_a?(Hash)
    urls.reject { |url| TERMINAL_PR_STATUSES.include?(statuses[url]) }
  end

  private

  # The pause's announcement: the settled `session_needs_input` wake fan-out, and
  # the human's debounced push. Both gate on the same marker — see the "one bump,
  # two consumers" note at the `pause` callback.
  def announce_needs_input(marker)
    fire_settled_needs_input_ao_event(marker)
    enqueue_debounced_needs_input_push_notification(marker)
  end

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
  # ONE failure is not swallowed: an error that left the connection inside a
  # transaction Postgres has aborted. Swallowing exists to let a transition finish
  # with one side effect missing, and on a poisoned connection no transition can
  # finish — the state UPDATE itself rolls back, and every later callback raises
  # `InFailedSqlTransaction` and lands here in turn. Reporting each of them pages
  # once per callback with nothing but consequences, which is exactly what issue
  # #924 was: four ERROR records for one failed SELECT nobody logged. Re-raising
  # lets the first one abort the transition and surface the real cause once.
  #
  # @param operation [Symbol] the callback that failed — pass `__method__`
  # @param error [Exception] the swallowed error
  # @param alert [Boolean] whether this failure also pages #eng-alerts
  def report_swallowed_side_effect(operation, error, alert:)
    if DatabaseTransactionState.aborted_by?(error)
      # Logged before the raise, not instead of it. Whether anything upstream
      # records this depends on who called the transition, and the one seam whose
      # job is to make swallowed failures visible must not have an exit that says
      # nothing.
      Rails.logger.error(
        "[SessionStateMachine] Aborting the transition on session #{id}: #{operation} raised " \
        "#{error.class}: #{error.message}, and the transaction it ran in cannot commit"
      )
      raise error
    end

    begin
      Rails.logger.error(
        "[SessionStateMachine] Failed to #{operation} for session #{id}: #{error.class}: #{error.message}"
      )
      return unless alert

      # Post AFTER the transaction commits. AASM runs `after` callbacks inside the
      # transition's own transaction, and AlertService posts to Slack synchronously
      # (5s connect / 10s read). Alerting inline would hold a transaction open on
      # this row for a network round trip during precisely the incident — a sick
      # database — where that hurts most. after_all_transactions_commit runs the
      # block immediately when no transaction is open, so nothing is deferred that
      # doesn't need to be.
      session_id = id
      ActiveRecord.after_all_transactions_commit do
        AlertService.raise_alert(
          "Session state-machine side effect failed",
          details: "`#{operation}` raised during a state transition and was swallowed, so the " \
                   "transition completed with this side effect missing.\n\n" \
                   "*Session:* #{session_id}\n\n" \
                   "<#{AppUrl.base_url}/sessions/#{session_id}|View session in Zimmer>",
          source: "SessionStateMachine##{operation}",
          dedup_key: "session_state_machine_side_effect_#{operation}",
          # The exception itself, not a hand-copied `e.message`: the backtrace is
          # the high-signal part and it is sitting right here at the rescue.
          error: error
        )
      rescue => alert_error
        # Runs post-commit, outside the outer rescue's reach.
        Rails.logger.error(
          "[SessionStateMachine] Failed to alert on swallowed side effect #{operation}: #{alert_error.message}"
        )
      end
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

  # Tag this session with what every experimental setting is right now.
  #
  # Called from `start` and `resume` and NOWHERE ELSE, because those are the two
  # transitions at which an agent process is about to spawn — and a setting like
  # MCP tool search takes effect in the spawn environment. Observing here records
  # what the session actually ran with. The first call fixes the start-of-life
  # value; every later one moves the end-of-life value, so a setting toggled
  # between two turns shows up as a disagreement between the two.
  #
  # The terminal transitions look like the natural place for the end-of-life
  # value and are the wrong one. `archive` and `fail` fire at bookkeeping
  # moments that can land arbitrarily long after the session last ran —
  # HealthMonitorService#archive_old_sessions archives everything untouched for
  # seven days in a loop — so recording there would re-stamp an old session's end
  # value with today's setting, flip it to `mixed`, and quietly drain the control
  # cohort of the very comparison this exists to support.
  #
  # Does not raise, with one deliberate exception: SessionExperimentalFlag.record!
  # swallows its own errors and this rescue covers the constant lookup that
  # reaches it, because a cohort label is bookkeeping and bookkeeping must not be
  # able to stop a session starting. But a transaction Postgres has already
  # aborted is not a session this can save — the transition is going to roll back
  # whatever happens here — so that one case propagates rather than adding
  # another misleading error to the pile. See DatabaseTransactionState.
  def record_experimental_setting_flags
    SessionExperimentalFlag.record!(self)
  rescue => e
    raise if DatabaseTransactionState.aborted_by?(e)

    Rails.logger.error "[SessionStateMachine] Failed to tag experimental settings: #{e.message}"
  end

  # The archive event's timeline line: who did it, and what it cost.
  #
  # Never raises. It is computed inside the `archive` callback chain, ahead of
  # the trash bookkeeping, so a bad metadata shape here must not be able to take
  # the transition down with it — the plain line is always available.
  def archive_log_message(stranded = [])
    [
      "Session moved to trash by #{archive_actor.presence || ARCHIVE_ACTOR_UNRECORDED}",
      stranded_enqueued_messages_clause(stranded),
      unresolved_pr_clause
    ].compact.join(" — ")
  rescue => e
    Rails.logger.error "[SessionStateMachine] Failed to describe the archive of session #{id}: #{e.message}"
    "Session moved to trash"
  end

  # Come to rest in `needs_input` only with an empty queue.
  #
  # The `needs_input` counterpart of strand_pending_enqueued_messages below, and
  # of Sessions::ArchiveGuard — the same invariant, "a session does not idle on
  # top of a message queued for it", at the other resting state. It differs in
  # what it can do about it. Archiving ends every delivery path, so the honest
  # responses there are to refuse the transition or to record the discard.
  # `needs_input` ends nothing: an idle session is precisely the condition a
  # queued message is waiting for, so the response here is to deliver it.
  #
  # Most pauses never reach this with anything to do. AgentSessionJob drains the
  # queue at each of its four turn-end paths and does it BEFORE `pause!`, so the
  # session hands off while still `running` and never flaps through
  # `needs_input`. That remains the hot path. What it cannot cover is a message
  # enqueued between its read of the queue and this transition committing, and
  # it does not run at all for the pauses that originate elsewhere — the MCP
  # `pause` action, `POST /api/v1/sessions/:id/pause`, the web pause button,
  # Sessions::InterruptService, SessionRecoveryService.
  #
  # Deferred to a job rather than drained inline. AASM runs `after` callbacks
  # inside the transition's own transaction, and delivering means resuming the
  # session — a second AASM event on this object, nested inside the first, plus
  # an AgentSessionJob enqueue — from whatever thread happened to call `pause!`,
  # including a web request. EnqueuedMessageDrainJob does it once the transition
  # is committed and visible, under the same per-session advisory lock
  # Sessions::InterruptService takes, and carries the bounded-retry and
  # give-up-loudly logic that keeps a session which cannot take its message from
  # bouncing between states forever.
  def drain_enqueued_messages_after_pause
    return unless needs_input?
    return unless enqueued_messages.pending.exists?

    # Enqueued after commit, not inline. The job re-reads the session, so it
    # must not run against a transition the transaction has not committed yet —
    # and on the paths where `pause!` is nested inside a caller's own
    # transaction (Sessions::InterruptService holds one across the whole
    # interrupt), inline would mean enqueueing work against a state that may
    # still roll back.
    #
    # The rescue is INSIDE the block as well as around the method, and both are
    # load-bearing: the block runs after this method has returned, so an outer
    # rescue alone cannot see it. Same shape as alert_on_stranded_enqueued_messages.
    session_id = id
    ActiveRecord.after_all_transactions_commit do
      EnqueuedMessageDrainJob.set(wait: EnqueuedMessageDrainJob::DELAY).perform_later(session_id)
    rescue => e
      report_swallowed_side_effect(__method__, e, alert: true)
    end
  rescue => e
    # Alerting: a swallowed failure here puts the session back in exactly the
    # state this callback exists to prevent — idle, with a message queued for
    # it, and nothing coming.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Drop the drain attempt counter when the session gets going again.
  #
  # The counter bounds EnqueuedMessageDrainJob's retries within one idle spell.
  # A session that resumes by any route — the drain itself succeeding, a human
  # follow-up, a recovery sweep — has ended that spell, and a count left over
  # from it would deny a later drain the attempts it is owed.
  def clear_enqueued_drain_attempts
    return unless metadata&.key?(EnqueuedMessageDrainJob::ATTEMPTS_KEY)

    update_column(:metadata, metadata.except(EnqueuedMessageDrainJob::ATTEMPTS_KEY))
  rescue => e
    # Log-only: a stale counter costs a future drain its retries, and the
    # give-up path alerts loudly when that happens.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Retire every message still queued for this session, because archiving has
  # just ended the only path by which one could be delivered.
  #
  # That path is narrow and worth naming: EnqueuedMessageProcessorService claims
  # `pending` rows only, and for a live session the only thing that calls it is
  # AgentSessionJob's end-of-turn drain — which an archived session never
  # reaches, because the monitoring loop sees `archived?` and terminates the
  # process instead of pausing.
  #
  # Leaving those rows `pending` is what made the loss silent. `follow_up`
  # without `force_immediate` auto-queues onto a running session and answers
  # "Message queued (session is running). It will be sent when the agent
  # completes its current task" — a promise, not a receipt. When the turn it
  # queued behind is the session's last (goals routinely tell an agent to
  # self-archive once its work is done), the promise is already false when it is
  # made, and every later reader of the queue still sees `pending` and reads it
  # as "on its way". Production session 6073: a user's second Slack message
  # queued behind their first, the session archived at the end of that same
  # turn, and the message sat `pending` in a queue nobody would ever drain.
  #
  # `undelivered` is terminal, so the queue can no longer misreport itself. The
  # archive line names what was lost and an alert fires, so the sender's belief
  # that delivery was coming is corrected rather than left standing.
  #
  # @return [Array<EnqueuedMessage>] the messages retired, for the archive line
  def strand_pending_enqueued_messages
    candidate_ids = enqueued_messages.pending.ordered.pluck(:id)
    return [] if candidate_ids.empty?

    # One guarded statement rather than a loop of validating `update!`s. Two
    # reasons, and both are about not lying on the archive line. A loop aborts
    # part-way on the first row that fails validation — a legacy row longer than
    # today's PROMPT_MAX_LENGTH is enough — leaving some rows retired and the
    # line naming none of them. And a row the processor claims between the
    # SELECT and the write would still be named as never delivered when it was
    # in fact delivered; re-reading only the rows the `status: "pending"` guard
    # actually moved is what makes the line describe what happened.
    enqueued_messages
      .where(id: candidate_ids, status: "pending")
      .update_all(status: "undelivered", updated_at: Time.current)

    stranded = enqueued_messages.where(id: candidate_ids, status: "undelivered").ordered.to_a
    return [] if stranded.empty?

    # Every retired row is returned for the archive line. Only the ones nobody
    # read before they were discarded are worth waking someone for.
    #
    # `force` is the whole discriminator, and it is the only thing Zimmer knows
    # about the caller's intent at this point. Sessions::ArchiveGuard refuses an
    # archive over a non-empty queue and prints every queued message in the
    # refusal, and the refusal says in as many words that force is for a caller
    # that has read them — so `force: true` is the caller ASSERTING it read the
    # queue and is discarding it deliberately. That is an accepted loss rather
    # than a silent one, and paging a human about a loss they authorized is what
    # turned one sanctioned spot-queue cleanup into seven pages — and seven
    # router sessions — on 2026-08-29. The forced branch records instead: the
    # rows retire, the archive line names them, and record_strand_ledger leaves a
    # queryable entry on the log plane.
    #
    # It is an assertion, not a proof, and the gap is worth naming: every surface
    # skips the guard entirely when `force` is set, so a caller that sends it on
    # its FIRST call was never refused and never shown anything. On a batch the
    # flag covers every session in it. Nothing here can tell those apart from a
    # caller that answered a refusal — which is why the record is the answer and
    # silence is not. `force` is deliberately hard to reach by accident: it is
    # off by default, named last in the refusal, and hedged in its own schema
    # description.
    #
    # An UNFORCED strand is the failure this alert was built for, and stays at
    # full volume for every message somebody is waiting on. The system-initiated
    # archives (HealthMonitorService's stale sweep, the status-summary fork
    # cleanup, SessionStatusSummaryHarvestJob) never consult the guard, so on
    # those paths nobody has read anything — which is how the mis-credited-PR bug
    # behind #555 was found, via a status-summary fork that inherited its source's
    # PR and was archived by the harvest job.
    #
    # The one thing subtracted from that branch is a message Zimmer addressed to
    # the session itself and the archive answers: the recovery nudge. Nobody wrote
    # it and nobody is waiting on a reply, so there is no reader to discover the
    # loss from and nothing about it is still true afterwards — see
    # EnqueuedMessage::SELF_ADDRESSED_ORIGINS, which is deliberately one origin
    # long and deliberately excludes automated_pr_merged. This is a subtraction
    # from the PAYLOAD, not from the retirement or the archive line, and a queue
    # holding anything else still pages and says how many nudges it left out.
    if archive_forced
      record_strand_ledger(stranded, forced: true)
    else
      self_addressed, awaited = stranded.partition(&:self_addressed?)
      alert_on_stranded_enqueued_messages(awaited, suppressed: self_addressed.size) if awaited.any?
      # Written whenever anything was suppressed, not only when the whole queue
      # was. A nudge dropped from a MIXED queue is discarded-without-paging just
      # as much as one dropped from a queue of its own, and the ledger's question
      # is fleet-wide — "what has been discarded without paging, and why?" — so
      # answering it for one of those two cases and not the other would leave the
      # grep quietly incomplete. The alert body's footnote is per session and does
      # not answer it.
      record_strand_ledger(self_addressed, forced: false) if self_addressed.any?
    end
    stranded
  rescue => e
    # Alerting: this is the callback whose whole job is to stop a dropped
    # message being silent, so it failing silently is the original defect again.
    report_swallowed_side_effect(__method__, e, alert: true)
    []
  end

  # The stranded-queue clause of the archive line.
  #
  # Rides on that line for the same reason unresolved_pr_clause does: someone
  # asking "where did my message go?" is already reading this session's
  # timeline. The previews are bounded — the full content stays on the row,
  # readable through the REST index and the MCP list, which now report it as
  # `undelivered` rather than `pending`.
  def stranded_enqueued_messages_clause(stranded)
    return nil if stranded.blank?

    subject = stranded.one? ? "1 queued message was" : "#{stranded.size} queued messages were"
    previews = stranded.map { |message| message.content.to_s.truncate(120).inspect }.join(", ")
    "#{subject} never delivered and #{stranded.one? ? 'is' : 'are'} now marked undelivered: #{previews}"
  rescue => e
    Rails.logger.error "[SessionStateMachine] Failed to describe stranded messages for session #{id}: #{e.message}"
    nil
  end

  # Page on a retired queue.
  #
  # Deliberately not filtered down to the mid-turn shape that caused #6073. A
  # human trashing a session they had queued a message onto is a quieter case,
  # but it is still a message that was accepted and never delivered, and the
  # only alternative to paging is discovering the next one from a user noticing.
  #
  # The one caller that does not reach here is a forced archive — see the branch
  # in strand_pending_enqueued_messages. Not because those messages matter less,
  # but because the guard already put them in front of the caller and the caller
  # accepted the loss; there is no user left to discover it from.
  #
  # The dedup key is per session, which bounds repeats for one session — an
  # archive, unarchive and re-archive pages once — and deliberately does NOT
  # collapse across sessions: a sweep that archives N sessions with queues has
  # lost N distinct messages, and one alert standing in for all of them is the
  # summary that hides the other N-1. HealthMonitorService#archive_old_sessions
  # is the sweep that could make that plural; a queue on a session untouched for
  # seven days is rare enough that the honest count is worth its noise.
  #
  # Posted after commit, for the reason report_swallowed_side_effect explains:
  # AlertService talks to Slack synchronously, and an AASM `after` callback runs
  # inside the transition's own transaction.
  def alert_on_stranded_enqueued_messages(stranded, suppressed: 0)
    # Guarded here rather than at the call site, so nothing can build a
    # zero-count page — the same self-guarding shape stranded_enqueued_messages_clause has.
    return if stranded.blank?

    session_id = id
    previews = stranded.map { |message| "- #{message.content.to_s.truncate(200)}" }.join("\n")
    count = stranded.size
    # Named rather than dropped silently, so the page and the archive line cannot
    # disagree about how many rows this archive retired. Without it a mixed queue
    # would page about "1 message" beside an archive line naming two, and the
    # reader would have no way to tell a suppression from a bug.
    footnote =
      if suppressed.positive?
        "\n\n(#{suppressed} automated recovery nudge#{"s" if suppressed > 1} Zimmer had addressed to " \
        "this session #{suppressed > 1 ? "were" : "was"} also retired by this archive and " \
        "#{suppressed > 1 ? "are" : "is"} not counted above: nobody wrote #{suppressed > 1 ? "them" : "it"} " \
        "and nobody was waiting on a reply.)"
      else
        ""
      end

    ActiveRecord.after_all_transactions_commit do
      AlertService.raise_alert(
        "Queued messages stranded by an archive",
        details: "Session #{session_id} was archived with #{count} message(s) still queued. They were " \
                 "never delivered and are now marked `undelivered`; whoever queued them was told they " \
                 "would be sent. Nobody was shown them before they were discarded: this archive " \
                 "answered no refusal from Sessions::ArchiveGuard.\n\n#{previews}#{footnote}\n\n" \
                 "<#{AppUrl.base_url}/sessions/#{session_id}|View session in Zimmer>",
        source: "SessionStateMachine#strand_pending_enqueued_messages",
        dedup_key: "stranded_enqueued_messages_#{session_id}"
      )
    rescue => e
      Rails.logger.error(
        "[SessionStateMachine] Failed to alert on stranded messages for session #{session_id}: #{e.message}"
      )
    end
  end

  # The ledger entry a strand leaves instead of a page.
  #
  # The session's own timeline already carries the human-readable version on the
  # archive line, and the rows themselves are readable as `undelivered` through
  # the REST index and the MCP list. What neither of those answers is the
  # fleet-wide question — "what has been discarded without paging, and why, since
  # Tuesday?" — because both are per session. This line is that answer: one
  # grep-able tag, the session, the actor, and each row's id and origin.
  #
  # Two branches reach it, and `forced=` is what tells them apart in a grep:
  #
  # - `forced: true` — the caller answered Sessions::ArchiveGuard's refusal and
  #   accepted the loss. What was discarded could have been anything.
  # - `forced: false` — nobody was refused, but every retired row was a message
  #   Zimmer had addressed to this session itself (see
  #   EnqueuedMessage::SELF_ADDRESSED_ORIGINS). Nothing was lost, so there is
  #   nothing to page about; the line exists so "nothing was lost" is a claim
  #   somebody can audit rather than an absence.
  #
  # `warn` rather than `error`, deliberately. Neither of those is a fault, and
  # the obs plane's `Zimmer backend logging errors (excludes staging)` rule pages
  # on ERROR and FATAL — writing this at `error` would move the page rather than
  # remove it.
  #
  # Deferred to after commit for the same reason the page is: the entry claims
  # an archive happened, and a transition that rolls back after this callback
  # would make that claim false.
  def record_strand_ledger(stranded, forced:)
    return if stranded.blank?

    session_id = id
    actor = archive_actor.presence || ARCHIVE_ACTOR_UNRECORDED
    count = stranded.size
    # Bounded like every other rendering of a retired queue here — the previews
    # at 200 chars on the page, at 120 on the archive line. `retired=` carries
    # the true count, so a queue too long to list still reports its size.
    listed = stranded.first(STRAND_LEDGER_IDS_LOGGED)
    rows = listed.map { |message| "##{message.id}(#{message.origin})" }.join(" ")
    rows += " +#{count - listed.size} more" if count > listed.size
    reason =
      if forced
        "the caller passed `force`, which asserts it read the queue and is discarding it " \
        "deliberately. Recorded rather than paged: the loss was authorized."
      else
        "every retired row was a notice Zimmer had addressed to this session itself. Recorded " \
        "rather than paged: nobody wrote them and nobody was waiting on a reply."
      end

    ActiveRecord.after_all_transactions_commit do
      Rails.logger.warn(
        "[StrandedQueue] session=#{session_id} forced=#{forced} actor=#{actor.inspect} " \
        "retired=#{count} messages=#{rows} — #{reason}"
      )
    rescue => e
      Rails.logger.error(
        "[SessionStateMachine] Failed to record the strand on session #{session_id}: #{e.message}"
      )
    end
  rescue => e
    # Log-only. Losing this line costs an audit convenience; the discard itself
    # is still on the archive line and on the rows, and no page was owed here.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # The pull requests this session opened that Zimmer never saw reach a terminal
  # state, named on the archive line.
  #
  # Archiving is what removes a session from GitHubPullRequestPollerJob's scope
  # (`with_github_prs` excludes archived and failed sessions), so it also ends any chance
  # of the merge message the PR goals in config/goals.json promise: "the
  # pull-request poller sends this session a message when the PR merges, and
  # THAT MESSAGE IS YOUR SIGNAL TO ARCHIVE". A session archived first never
  # gets it, and nothing else records that the promise died.
  #
  # This rides on the archive line rather than raising a warning of its own,
  # deliberately. A merge gate archives the producing session within seconds of
  # merging — well inside the poller's 30-second cadence — so an unresolved PR
  # at archive is the common case, not an anomaly worth alerting on. What it is
  # worth is a sentence in the one place someone asking "where did my session
  # go?" is already looking.
  def unresolved_pr_clause
    unresolved = unresolved_pr_urls
    return nil if unresolved.empty?

    subject = unresolved.one? ? "1 tracked pull request had" : "#{unresolved.size} tracked pull requests had"
    pronoun = unresolved.one? ? "it" : "them"
    "#{subject} not reached a terminal state, so no merge notification will be delivered for #{pronoun}: " \
      "#{unresolved.join(', ')}"
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

  # The custom_metadata keys a resume drops outright. Each one is a verdict the
  # PREVIOUS run reached, and the new one has to reach it for itself.
  STALE_MCP_FAILURE_KEYS = %w[
    should_fail_session
    mcp_connection_checked
    mcp_failed_servers
    mcp_failure_reason
  ].freeze

  # Drop what Sessions::ParkUndeliveredTurn stamped, now that the session is
  # running again.
  #
  # The park records its outcome in `failure_reason`, which no resume path clears —
  # so without this the marker outlives the turn that earned it, and the NEXT
  # ordinary pause would render "This turn stopped before the agent started" on a
  # session that had just completed a turn perfectly well. Scoped to a row whose
  # `failure_reason` is exactly the park's own, so it can never eat another
  # failure's record.
  def clear_undelivered_turn_park
    return unless metadata&.dig("failure_reason") == Sessions::ParkUndeliveredTurn::FAILURE_REASON

    remove_metadata!(Sessions::ParkUndeliveredTurn::METADATA_KEYS)
  rescue => e
    # Log-only: the consequence is a stale failure line on the session page, which
    # the next park or failure overwrites. Nothing persistent is left inconsistent.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # Reset the MCP metadata a resuming session must not inherit from its last run.
  #
  # The failure flags in STALE_MCP_FAILURE_KEYS are dropped. Without that, the new
  # job would immediately see the old should_fail_session=true and fail again
  # before its servers had any chance to connect.
  #
  # `mcp_servers_status` is RESET to `pending` rather than dropped (#465). Its
  # entries do all have to go — a `connected` recorded by the process that just
  # exited says nothing about the one about to start — but the key itself must
  # stay: the REST API and the get_session MCP tool hand `custom_metadata` back
  # verbatim, so an absent key reads as "no servers configured" rather than
  # "configured, and this run has not connected them yet", which is what `pending`
  # says. McpStatusPersisting upgrades each entry as the detector's evidence
  # arrives, and it is the only writer that ever does — so a key dropped here is
  # gone for the whole of a turn that never gets far enough to reach it.
  #
  # The reset spans the union of the servers this session has wired and the names
  # already in the hash. Taking `all_mcp_servers` alone would hand the key's
  # survival to a catalog read that fails soft: `plugin_mcp_servers` returns []
  # when the AIR catalog cannot be resolved, so a blip at resume time would empty
  # the reset for a plugin-only session and delete the key — reproducing the
  # defect on the path meant to fix it. A name that is genuinely gone is pruned by
  # #forget_mcp_server_status! on the removal path, and every view renders chips
  # from the session's own server list rather than from these keys.
  def clear_stale_mcp_failure_metadata
    current = custom_metadata || {}
    keys_to_clear = STALE_MCP_FAILURE_KEYS & current.keys
    previous_status = current["mcp_servers_status"] || {}
    reset_status = (previous_status.keys | all_mcp_servers).index_with { Session::MCP_STATUS_PENDING }

    # Nothing to drop and the floor is already what is stored: skip the UPDATE
    # rather than re-issue an identical one on every resume.
    return if keys_to_clear.empty? && previous_status == reset_status

    # The atomic merge, not a whole-column write: it touches only the keys named
    # here, so a status a still-draining poller writes between the read above and
    # this line is not erased along with the flags. It also re-dispatches the
    # session-card broadcast that a raw UPDATE would swallow, and like
    # `update_column` it runs no validations or save callbacks — which is what
    # makes it safe inside an AASM transition callback.
    if reset_status.empty?
      merge_custom_metadata!({}, STALE_MCP_FAILURE_KEYS + [ "mcp_servers_status" ])
    else
      merge_custom_metadata!({ "mcp_servers_status" => reset_status }, STALE_MCP_FAILURE_KEYS)
    end

    Rails.logger.info "[SessionStateMachine] Reset MCP metadata for session #{id} on resume " \
                      "(cleared: #{keys_to_clear.presence&.join(', ') || 'none'}; " \
                      "mcp_servers_status floored to pending for: #{reset_status.keys.presence&.join(', ') || 'none'})"
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

    # A sleep intent recorded by the system-recovery preserve branch is only
    # valid while the wake-ups it was recorded for are still armed. They may not
    # be: a backstop whose wall time elapsed during the outage is due the moment
    # recovery resumes the session, so it can fire mid-recovery-turn, destroy its
    # siblings, and hand off to a new turn without ever pausing. Sleeping on that
    # stale intent would put the session in `waiting` with nothing armed and no
    # `paused_by` — invisible to both recovery sweeps, which is a worse stall than
    # the one this preserve branch exists to prevent. Drop the intent instead and
    # let the session come to rest in needs_input, where the operator can see it.
    if metadata[PENDING_SLEEP_REQUIRES_WAKE] && !armed_one_time_wake?
      update_column(:metadata, metadata.except("pending_sleep", PENDING_SLEEP_REQUIRES_WAKE))
      Rails.logger.info(
        "[SessionStateMachine] Dropped the preserved re-sleep for session #{id} — its wake-ups " \
        "fired or were destroyed during the recovery turn, so sleeping would strand it"
      )
      return
    end

    sleep!
    update_column(:metadata, metadata.except("pending_sleep", PENDING_SLEEP_REQUIRES_WAKE))
  rescue => e
    # Alert: the session asked to sleep and did not. It sits in needs_input on
    # the user's homepage as if it wanted attention, and the pending_sleep flag
    # survives to surprise-sleep it after some later turn.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Cancel any pending one-time wake-up conditions that were targeting this
  # session. When a session is deliberately resumed (user follow-up,
  # force_immediate, restart, or the trigger itself firing), these conditions
  # should not fire again on an already-active session.
  #
  # We "consume" each matching condition by setting last_triggered_at = now,
  # which makes the firing path skip it. The trigger itself stays enabled (it
  # may have other conditions).
  #
  # Two resumes are exceptions, and both leave the wake-ups armed:
  #
  # - A SYSTEM-RECOVERY resume takes the preserve branch. The session did not
  #   choose to wake, so its wake-ups are not moot. See #system_recovery_resume.
  # - A WAKE-FIRE resume takes the hold branch. The wake-ups ARE moot, but only
  #   once the woken turn has actually run — consuming them here, before it has,
  #   is the no-trigger window of
  #   https://github.com/tadasant/zimmer/issues/569. See
  #   #hold_pending_one_time_wakes.
  #
  # Scoped to: conditions on triggers where this session is the reuse target,
  # that haven't fired yet, and that are one-time wake-ups — either a one-time
  # schedule (scheduled_at present) or a session-scoped ao_event
  # (watched_session_id present). Recurring schedules and broadcast ao_events
  # are left alone.
  def cancel_pending_one_time_wake_triggers
    conditions = pending_one_time_wake_conditions.select do |condition|
      condition.one_time_schedule? || condition.session_scoped_ao_event?
    end
    return if conditions.empty?

    return preserve_pending_one_time_wakes(conditions) if system_recovery_resume
    return hold_pending_one_time_wakes(conditions) if wake_fire_resume

    conditions.each do |condition|
      condition.update!(last_triggered_at: Time.current)
      Rails.logger.info(
        "[SessionStateMachine] Cancelled pending one-time wake-up " \
        "(trigger_condition #{condition.id}) for resumed session #{id}"
      )
    end

  rescue => e
    # Don't raise — trigger bookkeeping failures shouldn't block the resume. But
    # do alert: on the cancel branch an uncancelled one-time wake stays armed and
    # fires later against an already-active session, injecting a wake-up prompt
    # into live work; on the preserve branch a session that should have gone back
    # to sleep comes to rest in needs_input instead; on the hold branch the group
    # is left armed and unmarked, so nothing retires it at the end of the turn and
    # it fires into a later, unrelated wait.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Leave a system-recovered session's wake-ups armed, and put it back to sleep
  # afterwards when doing so cannot strand it.
  #
  # The re-sleep is deliberately conditional. A one-time schedule fires at a wall
  # time no matter what else happens, so a session holding one is guaranteed to
  # be woken and can safely go back to `waiting`. A session holding only
  # session-scoped ao_event watchers has no such guarantee: a watched session may
  # have reached the state being watched for during the outage, and that
  # transition is not replayed, so sleeping on it would trade a 22-hour stall for
  # an indefinite one. Those sessions come to rest in `needs_input` instead —
  # visible on the operator's homepage, with the watchers still armed, because
  # Trigger#follow_up_session! delivers to a needs_input session just as well.
  def preserve_pending_one_time_wakes(conditions)
    # A one-time schedule only backstops the re-sleep if it can still fire. One
    # whose moment passed unfired is the shape that strands a session rather than
    # waking it, and treating it as a guarantee is what would put the session
    # straight back to sleep on nothing.
    backstopped = conditions.any? do |condition|
      condition.one_time_schedule? && self.class.one_time_wake_pending?(condition)
    end

    if backstopped
      # Paired with PENDING_SLEEP_REQUIRES_WAKE: this sleep intent is only good
      # while something is still armed to undo it. A deliberate sleep (the API's
      # sleep_session, which arms nothing) carries no such marker and is executed
      # unconditionally.
      update_column(:metadata, (metadata || {}).merge(
        "pending_sleep" => true,
        PENDING_SLEEP_REQUIRES_WAKE => true
      ))
    end

    Rails.logger.info(
      "[SessionStateMachine] Preserved #{conditions.size} pending wake-up(s) across a " \
      "system-recovery resume of session #{id} " \
      "(trigger_conditions #{conditions.map(&:id).join(', ')}); " \
      "#{backstopped ? 'will return to waiting after this turn' : 'will rest in needs_input — no one-time schedule backstop among them'}"
    )

    logs.create!(
      content: "Recovered from a system interruption with #{conditions.size} wake-up(s) still armed — " \
        "#{backstopped ? 'returning to waiting after this turn' : 'no scheduled backstop, so this session will rest in needs_input'}",
      level: "info"
    )
  end

  # Hold this session's wake group across the turn a wake just woke it for.
  #
  # THE WINDOW THIS CLOSES (#569). A fired wake used to void the rest of its
  # group at fire time, in two places at once: this callback consumed every
  # pending one-time wake condition aimed at the session, and the firing job then
  # destroyed the sibling trigger rows. Both ran BEFORE the woken turn had done
  # anything. Re-arming is the woken turn's job and happens at the END of that
  # turn, so between the fire and a successful re-arm the session held nothing at
  # all — and a turn interrupted anywhere in there (deploy restart, killed
  # process, transient failure) left it asleep with no wake, looking exactly like
  # a session sleeping correctly. In the filed instance a 04:52 deadline backstop
  # was voided by a 04:18 fire and the session sat inert until an orphan sweep
  # found it 4.5 hours later.
  #
  # Holding leaves the conditions unfired and the triggers `enabled` — they can
  # still fire, which is the whole point — and marks the trigger rows
  # `wake_held_at` so #retire_held_wake_triggers knows which rows belong to the
  # wait that just ended rather than to a wait the woken turn has since armed.
  #
  # What holding is NOT is a licence for a stale wake to survive its wait. The
  # group is retired at the end of any turn that completes normally, which is the
  # same moment the old code's destroy amounted to, one turn later.
  def hold_pending_one_time_wakes(conditions)
    # Only a trigger that is NOTHING BUT one-shot wakes can be held, because
    # holding hands the whole ROW to #retire_held_wake_triggers, which destroys
    # it. A trigger mixing an unfired one-shot with a recurring schedule or a
    # Slack condition does other work the requester's next pause has no business
    # deleting — Trigger#hold_wake_group! and CleanupStaleTriggersJob both make
    # the same distinction. Its one-shot is consumed as before.
    held, consumed = conditions.partition { |condition| condition.trigger&.one_time_reuse_trigger? }

    consumed.each { |condition| condition.update!(last_triggered_at: Time.current) }
    return if held.empty?

    held_at = Time.current
    Trigger.where(id: held.map(&:trigger_id).uniq)
           .update_all(wake_held_at: held_at, updated_at: held_at)

    Rails.logger.info(
      "[SessionStateMachine] Held #{held.size} pending one-time wake-up(s) across the woken " \
      "turn of session #{id} (trigger_conditions #{held.map(&:id).join(', ')}) — they stay " \
      "armed until this turn comes to rest" \
      "#{consumed.any? ? "; consumed #{consumed.size} on trigger(s) that do other work" : ''}"
    )
  end

  # Retire the wake group a fire held across this turn.
  #
  # The other half of #hold_pending_one_time_wakes, and the half that keeps
  # holding from becoming an accumulation of stale wakes. A turn that reached a
  # normal rest is a turn that got to re-arm whatever it wanted; anything still
  # carrying `wake_held_at` belongs to the wait that woke it and has no business
  # firing into the next one. Wakes the turn armed for itself carry no mark and
  # are untouched.
  #
  # A `failed` trigger is exempt for the same reason it is exempt everywhere else:
  # it is the record of a wake that tried and could not, and it is the user's to
  # clear.
  #
  # Called from `pause` and `archive`, and deliberately NOT from `fail`. A failed
  # session is not reliably a finished one — CleanupOrphanedSessionsJob recovers
  # `failed` sessions carrying `GoodJob::InterruptError` or the recovery marker,
  # which is an interrupted turn wearing a different status — so retiring there
  # would re-open the window for that path. The cost is that a group held on a
  # session that stays failed lingers: it clears as its conditions spend, on the
  # deliberate resume of a restart, or when the session is archived, and
  # CleanupStaleTriggersJob collects it once every one-shot is consumed.
  def retire_held_wake_triggers
    held = Trigger.where(last_session_id: id, reuse_session: true)
                  .where.not(wake_held_at: nil)
                  .where.not(status: "failed")
    ids = held.pluck(:id)
    return if ids.empty?

    Trigger.where(id: ids).destroy_all
    Rails.logger.info(
      "[SessionStateMachine] Retired #{ids.size} held wake trigger(s) (#{ids.join(', ')}) for " \
      "session #{id} — the turn they were held across has come to rest"
    )
  rescue => e
    # Alert: swallowed, the held group stays armed with nothing left to retire it,
    # and one of its members fires into whatever the session is doing next — the
    # stale-wake regression that holding exists to avoid.
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Whether any one-time wake-up is still armed against this session — asked with
  # the same "can it fire" reading as #awaiting_scheduled_wake?, not the looser
  # "is there an unfired row".
  #
  # #execute_pending_sleep gates a preserved sleep intent on this, and the two
  # readings differ exactly where it matters: a session stranded on a wake that
  # has lapsed, or that watches a session which will never transition again, would
  # answer true to the looser one, re-sleep on the strength of it, and be stranded
  # again by the very resume sent to rescue it. That is the loop StrandedSleepRescue
  # would otherwise spend its whole budget on.
  #
  # Rescued to FALSE, which is the opposite direction from #awaiting_scheduled_wake?
  # and deliberately so. That one is asked about a session already at rest, where
  # "asleep on purpose" is the answer that leaves it alone; this one gates a
  # re-sleep, where the safe answer is to not go back to sleep. A session that
  # comes to rest in `needs_input` because the trigger table was briefly
  # unreadable is visible on the homepage; one that sleeps on a wake nobody could
  # confirm is not.
  def armed_one_time_wake?
    conditions = pending_one_time_wake_conditions.to_a
    watched = self.class.watched_session_statuses(conditions)
    conditions.any? do |condition|
      (condition.one_time_schedule? || condition.session_scoped_ao_event?) &&
        self.class.one_time_wake_pending?(condition, watched_statuses: watched)
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error(
      "[SessionStateMachine] Failed to check armed wake-ups for session #{id}: #{e.message}"
    )
    false
  end

  # Unfired trigger conditions that could still wake this session: conditions on
  # triggers where this session is the reuse target, that haven't fired yet.
  # Callers still filter to the one-time shapes (one-time schedule or
  # session-scoped ao_event) — recurring schedules and broadcast ao_events are
  # not per-session wake-ups and are left alone.
  def pending_one_time_wake_conditions
    TriggerCondition
      .joins(:trigger)
      .includes(:trigger)
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

  # Re-render the lost-elicitation banner slot on any open session page. The
  # partial renders nothing when the marker is absent, so the same call both
  # raises and dismisses the banner. Guarded: a broadcast failure must not fail
  # the reconciliation that produced it.
  def broadcast_lost_elicitation_banner
    BroadcastService.new.lost_elicitation_banner(self)
  rescue => e
    Rails.logger.error "[SessionStateMachine] Failed to broadcast lost elicitation banner for session #{id}: #{e.message}"
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
    rescue => e
      # The rescue belongs INSIDE the block. after_all_transactions_commit defers
      # this body past the transition's transaction, so a method-level rescue
      # would only ever catch a failure to *register* the callback — never the
      # enqueue itself, which is the failure that matters and the one this
      # callback already suffered silently once (see the NoMethodError note
      # above). A swallowed enqueue means every watcher of this session misses
      # the transition, with nothing to retry it.
      report_swallowed_side_effect(__method__, e, alert: true)
    end
  rescue => e
    # Don't raise - trigger failures shouldn't block state transitions.
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

  # Settle window for `session_needs_input` wake-ups — the same idea as
  # NEEDS_INPUT_DEBOUNCE, applied to the trigger fan-out rather than to pushes.
  #
  # `pause` is emitted at every turn boundary, and a turn boundary is not a rest.
  # A healthy session that is asleep on its own `wake_me_up_later` wakes, takes a
  # turn, and sleeps again: `running → needs_input → waiting`, with the
  # `needs_input` leg lasting microseconds because `execute_pending_sleep` runs
  # inside this very callback. A session with a queued message does the same in
  # reverse via EnqueuedMessageDrainJob (its DELAY is 10s, comfortably inside this
  # window). Firing a watcher's wake on those legs woke it to learn nothing, and
  # cost it a full agent turn plus the re-registration of every sibling wake the
  # fire destroyed — the "flap storm".
  #
  # Shorter than the push debounce on purpose: a wake is latency-sensitive in a
  # way a phone notification is not (AoEventTriggerJob runs on its own queue for
  # exactly that reason), and the flaps this suppresses resolve in well under a
  # second. Only `session_needs_input` is settled; `session_failed` and
  # `session_archived` are terminal, cannot flap, and still fire immediately.
  NEEDS_INPUT_SETTLE_WINDOW = 30.seconds

  # Fire `session_needs_input` wake-ups once the session has actually come to
  # rest there, rather than the instant it crosses the state.
  #
  # Two mechanisms, because the flap has both a synchronous and an asynchronous
  # form. The wait window covers the asynchronous one; the marker covers a
  # session that churns through further transitions inside the window. Both are
  # re-checked by AoEventSubject::SessionSubject#stale? at execution time, which
  # is the only place that can see where the session actually ended up.
  def fire_settled_needs_input_ao_event(marker)
    session_id = id
    ActiveRecord.after_all_transactions_commit do
      AoEventTriggerJob
        .set(wait: NEEDS_INPUT_SETTLE_WINDOW)
        .perform_later("session_needs_input", session_id, marker)
    rescue => e
      # Inside the block for the same reason as fire_ao_event_triggers: the body
      # is deferred past this transaction, so a method-level rescue would only
      # see a failure to register the callback. A swallowed enqueue means every
      # watcher of this session misses the transition.
      report_swallowed_side_effect(:fire_settled_needs_input_ao_event, e, alert: true)
    end
  rescue => e
    report_swallowed_side_effect(__method__, e, alert: true)
  end

  # Enqueue a debounced needs_input push notification.
  #
  # The transition counter in custom_metadata lets the deferred job detect
  # whether the session has churned through additional state changes during the
  # wait window. If a flap (resume → pause) happens during the window, the
  # original job's marker won't match the new counter and the job will no-op;
  # the new pause will schedule its own debounced job.
  #
  # The marker is passed in rather than bumped here, because the wake fan-out
  # debounces against the same counter and one transition must produce one bump.
  #
  # A nil marker means the bump failed, and the push is then skipped rather than
  # sent un-markered. SendPushNotificationJob's `stale_needs_input_transition?`
  # does not gate at all on a nil marker, so enqueuing one would push 60 seconds
  # later even if the session had long since flapped back to `running` — which is
  # both the thing the debounce exists to prevent and worse than the behaviour
  # before this counter had two consumers, where a failed bump meant no push.
  def enqueue_debounced_needs_input_push_notification(marker)
    return if marker.nil?
    return unless push_notifications_enabled?

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

  # Increment and persist the needs_input transition counter, returning the new
  # value. Used as the debounce marker by both deferred consumers — the wake
  # fan-out and the push job. The counter is monotonic across the session's
  # lifetime; it is never reset on resume, so values are unique per transition
  # but not minimal.
  #
  # Called directly from the `pause` callback rather than from inside one of its
  # consumers, so it needs its own rescue: an unguarded raise here would wedge
  # the transition, which is the one thing a side effect must never do. Nil
  # degrades both consumers to their un-markered behaviour — the wake still
  # settles on state, the push still gates on state — rather than losing them.
  def bump_needs_input_transition_counter
    metadata_hash = custom_metadata.presence || {}
    next_count = metadata_hash["needs_input_count"].to_i + 1
    update_column(:custom_metadata, metadata_hash.merge("needs_input_count" => next_count))
    next_count
  rescue => e
    # Log-only: the wake still settles on state, which is the check doing the real
    # suppression, and the push is skipped entirely — see the guard in
    # #enqueue_debounced_needs_input_push_notification for why it must not be
    # sent un-markered.
    report_swallowed_side_effect(__method__, e, alert: false)
    nil
  end

  # Enqueue SessionTitleJob (which both titles and categorizes) when either
  # piece of work is still pending. Firing on a pause/fail transition runs it
  # promptly once a transcript exists — the strongest signal for both the title
  # and the category. Also catches sessions created without a prompt (e.g.
  # clone-only sessions that later received one), where the after_create_commit
  # callback skipped enqueuing because the prompt was blank at creation time.
  #
  # Coalesced per session: a SessionTitleJob already queued and unclaimed for
  # this session reads the transcript when it runs, so a second one behind it
  # would only find the work done. (One already running took its snapshot when
  # it started and does not count.) A session that stays uncategorized (the inference
  # answered NONE) re-enqueues on every pause for as long as that holds, and
  # without this check a session sleeping and waking on a short self-wake
  # stacks one title job per wake — see PendingSessionJob.
  def enqueue_session_inference_if_needed
    title_pending = metadata&.dig("auto_generated_title") == true
    category_pending = category_id.blank? && prompt.present? && Category.where(is_frozen: false).exists?
    return unless title_pending || category_pending
    return if PendingSessionJob.queued?(SessionTitleJob, id)

    SessionTitleJob.perform_later(id)
  rescue => e
    # Log-only: a missing title or category is cosmetic, and the next pause or
    # fail transition re-runs this for as long as either is still pending.
    report_swallowed_side_effect(__method__, e, alert: false)
  end

  # The automatic trigger for the Status panel's blurb: the session coming to
  # rest, at needs_input or failed. Those are the moments the summary is about —
  # "where things stand" is a question you ask of a session that has stopped —
  # and the moments the operator is most likely to read it next.
  #
  # Still no polling, no generate-on-page-view and no generate-per-message: this
  # is the only place a generation is started for a session that is doing fine.
  # StatusSummaryBackstopJob is the repair path behind it, and it only touches a
  # session already at rest whose last generation demonstrably did not land — a
  # job lost to a deploy, a fork parked out of quota, a claim abandoned past
  # PENDING_TIMEOUT. Without it a session in the action queue has no further
  # transition to try again on, so one lost generation is permanent.
  #
  # The generator itself still refuses when the session has not moved since the
  # last summary, so a transition that adds no transcript costs nothing.
  #
  # Coalesced per session at this site only: a SessionStatusSummaryJob already
  # queued and unclaimed for this session — automatic or forced — computes the
  # line count it summarizes when it claims the record, so it will cover this
  # transition's transcript too, and a second copy would only claim an
  # `inference` thread to return "Summary is current". One already running took
  # its snapshot when it started and does not count; the fresh enqueue then
  # meets its claim and returns after a SELECT. The forced surfaces (Regenerate in the panel,
  # REST, MCP) do not pass through here and are never coalesced — see
  # SessionStatusSummaryJob for why a queue-level dedup key would be wrong.
  def enqueue_status_summary_refresh
    return if transcript.blank?
    return if PendingSessionJob.queued?(SessionStatusSummaryJob, id)

    SessionStatusSummaryJob.perform_later(id)
  rescue => e
    Rails.logger.error "[SessionStateMachine] Failed to enqueue status summary refresh: #{e.message}"
    # Don't raise - summary enqueue failures shouldn't block state transitions
  end

  # A summary fork has finished its single turn; lift its answer onto the source
  # session and archive it.
  def harvest_status_summary(failed: false)
    SessionStatusSummaryHarvestJob.perform_later(id, failed: failed)
  rescue => e
    Rails.logger.error "[SessionStateMachine] Failed to enqueue status summary harvest: #{e.message}"
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

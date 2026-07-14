# frozen_string_literal: true

# Trigger represents a "trigger flow" — a session template that can be fired
# by one or more trigger conditions (OR semantics).
#
# When ANY of its conditions fire, the trigger creates or reuses a session
# using its configured session template (agent_root, prompt, MCP servers, etc.).
class Trigger < ApplicationRecord
  STATUSES = %w[enabled disabled].freeze

  # --- Burst control -------------------------------------------------------
  #
  # `max_sessions_per_minute` caps how many NEW sessions a trigger may spawn in
  # a rolling one-minute window. NULL means unbounded (the pre-existing
  # behavior, and the default for every trigger).
  #
  # Once the cap is exceeded the trigger enters a *burst*: it spawns exactly one
  # burst-notice session (linking the sessions it did spawn in the window) and
  # then spawns nothing at all until the burst subsides. A burst is "over" once
  # BURST_COOLDOWN passes with no further spawn attempt — every suppressed
  # attempt pushes `burst_active_until` forward, so an outage that keeps
  # producing events for an hour keeps the trigger quiet for that hour and still
  # yields exactly ONE notice, not one per tick.
  #
  # BURST_COOLDOWN is deliberately several times the poll cadence, NOT one minute.
  # The pollers tick every minute, so a one-minute cooldown expires exactly as the
  # next tick's events arrive: the burst would "end", the cap would refill, and a
  # sustained outage would produce a fresh batch of sessions and a fresh notice
  # every minute — the stream of notices this control exists to prevent. Five
  # quiet minutes is the boundary of one burst.
  BURST_WINDOW = 1.minute
  BURST_COOLDOWN = 5.minutes

  # Cap on how many session links the burst-notice prompt carries. A sane limit
  # is small, but nothing stops an operator setting it to 500.
  MAX_BURST_NOTICE_LINKS = 25

  # How much of the event that tipped the cap to quote in the notice prompt.
  BURST_NOTICE_PROMPT_EXCERPT = 500

  belongs_to :last_session, class_name: "Session", optional: true
  has_many :trigger_conditions, dependent: :destroy
  accepts_nested_attributes_for :trigger_conditions, allow_destroy: true, reject_if: :all_blank

  validates :name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :agent_root_name, presence: true
  validates :prompt_template, presence: true
  validates :trigger_conditions, presence: { message: "must have at least one condition" }
  validates :max_sessions_per_minute,
    numericality: { only_integer: true, greater_than: 0 },
    allow_nil: true
  validate :catalog_skills_must_be_array
  validate :catalog_skills_must_exist_in_catalog, if: :catalog_skills_changed?
  validate :catalog_hooks_must_be_array
  validate :catalog_hooks_must_exist_in_catalog, if: :catalog_hooks_changed?
  validate :catalog_plugins_must_be_array
  validate :catalog_plugins_must_exist_in_catalog, if: :catalog_plugins_changed?

  before_validation :clear_enqueue_messages_without_reuse_session
  before_validation :clear_resuscitate_archived_without_reuse_session
  validate :validate_enqueue_messages_requires_reuse_session
  validate :validate_resuscitate_archived_requires_reuse_session
  validate :validate_last_session_requires_reuse_session, on: :create
  validate :validate_watched_session_not_requester, on: :create

  # When a trigger is created with a target session and a one-time schedule,
  # automatically transition the target session into the waiting (dormant)
  # state. This is the "per-session wake-up" path: API callers can schedule a
  # trigger for a specific session and the session is moved off the user's
  # action queue until the trigger fires (or the user resumes manually).
  after_create :sleep_target_session_if_applicable

  # When a trigger is created with a session-scoped ao_event condition whose
  # watched session is ALREADY in the target state, fire the wake immediately.
  # See #fire_ao_event_immediately_if_state_matches for atomicity guarantees.
  after_create :fire_ao_event_immediately_if_state_matches

  scope :enabled, -> { where(status: "enabled") }
  scope :disabled, -> { where(status: "disabled") }

  # Scopes that filter by condition type (returns triggers that have at least one condition of that type)
  scope :with_slack_conditions, -> { joins(:trigger_conditions).where(trigger_conditions: { condition_type: "slack" }).distinct }
  scope :with_schedule_conditions, -> { joins(:trigger_conditions).where(trigger_conditions: { condition_type: "schedule" }).distinct }
  scope :with_ao_event_conditions, -> { joins(:trigger_conditions).where(trigger_conditions: { condition_type: "ao_event" }).distinct }
  scope :with_github_conditions, -> { joins(:trigger_conditions).where(trigger_conditions: { condition_type: TriggerCondition::GITHUB_CONDITION_TYPES }).distinct }

  def enabled?
    status == "enabled"
  end

  def disabled?
    status == "disabled"
  end

  def enable!
    update!(status: "enabled")
  end

  def disable!
    update!(status: "disabled")
  end

  def toggle!
    if enabled?
      disable!
    else
      enable!
    end
  end

  # Returns the condition types present on this trigger
  def condition_types
    trigger_conditions.pluck(:condition_type).uniq
  end

  # Human-readable summary of all conditions
  def conditions_summary
    trigger_conditions.map(&:description).join(" OR ")
  end

  # Variables that require user input during manual invocation
  # ({{time}} and {{date}} are auto-populated)
  USER_INPUT_VARIABLES = %w[link text author channel event repo number title labels].freeze

  # The variables that IDENTIFY which GitHub item a session was fired for.
  #
  # Deliberately not the full set a GitHub condition can fill in. {{text}}, {{author}} and
  # {{event}} are also the Slack variables, so a trigger with both a Slack and a GitHub
  # condition and a template like "New message: {{text}}" would look like it names GitHub
  # context while telling the session nothing about which PR it is looking at. Only these
  # three actually pin down the item, so only these three suppress the context block.
  GITHUB_IDENTITY_VARIABLES = %w[link repo number].freeze

  # Returns the user-input variable names used in this trigger's prompt template
  def prompt_variables
    USER_INPUT_VARIABLES.select { |var| prompt_template.include?("{{#{var}}}") }
  end

  # Whether this trigger's template identifies the GitHub item on its own.
  def references_github_context?
    GITHUB_IDENTITY_VARIABLES.any? { |var| prompt_template.include?("{{#{var}}}") }
  end

  # Interpolate variables into the prompt template
  # Supported variables: {{link}}, {{text}}, {{author}}, {{channel}}, {{time}}, {{date}},
  # {{event}}, and — for GitHub conditions — {{repo}}, {{number}}, {{title}}, {{labels}}
  def interpolate_prompt(link: nil, text: nil, author: nil, channel: nil, event: nil,
                         repo: nil, number: nil, title: nil, labels: nil)
    result = prompt_template.dup
    result.gsub!("{{link}}", link.to_s) if result.include?("{{link}}")
    result.gsub!("{{text}}", text.to_s) if result.include?("{{text}}")
    result.gsub!("{{author}}", author.to_s) if result.include?("{{author}}")
    result.gsub!("{{channel}}", channel.to_s) if result.include?("{{channel}}")
    result.gsub!("{{time}}", Time.current.strftime("%H:%M")) if result.include?("{{time}}")
    result.gsub!("{{date}}", Time.current.strftime("%Y-%m-%d")) if result.include?("{{date}}")
    result.gsub!("{{event}}", event.to_s) if result.include?("{{event}}")
    result.gsub!("{{repo}}", repo.to_s) if result.include?("{{repo}}")
    result.gsub!("{{number}}", number.to_s) if result.include?("{{number}}")
    result.gsub!("{{title}}", title.to_s) if result.include?("{{title}}")
    result.gsub!("{{labels}}", Array(labels).join(", ")) if result.include?("{{labels}}")
    result
  end

  # Create a new session from this trigger's template, or reuse an existing one.
  #
  # Returns the session that was created or reused, or nil when nothing was
  # created: the trigger is burst-suppressed (see #spawn_with_burst_control!),
  # or a one-time reuse trigger's target session is gone. Callers must handle
  # nil.
  def create_session!(prompt:)
    @last_fire_burst_suppressed = false

    # Heal any catalog references that no longer exist before creating or
    # reusing a session. Each heal method persists the fix so subsequent
    # fires won't encounter the same issue.
    heal_stale_mcp_servers!
    heal_stale_catalog_skills!
    heal_stale_catalog_hooks!
    heal_stale_catalog_plugins!
    heal_stale_agent_root!

    if reuse_session && last_session_id.present?
      session = Session.find_by(id: last_session_id)
      if session && reusable_session?(session)
        return follow_up_session!(session, prompt: prompt)
      end

      # Resuscitate archived sessions: unarchive and then follow up
      if session && resuscitate_archived && session.archived?
        resuscitate_session!(session)
        return follow_up_session!(session, prompt: prompt)
      end

      # One-time reuse triggers are semantically "act on this specific session at
      # this time." If the session isn't reusable (user archived it, resumed it
      # manually, etc.), skip silently — there's nothing else to do.
      if one_time_reuse_trigger?
        Rails.logger.info "[Trigger#create_session!] Skipping one-time reuse trigger #{id} — target session #{last_session_id} is not reusable (status: #{session&.status || 'not found'})"
        return session
      end
    end

    spawn_with_burst_control!(prompt: prompt)
  end

  # True when this trigger is currently inside a burst it has already noticed:
  # every spawn attempt is suppressed until the burst subsides.
  def bursting?
    burst_active_until.present? && burst_active_until > Time.current
  end

  # Whether the most recent #create_session! call on this in-memory instance was
  # dropped by burst control. Callers use this to distinguish "nothing spawned
  # because we're rate-limited" from "nothing spawned because the target session
  # was gone."
  def last_fire_burst_suppressed?
    @last_fire_burst_suppressed == true
  end

  # A one-time reuse trigger is one where reuse_session is enabled and ALL
  # conditions are one-time schedules or session-scoped ao_events. These are
  # semantically "act on this specific session at this time/state" — if the
  # session isn't available, don't create a new one.
  def one_time_reuse_trigger?
    reuse_session &&
      trigger_conditions.any? &&
      trigger_conditions.all? { |c| c.one_time_schedule? || c.session_scoped_ao_event? }
  end

  # Outcome of the most recent #follow_up_session! call on this in-memory
  # trigger instance. One of:
  #   :delivered             — session was resumed and a job was enqueued
  #   :queued                — message was added to the session's enqueued_messages
  #   :skipped_pending_exists — a pending enqueued message already existed; no-op
  #   :dropped               — could not deliver (recurring trigger + busy session
  #                            + enqueue_messages disabled)
  #   nil                    — #follow_up_session! was not called on this instance
  #
  # Callers (AoEventTriggerJob, ScheduleTriggerJob) use this to decide whether
  # destroying sibling wake triggers is safe. If the wake was dropped, the
  # siblings may yet deliver and must not be cleaned up. See the race-window
  # comment in #follow_up_session! for the full motivation.
  attr_reader :last_follow_up_status

  # True when the most recent #follow_up_session! call ran but failed to
  # deliver or queue the prompt — i.e., the wake-up was silently dropped.
  # Returns false (not nil) when follow_up_session! wasn't called.
  def last_follow_up_dropped?
    @last_follow_up_status == :dropped
  end

  # When a one-time wake fires, sibling wakes scheduled against the same
  # requester session are now moot — the requester has already been resumed,
  # so the other "wake me up when X" triggers will never have anything useful
  # to do. Destroys all OTHER one-time-reuse triggers that target the same
  # last_session_id and returns the count destroyed (for logging).
  #
  # This implements the "triple-wake plus deadline backstop" cleanup pattern:
  # agents typically schedule needs_input + failed + archived + a deadline
  # backstop sibling group, and only one of them ever fires usefully.
  def destroy_sibling_wakes!
    return 0 unless one_time_reuse_trigger?
    return 0 if last_session_id.blank?

    siblings = Trigger
      .where(last_session_id: last_session_id, reuse_session: true)
      .where.not(id: id)
      .includes(:trigger_conditions)
      .to_a
      .select(&:one_time_reuse_trigger?)

    return 0 if siblings.empty?

    sibling_ids = siblings.map(&:id)
    Trigger.where(id: sibling_ids).destroy_all
    sibling_ids.size
  end

  private

  def clear_enqueue_messages_without_reuse_session
    self.enqueue_messages = false unless reuse_session
  end

  def validate_enqueue_messages_requires_reuse_session
    if enqueue_messages && !reuse_session
      errors.add(:enqueue_messages, "can only be enabled when re-use session is enabled")
    end
  end

  def clear_resuscitate_archived_without_reuse_session
    self.resuscitate_archived = false unless reuse_session
  end

  def validate_resuscitate_archived_requires_reuse_session
    if resuscitate_archived && !reuse_session
      errors.add(:resuscitate_archived, "can only be enabled when re-use session is enabled")
    end
  end

  # Validation is scoped to :create because create_new_session! updates
  # last_session_id on every fire regardless of reuse_session (it tracks the
  # most recently spawned session for potential reuse). Re-running this check
  # on update would block that internal bookkeeping.
  def validate_last_session_requires_reuse_session
    if last_session_id.present? && !reuse_session
      errors.add(:last_session_id, "can only be set when re-use session is enabled")
    end
  end

  # A session cannot watch itself for state changes — the auto-sleep would
  # never resolve cleanly because the requester would have to transition
  # itself into the watched state to resume itself. This complements the
  # client-side guard in the wake_me_up_when_session_changes_state MCP tool
  # so the rejection is enforced consistently regardless of caller path.
  def validate_watched_session_not_requester
    return if last_session_id.blank?

    requester_id = last_session_id.to_i
    trigger_conditions.each do |condition|
      next unless condition.session_scoped_ao_event?
      if condition.watched_session_id == requester_id
        errors.add(:base, "watched_session_id cannot equal last_session_id (a session cannot watch itself)")
        return
      end
    end
  end

  # Transition the target session to waiting when a per-session wake-up trigger
  # is created (reuse_session + last_session_id + at least one one-time schedule
  # OR a session-scoped ao_event condition).
  #
  # - needs_input → waiting (immediate sleep via state machine)
  # - running     → pending_sleep metadata flag; the pause callback transitions
  #                 the session to waiting when the current turn completes
  # - waiting/failed/archived → no-op (session is already dormant or terminal)
  #
  # Failures are logged but never raised — the trigger itself has already been
  # persisted by the time this callback runs, and losing the auto-sleep shouldn't
  # kill the trigger.
  def sleep_target_session_if_applicable
    return unless enabled?
    return unless reuse_session && last_session_id.present?

    # Only auto-sleep for "targeted wake-up" triggers: at least one condition
    # is a one-time schedule, or a session-scoped ao_event (watched_session_id
    # set). Slack/recurring-schedule/broadcast ao_event triggers shouldn't
    # transition the session to waiting — those can fire repeatedly and
    # shouldn't block user interaction.
    #
    # Note: this runs in after_create, when the in-memory trigger_conditions
    # association has the nested attributes loaded. Do not switch this to a
    # DB query (e.g., trigger_conditions.where(...)) without checking that
    # the conditions are persisted at this point.
    return unless trigger_conditions.any? { |c| c.one_time_schedule? || c.session_scoped_ao_event? }

    session = Session.find_by(id: last_session_id)
    return unless session

    if session.needs_input?
      session.sleep!
      session.logs.create!(
        content: "[Trigger##{id}] Session transitioned to waiting for scheduled wake-up",
        level: "info"
      )
    elsif session.running?
      session.update!(metadata: (session.metadata || {}).merge("pending_sleep" => true))
      session.logs.create!(
        content: "[Trigger##{id}] pending_sleep set — session will transition to waiting after current turn",
        level: "info"
      )
    else
      Rails.logger.info(
        "[Trigger#sleep_target_session_if_applicable] Skipping auto-sleep for trigger #{id} — " \
        "target session #{session.id} is in #{session.status} state"
      )
    end
  rescue => e
    Rails.logger.error(
      "[Trigger#sleep_target_session_if_applicable] Failed to auto-sleep session #{last_session_id} " \
      "for trigger #{id}: #{e.class}: #{e.message}"
    )
  end

  # When a trigger has session-scoped ao_event conditions whose watched
  # sessions are ALREADY in the target state at trigger-creation time, fire
  # the wake immediately rather than waiting for a future transition that
  # may never come. This closes a footgun where, e.g., a requester registers
  # a session_needs_input watcher on a session that has already paused — the
  # transition has already happened, so the trigger would otherwise sleep
  # forever (or until a deadline backstop fires).
  #
  # Atomicity: each watched session row is locked (FOR UPDATE) inside this
  # callback, which runs INSIDE the trigger creation's transaction. Any
  # concurrent state transition on the watched session either:
  #   - committed BEFORE we acquire the lock → we see the new state and fire
  #     immediately (the transition's own AoEventTriggerJob ran before our
  #     trigger existed and so didn't pick it up)
  #   - acquires the lock AFTER us, after we commit → the transition's
  #     AoEventTriggerJob runs after our trigger is committed and fires it
  #     via the normal path
  # Both paths converge on the same firing pipeline (AoEventTriggerJob),
  # which is one-shot per session-scoped condition (last_triggered_at guard),
  # so a duplicate enqueue from both paths is harmless.
  #
  # The fire-immediately path enqueues AoEventTriggerJob with the watched
  # session id and event_name — the same job the state-machine transition
  # callbacks use — so there's no parallel firing implementation.
  #
  # Failures are logged but never raised: losing the immediate fire shouldn't
  # destroy the trigger that has already been persisted.
  def fire_ao_event_immediately_if_state_matches
    return unless enabled?

    matching_conditions = trigger_conditions.select(&:session_scoped_ao_event?)
    return if matching_conditions.empty?

    matching_conditions.each do |condition|
      watched_id = condition.watched_session_id
      event_name = condition.ao_event_name
      target_status = ao_event_target_status(event_name)
      next unless target_status

      watched_session = Session.lock.find_by(id: watched_id)
      next unless watched_session

      next unless watched_session.status.to_s == target_status

      Rails.logger.info(
        "[Trigger#fire_ao_event_immediately_if_state_matches] " \
        "Watched session #{watched_id} already in '#{target_status}' state at " \
        "trigger creation — firing trigger #{id} immediately for condition #{condition.id}"
      )

      ActiveRecord.after_all_transactions_commit do
        AoEventTriggerJob.perform_later(event_name, watched_id)
      end
    end
  rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
    # Routine, self-resolving: the regular state-machine transition path will
    # enqueue the same AoEventTriggerJob whenever the watched session next
    # transitions, so missing the immediate-fire optimization is not broken
    # behavior. Log at .info per project logging philosophy.
    Rails.logger.info(
      "[Trigger#fire_ao_event_immediately_if_state_matches] Lock contention " \
      "for trigger #{id}; deferring to normal transition path: " \
      "#{e.class}: #{e.message}"
    )
  rescue => e
    Rails.logger.error(
      "[Trigger#fire_ao_event_immediately_if_state_matches] Failed for trigger #{id}: " \
      "#{e.class}: #{e.message}"
    )
  end

  def ao_event_target_status(event_name)
    case event_name
    when "session_needs_input" then "needs_input"
    when "session_failed" then "failed"
    when "session_archived" then "archived"
    end
  end

  def reusable_session?(session)
    return false unless session.needs_input? || session.running? || session.waiting?

    # Don't reuse sessions that a user has manually paused/taken control of
    return false if session.metadata&.dig("paused_by") == "user"

    true
  end

  def follow_up_session!(session, prompt:)
    # Sync MCP servers, catalog skills, hooks, and plugins to match current
    # trigger configuration. A trigger that declares none of a given artifact
    # never clears the session's — see #sync_session_artifact!.
    sync_mcp_servers!(session)
    sync_catalog_skills!(session)
    sync_catalog_hooks!(session)
    sync_catalog_plugins!(session)

    @last_follow_up_status = :dropped

    # Use transaction with row-level locking to prevent race conditions.
    # The state check and state change must happen atomically, matching the
    # pattern in GithubCommentPollerJob and EnqueuedMessageProcessorService.
    ActiveRecord::Base.transaction do
      session.lock!

      if session.needs_input? || session.waiting?
        # Reset SIGTERM retry state for fresh execution
        # (matches SessionsController#follow_up and GithubCommentPollerJob pattern)
        if session.metadata&.dig("sigterm_retry_count").present?
          session.update!(
            metadata: (session.metadata || {}).except(
              "sigterm_retry_count",
              "sigterm_retry_timestamps",
              "last_sigterm_at"
            )
          )
        end

        # Transition session to running before enqueuing the job.
        # This matches the pattern used by SessionsController#follow_up and
        # EnqueuedMessageProcessorService - the session must be running when
        # AgentSessionJob picks up the follow-up prompt.
        session.resume! if session.may_resume?

        # Store pending prompt in metadata for recovery if job is interrupted
        # (matches SessionsController#follow_up and GithubCommentPollerJob pattern)
        session.update!(
          metadata: (session.metadata || {}).merge("pending_follow_up_prompt" => prompt)
        )

        AgentSessionJob.enqueue_with_prompt(session.id, prompt)
        @last_follow_up_status = :delivered
      elsif session.running?
        # Wake-up triggers (one_time_reuse_trigger?) must deliver durably across
        # the race window between "watched session transitions" and "requester's
        # current turn ends". Without queuing here, a wake that fires while the
        # requester is still running gets silently dropped — and if the caller
        # destroys sibling wakes on what it thinks is a successful fire, the
        # requester loses every wake it scheduled. Wake-ups are one-shot signals,
        # not recurring drumbeats, so the `enqueue_messages` flag's "don't barge
        # a busy session" intent does not apply to them.
        should_enqueue = enqueue_messages || one_time_reuse_trigger?

        if !should_enqueue
          Rails.logger.info "[Trigger#follow_up_session!] Skipping enqueue for trigger #{id} - enqueue_messages is disabled and session #{session.id} is still running"
          # :dropped (set above)
        elsif session.enqueued_messages.pending.exists?
          Rails.logger.info "[Trigger#follow_up_session!] Skipping enqueue for trigger #{id} - session #{session.id} already has pending enqueued messages"
          # Pending message already exists — the watched event is effectively
          # represented by that pending message (or by an earlier wake that
          # already queued one). Treat as a successful no-op so the caller can
          # safely clean up siblings.
          @last_follow_up_status = :skipped_pending_exists
        else
          next_position = (session.enqueued_messages.maximum(:position) || 0) + 1
          session.enqueued_messages.create!(
            content: prompt,
            position: next_position,
            status: "pending"
          )
          @last_follow_up_status = :queued
        end
      end

      # Bookkeeping-only write: skip validations/callbacks. This advances
      # last_triggered_at without re-running create-time/presence validations
      # (e.g. `validates :trigger_conditions, presence:`). Those validations are
      # irrelevant to a tracking-timestamp bump and, worse, can spuriously raise
      # RecordInvalid in a benign race: a sibling wake firing concurrently can
      # call #destroy_sibling_wakes!, which destroys this trigger and
      # cascade-deletes its conditions (has_many ..., dependent: :destroy) out
      # from under this still-in-memory instance. A full-validation save! would
      # then see zero conditions and raise. update_columns issues a direct
      # UPDATE (a no-op if the row is already gone), matching the heal_* methods
      # which deliberately use update_column for the same reason.
      update_columns(last_triggered_at: Time.current)
    end

    session
  end

  # Update the session's MCP servers to match the trigger's current configuration.
  # For running sessions, this only takes effect on the next process spawn,
  # not on the currently running process.
  def sync_mcp_servers!(session)
    sync_session_artifact!(session, :mcp_servers, mcp_servers)
  end

  # Update the session's catalog skills to match the trigger's current configuration.
  # For running sessions, this only takes effect on the next process spawn.
  def sync_catalog_skills!(session)
    sync_session_artifact!(session, :catalog_skills, catalog_skills)
  end

  # Update the session's catalog hooks to match the trigger's current configuration.
  # For running sessions, this only takes effect on the next process spawn.
  def sync_catalog_hooks!(session)
    sync_session_artifact!(session, :catalog_hooks, catalog_hooks)
  end

  # Update the session's catalog plugins to match the trigger's current configuration.
  # For running sessions, this only takes effect on the next process spawn.
  def sync_catalog_plugins!(session)
    sync_session_artifact!(session, :catalog_plugins, catalog_plugins)
  end

  # Push one artifact list from this trigger onto a session it is reusing.
  #
  # Two invariants, both learned from the session-9563 incident, in which a
  # one-time wake trigger (created by the `wake_me_up_later` /
  # `wake_me_up_when_session_changes_state` self-session tools, which never send
  # artifact params, so every jsonb column defaults to `[]`) fired against a
  # live session and stripped the MCP servers it had been provisioned with:
  #
  # 1. An EMPTY trigger list never overwrites a non-empty session list. "The
  #    trigger declares no servers" means "this trigger has nothing to say about
  #    servers", not "this session should have no servers". Clearing a live
  #    session's artifacts is never the intent of a trigger fire, and there is a
  #    dedicated endpoint (PATCH /sessions/:id/mcp_servers) for users who really
  #    do want to remove them.
  #
  # 2. Any NARROWING — a sync that removes artifacts the session currently has —
  #    is logged at WARN. A session losing its tools is broken system behavior
  #    that will not self-resolve, so per the repo's logging philosophy it must
  #    be noisy rather than silent.
  #
  # A trigger that DOES declare a non-empty list is still authoritative for that
  # artifact, so recurring UI-authored triggers keep syncing as configured.
  def sync_session_artifact!(session, attribute, desired)
    current = session.public_send(attribute) || []
    desired = desired || []

    return if current == desired
    return if desired.empty? && current.present?

    removed = current - desired
    if removed.any?
      Rails.logger.warn(
        "[Trigger#sync_session_artifact!] Trigger '#{name}' (ID: #{id}) is removing " \
        "#{attribute} #{removed.inspect} from session #{session.id} on reuse. " \
        "Session will run without them after its next process spawn."
      )
    end

    session.update!(attribute => desired)
  end

  def resuscitate_session!(session)
    result = UnarchiveSessionService.call(session: session)
    unless result.success?
      raise "Failed to resuscitate archived session #{session.id}: #{result.error}"
    end
    session.reload
  end

  def catalog_skills_must_be_array
    return if catalog_skills.nil? || catalog_skills.is_a?(Array)

    errors.add(:catalog_skills, "must be an array")
  end

  def catalog_skills_must_exist_in_catalog
    return if catalog_skills.nil? || !catalog_skills.is_a?(Array)

    non_blank_skills = catalog_skills.reject(&:blank?)
    invalid_skills = non_blank_skills.reject { |name| SkillsConfig.exists?(name) }
    return if invalid_skills.empty?

    errors.add(:catalog_skills, "contains invalid skill(s): #{invalid_skills.join(', ')}")
  end

  def catalog_hooks_must_be_array
    return if catalog_hooks.nil? || catalog_hooks.is_a?(Array)

    errors.add(:catalog_hooks, "must be an array")
  end

  def catalog_hooks_must_exist_in_catalog
    return if catalog_hooks.nil? || !catalog_hooks.is_a?(Array)

    non_blank_hooks = catalog_hooks.reject(&:blank?)
    invalid_hooks = non_blank_hooks.reject { |name| HooksConfig.exists?(name) }
    return if invalid_hooks.empty?

    errors.add(:catalog_hooks, "contains invalid hook(s): #{invalid_hooks.join(', ')}")
  end

  def catalog_plugins_must_be_array
    return if catalog_plugins.nil? || catalog_plugins.is_a?(Array)

    errors.add(:catalog_plugins, "must be an array")
  end

  def catalog_plugins_must_exist_in_catalog
    return if catalog_plugins.nil? || !catalog_plugins.is_a?(Array)

    non_blank_plugins = catalog_plugins.reject(&:blank?)
    invalid_plugins = non_blank_plugins.reject { |id| PluginsConfig.exists?(id) }
    return if invalid_plugins.empty?

    errors.add(:catalog_plugins, "contains invalid plugin(s): #{invalid_plugins.join(', ')}")
  end

  # The burst-control gate. Every path that would SPAWN a session funnels
  # through here; follow-ups into a reused session don't, because they spawn
  # nothing (and a reuse trigger tops out at one session by construction).
  #
  # Three outcomes:
  #   :allowed    — under the cap; spawn as usual and record the session so the
  #                 notice, if one follows, can link it.
  #   :burst      — this fire would exceed the cap. Spawn ONE burst-notice
  #                 session instead of the session the event asked for.
  #   :suppressed — the burst is already open and noticed. Spawn nothing. The
  #                 event is dropped (Slack's cursor still advances), which is
  #                 the point: the operator gets one session to investigate a
  #                 burst, not a session per event in it.
  def spawn_with_burst_control!(prompt:)
    case reserve_burst_slot!
    when :suppressed
      @last_fire_burst_suppressed = true
      Rails.logger.info(
        "[Trigger#create_session!] Trigger '#{name}' (ID: #{id}) is burst-suppressed " \
        "(cap: #{max_sessions_per_minute}/min, burst open until #{burst_active_until&.iso8601}) — " \
        "dropping this fire; the burst notice has already been sent"
      )
      nil
    when :burst
      spawn_burst_notice_session!(triggering_prompt: prompt)
    else
      session = create_new_session!(prompt: prompt)
      record_burst_window_session!(session)
      session
    end
  end

  # Atomically decide whether this fire may spawn. The read-modify-write of the
  # window counters happens under a row lock, so two jobs firing the same
  # trigger concurrently (ScheduleTriggerJob and AoEventTriggerJob can overlap)
  # cannot both reserve the last slot.
  #
  # The slot is reserved BEFORE the session exists, so a spawn that then raises
  # still consumes budget. That errs toward under-spawning, which is the safe
  # direction for a control whose whole job is to bound spawns.
  def reserve_burst_slot!
    return :allowed if max_sessions_per_minute.blank?

    with_lock do
      now = Time.current

      # Burst already open and noticed: stay quiet, and hold it open as long as
      # events keep arriving. This is what makes an hour-long outage produce one
      # notice instead of one per minute.
      if burst_active_until.present? && burst_active_until > now
        update_columns(burst_active_until: now + BURST_COOLDOWN, updated_at: now)
        next :suppressed
      end

      # Start a fresh window when the current one has aged out, or when a burst
      # has expired (BURST_COOLDOWN passed with no attempt — the burst is over).
      if burst_window_started_at.blank? ||
         burst_window_started_at <= now - BURST_WINDOW ||
         burst_active_until.present?
        reset_burst_window!(now)
      end

      if burst_window_count >= max_sessions_per_minute
        update_columns(burst_active_until: now + BURST_COOLDOWN, updated_at: now)
        next :burst
      end

      update_columns(burst_window_count: burst_window_count + 1, updated_at: now)
      :allowed
    end
  end

  def reset_burst_window!(now)
    update_columns(
      burst_window_started_at: now,
      burst_window_count: 0,
      burst_window_session_ids: [],
      burst_active_until: nil,
      updated_at: now
    )
  end

  # Record a spawned session against the current window so a burst notice can
  # link the sessions the operator now has to deal with.
  def record_burst_window_session!(session)
    return if max_sessions_per_minute.blank? || session.blank?

    with_lock do
      ids = ((burst_window_session_ids || []) + [ session.id ]).uniq.last(MAX_BURST_NOTICE_LINKS)
      update_columns(burst_window_session_ids: ids, updated_at: Time.current)
    end
  end

  # The one session a burst produces. It deliberately does NOT:
  #   - update last_session_id (a reuse trigger must never follow up INTO the
  #     notice session), or
  #   - carry the trigger's goal (the trigger's goal describes the work the
  #     event asked for; this session's job is to investigate the burst).
  def spawn_burst_notice_session!(triggering_prompt:)
    session = Session.create_from_agent_root!(
      agent_root_name: agent_root_name,
      prompt: burst_notice_prompt(triggering_prompt: triggering_prompt),
      mcp_servers: mcp_servers,
      catalog_skills: catalog_skills,
      catalog_hooks: catalog_hooks,
      catalog_plugins: catalog_plugins,
      metadata: { trigger_id: id, trigger_name: name, burst_notice: true }
    )

    update_columns(last_triggered_at: Time.current)
    Trigger.update_counters(id, sessions_created_count: 1)

    # A trigger hitting its cap is not routine: something is generating events
    # far faster than the operator expected, and it will not self-resolve.
    Rails.logger.warn(
      "[Trigger#create_session!] Trigger '#{name}' (ID: #{id}) exceeded its cap of " \
      "#{max_sessions_per_minute} session(s)/minute — spawned burst-notice session #{session.id} " \
      "and suppressed further spawns until the burst subsides. Sessions spawned in this window: " \
      "#{burst_window_session_ids.inspect}"
    )

    session
  end

  def burst_notice_prompt(triggering_prompt:)
    base = AppUrl.base_url
    links = burst_window_session_ids.map { |session_id| "- #{base}/sessions/#{session_id}" }
    links = [ "- (none — the cap was hit on the first fire of the window)" ] if links.empty?
    excerpt = triggering_prompt.to_s.truncate(BURST_NOTICE_PROMPT_EXCERPT)

    <<~PROMPT
      ⚠️ Burst detected — this session exists because the trigger "#{name}" (ID: #{id}) hit its rate cap.

      The trigger is capped at #{max_sessions_per_minute} session(s) per minute. More events than that arrived
      inside one minute, so Zimmer stopped spawning a session per event and spawned this one
      instead. Until the burst subsides (no further events for #{BURST_COOLDOWN.inspect}), this trigger
      spawns nothing at all, and the events that arrive in the meantime are dropped — not queued,
      not replayed. You will not get another burst notice for this burst.

      Sessions this trigger spawned in this window before it hit the cap:
      #{links.join("\n")}

      Trigger: #{base}/triggers/#{id}

      The event that tipped the cap (truncated):
      ```
      #{excerpt}
      ```

      Something is producing far more events than usual — an outage, a retry storm, a runaway
      producer. Investigate: look at the sessions above and the events behind them, work out what is
      generating the volume, and report what you find. Do NOT do the work for every event
      individually, and do not re-spawn the suppressed ones.
    PROMPT
  end

  def create_new_session!(prompt:)
    session = Session.create_from_agent_root!(
      agent_root_name: agent_root_name,
      prompt: prompt,
      mcp_servers: mcp_servers,
      catalog_skills: catalog_skills,
      catalog_hooks: catalog_hooks,
      catalog_plugins: catalog_plugins,
      goal: goal,
      metadata: { trigger_id: id, trigger_name: name }
    )

    # Track the session for potential reuse. Bookkeeping-only write: skip
    # validations/callbacks (same rationale as #follow_up_session!). Avoids
    # re-running create-time/presence validations on an internal tracking
    # update that may race with concurrent sibling-wake cleanup.
    update_columns(last_session_id: session.id, last_triggered_at: Time.current)

    # Update trigger stats atomically
    Trigger.update_counters(id, sessions_created_count: 1)

    session
  end

  # Detects a stale agent_root_name (one that no longer exists in the catalog)
  # and attempts to find a successor by matching the last session's git_root
  # and subdirectory. Persists the fix so subsequent fires use the new name.
  def heal_stale_agent_root!
    # Safety: if the catalog failed to load (AirCatalogService raised and
    # AgentRootsConfig rescued to `[]`), every name would appear stale. Skip
    # healing in that case — the session-creation path below will surface any
    # real misconfiguration through normal error handling.
    return if AgentRootsConfig.all.empty?
    return if AgentRootsConfig.exists?(agent_root_name)

    old_name = agent_root_name
    successor = find_agent_root_successor

    if successor
      update_column(:agent_root_name, successor.name)

      # Log-only, no #eng-alerts page: a found successor is matched on an exact
      # git_root + subdirectory match (see find_agent_root_successor), so it is
      # the SAME code location under a new catalog name — repointing is
      # impact-free and needs no human action. Paging #eng-alerts on every
      # successful heal is pure noise, and it recurs indefinitely for
      # self-waking sessions whose one-time wake triggers are recreated each
      # fire carrying a legacy/renamed root name. The .warn line is shipped to
      # the obs stack (queryable in VictoriaLogs) as a durable audit trail
      # without paging (the agent-orchestrator-errors Grafana rule matches
      # severity_text:ERROR only). The unhealable branch below still raises →
      # .error → page, which IS correct (a scheduled wake was genuinely lost);
      # see https://github.com/tadasant/zimmer-catalog/issues/4409.
      Rails.logger.warn(
        "[Trigger#heal_stale_agent_root!] Updated agent root from '#{old_name}' to '#{successor.name}' " \
        "on trigger '#{name}' (ID: #{id})"
      )
    else
      raise AgentRootsConfig::AgentRootNotFoundError,
        "Agent root '#{old_name}' not found in catalog and no successor could be identified. " \
        "Update trigger '#{name}' (ID: #{id}) manually at #{AppUrl.base_url}/triggers/#{id}"
    end
  end

  # Detects and removes catalog skills that no longer exist in the catalog.
  # Persists the cleaned list so the stale reference is only encountered once.
  def heal_stale_catalog_skills!
    return if catalog_skills.blank?
    # Safety: if SkillsConfig is empty (catalog load failure → rescued to []),
    # every ref would look stale. Skip healing to avoid destructive stripping.
    return if SkillsConfig.all.empty?

    non_blank = catalog_skills.reject(&:blank?)
    stale = non_blank.reject { |name| SkillsConfig.exists?(name) }
    return if stale.empty?

    valid = non_blank - stale
    update_column(:catalog_skills, valid)

    Rails.logger.warn(
      "[Trigger#heal_stale_catalog_skills!] Removed stale skill(s) #{stale.inspect} " \
      "from trigger '#{name}' (ID: #{id}). Remaining skills: #{valid.inspect}"
    )

    AlertService.raise_alert(
      "Trigger self-healed: stale catalog skill(s) removed",
      details: "Trigger *#{name}* (ID: #{id}) referenced catalog skill(s) that no longer exist:\n" \
               "• Removed: #{stale.join(', ')}\n" \
               "• Remaining: #{valid.empty? ? '(none)' : valid.join(', ')}\n\n" \
               "The stale reference(s) have been removed from the trigger. " \
               "The session will proceed with the remaining skills.\n\n" \
               "<#{AppUrl.base_url}/triggers/#{id}|View trigger in Zimmer>",
      source: "Trigger#create_session!",
      dedup_key: "trigger_stale_skills_#{id}"
    )
  end

  # Detects and removes catalog hooks that no longer exist in the catalog.
  # Persists the cleaned list so the stale reference is only encountered once.
  def heal_stale_catalog_hooks!
    return if catalog_hooks.blank?
    # Safety: see heal_stale_catalog_skills! — skip if catalog is empty.
    return if HooksConfig.all.empty?

    non_blank = catalog_hooks.reject(&:blank?)
    stale = non_blank.reject { |name| HooksConfig.exists?(name) }
    return if stale.empty?

    valid = non_blank - stale
    update_column(:catalog_hooks, valid)

    Rails.logger.warn(
      "[Trigger#heal_stale_catalog_hooks!] Removed stale hook(s) #{stale.inspect} " \
      "from trigger '#{name}' (ID: #{id}). Remaining hooks: #{valid.inspect}"
    )

    AlertService.raise_alert(
      "Trigger self-healed: stale catalog hook(s) removed",
      details: "Trigger *#{name}* (ID: #{id}) referenced catalog hook(s) that no longer exist:\n" \
               "• Removed: #{stale.join(', ')}\n" \
               "• Remaining: #{valid.empty? ? '(none)' : valid.join(', ')}\n\n" \
               "The stale reference(s) have been removed from the trigger. " \
               "The session will proceed with the remaining hooks.\n\n" \
               "<#{AppUrl.base_url}/triggers/#{id}|View trigger in Zimmer>",
      source: "Trigger#create_session!",
      dedup_key: "trigger_stale_hooks_#{id}"
    )
  end

  # Detects and removes catalog plugins that no longer exist in the catalog.
  # Persists the cleaned list so the stale reference is only encountered once.
  def heal_stale_catalog_plugins!
    return if catalog_plugins.blank?
    # Safety: see heal_stale_catalog_skills! — skip if catalog is empty.
    return if PluginsConfig.all.empty?

    non_blank = catalog_plugins.reject(&:blank?)
    stale = non_blank.reject { |plugin_id| PluginsConfig.exists?(plugin_id) }
    return if stale.empty?

    valid = non_blank - stale
    update_column(:catalog_plugins, valid)

    Rails.logger.warn(
      "[Trigger#heal_stale_catalog_plugins!] Removed stale plugin(s) #{stale.inspect} " \
      "from trigger '#{name}' (ID: #{id}). Remaining plugins: #{valid.inspect}"
    )

    AlertService.raise_alert(
      "Trigger self-healed: stale catalog plugin(s) removed",
      details: "Trigger *#{name}* (ID: #{id}) referenced catalog plugin(s) that no longer exist:\n" \
               "• Removed: #{stale.join(', ')}\n" \
               "• Remaining: #{valid.empty? ? '(none)' : valid.join(', ')}\n\n" \
               "The stale reference(s) have been removed from the trigger. " \
               "The session will proceed with the remaining plugins.\n\n" \
               "<#{AppUrl.base_url}/triggers/#{id}|View trigger in Zimmer>",
      source: "Trigger#create_session!",
      dedup_key: "trigger_stale_plugins_#{id}"
    )
  end

  # Detects and removes MCP servers that no longer exist in the catalog.
  # Persists the cleaned list to the database so the stale reference is
  # only encountered (and alerted) once.
  #
  # @return [Array<String>] the validated mcp_servers list to use for session creation
  def heal_stale_mcp_servers!
    return mcp_servers if mcp_servers.blank?
    # Safety: if ServersConfig is empty (catalog load failure → rescued to []),
    # every ref would appear stale and we'd destructively strip the list.
    return mcp_servers if ServersConfig.all.empty?

    non_blank = mcp_servers.reject(&:blank?)
    stale_servers = non_blank.reject { |name| ServersConfig.exists?(name) }
    return mcp_servers if stale_servers.empty?

    valid_servers = non_blank - stale_servers

    # Persist the cleaned list so subsequent fires don't re-encounter the same stale refs
    update_column(:mcp_servers, valid_servers)

    Rails.logger.warn(
      "[Trigger#heal_stale_mcp_servers!] Removed stale MCP server(s) #{stale_servers.inspect} " \
      "from trigger '#{name}' (ID: #{id}). Remaining servers: #{valid_servers.inspect}"
    )

    AlertService.raise_alert(
      "Trigger self-healed: stale MCP server(s) removed",
      details: "Trigger *#{name}* (ID: #{id}) referenced MCP server(s) that no longer exist in the catalog:\n" \
               "• Removed: #{stale_servers.join(', ')}\n" \
               "• Remaining: #{valid_servers.empty? ? '(none)' : valid_servers.join(', ')}\n\n" \
               "The stale reference(s) have been removed from the trigger. " \
               "The session will proceed with the remaining servers.\n\n" \
               "<#{AppUrl.base_url}/triggers/#{id}|View trigger in Zimmer>",
      source: "Trigger#create_session!",
      dedup_key: "trigger_stale_mcp_#{id}"
    )

    valid_servers
  end

  # Attempts to find a successor agent root by matching the last session's
  # git_root and subdirectory against the current catalog.
  # @return [AgentRootsConfig::AgentRoot, nil]
  def find_agent_root_successor
    return nil unless last_session_id.present?

    session = Session.find_by(id: last_session_id)
    return nil unless session

    # Search for a root matching the session's git URL and subdirectory,
    # skipping the metadata agent_root_key lookup (which would match the stale name)
    AgentRootsConfig.all.find do |ar|
      ar.url == session.git_root && ar.subdirectory.to_s == session.subdirectory.to_s
    end
  end
end

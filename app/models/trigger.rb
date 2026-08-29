# frozen_string_literal: true

# Trigger represents a "trigger flow" — a session template that can be fired
# by one or more trigger conditions (OR semantics).
#
# When ANY of its conditions fire, the trigger creates or reuses a session
# using its configured session template (agent_root, prompt, MCP servers, etc.).
class Trigger < ApplicationRecord
  # `failed` is Zimmer's to set: a fire raised and the trigger was parked rather
  # than deleted (see ScheduleTriggerJob). The MCP create/update surface does not
  # offer it, so an agent cannot fabricate a failure that never happened. It is a
  # third state and not a flavour of `disabled`, because the two answer different
  # questions — "you turned this off" versus "this tried to run and could not".
  # Every firing path filters on `status: "enabled"`, so a failed trigger fires no
  # more than a disabled one, which is what keeps a persistent error from becoming
  # a retry storm.
  STATUSES = %w[enabled disabled failed].freeze

  # Bound on the error text kept in `last_error`. Enough for a class + message
  # and the odd validation list; not a place to store a backtrace (the backtrace
  # goes to the log and to the alert's snippet).
  MAX_LAST_ERROR_CHARS = 1000

  # --- Burst control -------------------------------------------------------
  #
  # `max_sessions_per_minute` caps how many NEW sessions a trigger may spawn in a
  # one-minute window (anchored at the first fire and tumbling, not sliding).
  # NULL means unbounded (the pre-existing behavior, and the default for every
  # trigger).
  #
  # Once the cap is exceeded the trigger enters a *burst*: it spawns exactly one
  # burst-notice session (linking the sessions it did spawn in the window) and
  # then spawns nothing at all for the rest of the burst. A burst ends
  # BURST_COOLDOWN after the trigger last EXCEEDED its cap — so an outage that
  # keeps producing events faster than the cap keeps the trigger quiet for as
  # long as it lasts, and still yields exactly ONE notice, not one per tick.
  #
  # BURST_COOLDOWN is deliberately several times the poll cadence, NOT one minute.
  # The pollers tick every minute, so a one-minute cooldown expires exactly as the
  # next tick's events arrive: the burst would "end", the cap would refill, and a
  # sustained outage would produce a fresh batch of sessions and a fresh notice
  # every minute — the stream of notices this control exists to prevent.
  BURST_WINDOW = 1.minute
  BURST_COOLDOWN = 5.minutes

  # Cap on how many session links the burst-notice prompt carries. A sane limit
  # is small, but nothing stops an operator setting it to 500.
  MAX_BURST_NOTICE_LINKS = 25

  # --- Pending-session dedup ----------------------------------------------
  #
  # `skip_if_pending_session` says: if a session this trigger already spawned is
  # still pending — it has not yet finished the work the trigger asked for — then
  # this fire creates nothing. Opt-in, default off, so no existing trigger
  # changes behavior.
  #
  # This is a different question from the burst cap, and neither substitutes for
  # the other. `max_sessions_per_minute` bounds the RATE ("no more than N a
  # minute"); this bounds the BACKLOG ("no second session while the first is
  # still to act"). A trigger that fires every fifteen minutes never trips a rate
  # cap and can still pile up a dozen sessions all carrying the same prompt —
  # which is exactly what the `quota_available` wake trigger did, because the
  # fleet session it spawns is itself parked by the quota exhaustion it exists to
  # answer.
  #
  # PENDING means `waiting` or `running`, and deliberately nothing else:
  #
  #   - `waiting` is the "queued, has not had its turn" state, and it is where a
  #     session sits both before it is first started and while it is parked on an
  #     exhausted pool. This is the case the setting exists for.
  #   - `running` counts too. A session mid-work has not delivered its outcome
  #     yet, and spawning a sibling to do the same job concurrently is the same
  #     duplication one tick earlier — several of the duplicate wake sessions were
  #     running side by side.
  #   - `needs_input`, `archived` and `failed` do NOT count. Each is a session
  #     that has had its turn: it either finished, died, or is waiting on a human,
  #     and none of those may block a legitimate future fire. Counting
  #     `needs_input` in particular would let one session parked for a human
  #     silently disable the trigger for as long as nobody looked at it.
  #
  # Burst-notice sessions are excluded: a notice carries the "investigate this
  # burst" intent, not the trigger's own, so one sitting in `needs_input`-adjacent
  # limbo must not stand in for the work the trigger was asked to do.
  PENDING_INTENT_STATUSES = %w[waiting running].freeze

  # How much of the event that tipped the cap to quote in the notice prompt.
  BURST_NOTICE_PROMPT_EXCERPT = 500

  # --- Missed fires ---------------------------------------------------------
  #
  # A recurring trigger that reuses a session coalesces its fire when that
  # session is still holding the previous one (see #coalesce_recurring_fire?).
  # Coalescing is right, but a coalesced fire is a scheduled run that did not
  # happen, so a RUN of them is the signal that the schedule has quietly stopped
  # doing its job.
  #
  # Two conditions have to hold before this pages, because either alone is noisy
  # in the ordinary case:
  #
  #   * At least this many consecutive fires coalesced. One skip is unremarkable
  #     — a session mid-turn drains its queue at the next turn boundary and the
  #     following fire lands. Two in a row means nothing drained in between.
  #   * The undelivered prompt has been sitting for at least this long. A
  #     fast-firing trigger can rack up consecutive skips inside a single long
  #     turn without anything being wrong; a queue that has not moved in an hour
  #     is a different animal.
  #
  # Together they say: "two scheduled runs in a row did not happen, and the
  # session genuinely is not consuming." That is the second miss, not the sixth
  # — the 2026-08-29 incident ran for six nights before an unrelated archive
  # stranded the backlog and raised the only alert anyone saw.
  MISSED_FIRE_ALERT_THRESHOLD = 2
  MISSED_FIRE_MIN_QUEUE_AGE = 1.hour

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
  validates :scheduling_class,
    inclusion: { in: -> { SessionGenesis::CLASSES }, message: "%{value} is not a known scheduling class" },
    allow_nil: true
  # NULL is "predefine nothing" — the spawned session takes SessionPrecedence's
  # own default. The bounds are the column's, not a policy: precedence is an
  # absolute scale with no meaningful ceiling of its own.
  validates :precedence,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: SessionPrecedence::MIN,
      less_than_or_equal_to: SessionPrecedence::MAX
    },
    allow_nil: true
  validate :catalog_skills_must_be_array
  validate :catalog_skills_must_exist_in_catalog, if: :catalog_skills_changed?
  validate :catalog_hooks_must_be_array
  validate :catalog_hooks_must_exist_in_catalog, if: :catalog_hooks_changed?
  validate :catalog_plugins_must_be_array
  validate :catalog_plugins_must_exist_in_catalog, if: :catalog_plugins_changed?

  # A form's "Use the default" option submits "", which means "derive it", not a
  # class named empty string or a precedence of zero.
  before_validation :normalize_precedence
  before_validation :normalize_scheduling_class

  before_save :clear_burst_state_when_limit_changes
  before_save :clear_failure_state_when_leaving_failed
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
  scope :failed, -> { where(status: "failed") }

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

  # A fire raised and the trigger was parked instead of destroyed. See
  # ScheduleTriggerJob's rescue for the one path that sets this.
  def failed?
    status == "failed"
  end

  # Enabling is also how a failed trigger is RE-ARMED. The failure state is
  # cleared by #clear_failure_state_when_leaving_failed, so every path that moves
  # a trigger off `failed` — this, the edit form, the REST API, action_trigger —
  # sheds the stale error rather than only this one.
  def enable!
    update!(status: "enabled")
  end

  def disable!
    update!(status: "disabled")
  end

  # Enabled → disabled; anything else (disabled, failed) → enabled. Re-arming a
  # failed trigger is the same gesture as switching a disabled one back on.
  def toggle!
    if enabled?
      disable!
    else
      enable!
    end
  end

  # Park this trigger with the error that stopped it, instead of destroying it.
  # Named without a bang, and returning a boolean rather than raising, because
  # the caller is already inside a rescue and needs a fallback rather than a
  # second exception — see ScheduleTriggerJob.
  #
  # Uses update_columns for the same reason the other bookkeeping writes here do:
  # a failure write must not itself be blocked by validations (the trigger may
  # have had its conditions cascade-deleted by a concurrent sibling cleanup, and
  # `validates :trigger_conditions, presence:` would then raise). Recording that
  # a wake failed is strictly more important than the record being re-validated.
  #
  # @return [Boolean] whether the failure was persisted
  def mark_failed(error)
    now = Time.current
    update_columns(
      status: "failed",
      failed_at: now,
      last_error: format_last_error(error),
      updated_at: now
    )
    true
  rescue => e
    Rails.logger.error(
      "[Trigger#mark_failed] Could not park trigger #{id} as failed: #{e.class}: #{e.message}"
    )
    false
  end

  # True when every one-shot condition this trigger carries has already been
  # consumed — so re-enabling it cannot deliver the wake it owed.
  #
  # This is the case where a fire raised AFTER the condition was advanced: the
  # session was created and only the cleanup behind it fell over. Re-arming would
  # deliver nothing (and acting on the promise by hand would duplicate the
  # session), so the trigger page and the alert read this rather than offering a
  # re-arm that cannot work. False for a trigger with no one-shot condition at
  # all — a recurring one really does go back into service when re-enabled.
  #
  # Both one-shot shapes count: a one-time schedule and a session-scoped
  # `ao_event` wake. They are parked by different jobs (ScheduleTriggerJob and
  # AoEventTriggerJob) but they are the same question to a reader of /triggers,
  # and a predicate that saw only schedules would offer every parked
  # state-change wake a re-arm button that may duplicate a session.
  #
  # Deliberately not #schedule_due?: that returns false for any trigger that
  # isn't enabled, which is every trigger this question is asked about.
  def spent_one_shot_wake?
    one_shot = trigger_conditions.select { |c| c.one_time_schedule? || c.session_scoped_ao_event? }
    one_shot.any? && one_shot.all? { |c| c.last_triggered_at.present? }
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
  # a session it already spawned is still pending (see
  # #spawn_unless_pending_session!), or a one-time reuse trigger's target session
  # is gone. Callers must handle nil, and the three reasons are NOT
  # interchangeable — #last_fire_burst_suppressed? and
  # #last_fire_skipped_for_pending_session? tell them apart.
  # The genesis stamped on sessions this trigger spawns.
  #
  # Derived from the trigger's own condition types, so a Slack trigger's sessions
  # are priority and a github_issue trigger's are spot without the firing job
  # having to say so. `genesis_override` is how a fire that knows better — the
  # Invoke button, where a human is clicking in the web app — overrules that.
  def session_genesis
    @genesis_override.presence || SessionGenesis.from_condition_types(condition_types)
  end

  # The class this trigger's sessions would carry if it named none — the shipped
  # default for the genesis it derives. What the form shows next to "Use the
  # default", so the operator can see what they are choosing away from.
  #
  # `default_class`, not `effective_class`: every genesis a trigger can derive is
  # trigger-backed, and SessionGenesis ignores a per-kind override for those — so
  # the two agree, and this one does not read AppSetting once per trigger in a
  # listing of a hundred.
  def default_scheduling_class
    SessionGenesis.default_class(SessionGenesis.from_condition_types(condition_types))
  end

  # The class this trigger's sessions actually get.
  def effective_scheduling_class
    scheduling_class.presence || default_scheduling_class
  end

  # The class stamped on sessions this trigger spawns — nil when the operator has
  # chosen nothing, so the session derives from its genesis like any other and a
  # later change to the shipped default still reaches it.
  #
  # A genesis override means a human pressed Invoke and is waiting on the answer.
  # That is a different origin from the one this trigger's selector describes, so
  # the selector does not apply: the session takes `web_ui`'s class instead.
  def session_scheduling_class
    return nil if @genesis_override.present?

    scheduling_class.presence
  end

  # The spot-queue rank stamped on sessions this trigger spawns — nil when the
  # operator has predefined nothing, so the session takes the default
  # SessionPrecedence assigns.
  #
  # Unlike the class, this is NOT withheld from an Invoke. A precedence is a
  # statement about how the trigger's work ranks against everything else queued,
  # and that is as true of a hand-fired run as of a scheduled one; a human
  # pressing Invoke on a trigger ranked 5000 is asking for that work, at that
  # rank. It only ever orders spot sessions anyway, and Invoke's `web_ui` genesis
  # makes the session priority — so a carried-over value costs nothing and keeps
  # the rank if the session is later demoted.
  def session_precedence
    precedence
  end

  # @param genesis [String, nil] override the derived genesis for this fire only.
  def create_session!(prompt:, genesis: nil)
    @last_fire_burst_suppressed = false
    @last_fire_pending_session = nil
    # Reset with its siblings. The jobs read #last_follow_up_dropped? after
    # #create_session! on paths that never reach #follow_up_session! — the
    # one-time-reuse "target not reusable" return below, and every spawn — where
    # a value left over from a previous fire on this instance would be read as
    # this fire's outcome.
    @last_follow_up_status = nil
    @genesis_override = genesis

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

      # Resuscitate archived sessions: unarchive and then follow up — but only
      # when there is a conversation to bring back. A session archived before it
      # ever took a turn is not a reuse candidate at all (see
      # #resuscitatable_session?), and treating it as one bricks the trigger:
      # UnarchiveSessionService refuses it, #resuscitate_session! raises,
      # ScheduleTriggerJob advances last_triggered_at to stop the retry loop, and
      # the recurring trigger creates nothing — on that fire and on every fire
      # after it, since the candidate never changes. That is the "Daily Fleet
      # Cleanup" incident of 2026-08-23.
      if session && resuscitate_archived && session.archived?
        if resuscitatable_session?(session)
          resuscitate_session!(session)
          return follow_up_session!(session, prompt: prompt)
        end

        # Fall through to the no-reusable-session paths below: a recurring
        # trigger spawns a fresh session (and #create_new_session! points
        # last_session_id at it, so the trigger heals itself on this same fire),
        # while a one-time reuse trigger skips silently, because it means THAT
        # session and a fresh stranger would be no use to it.
        Rails.logger.warn(
          "[Trigger#create_session!] Trigger '#{name}' (ID: #{id}) cannot resuscitate archived session " \
          "#{session.id} — it has no runtime session id and no transcript, so it was archived before it " \
          "ever started and there is nothing to restore. Treating it as no reuse candidate: a recurring " \
          "trigger spawns a fresh session, a one-time reuse trigger skips."
        )
      end

      # One-time reuse triggers are semantically "act on this specific session at
      # this time." If the session isn't reusable (user archived it, resumed it
      # manually, etc.), skip silently — there's nothing else to do.
      if one_time_reuse_trigger?
        Rails.logger.info "[Trigger#create_session!] Skipping one-time reuse trigger #{id} — target session #{last_session_id} is not reusable (status: #{session&.status || 'not found'})"
        return session
      end
    end

    spawned = spawn_unless_pending_session!(prompt: prompt)
    # A trigger that spawned a REAL session has somewhere to talk to again, and
    # the queue that was holding the old session's prompts is no longer its
    # concern — #create_new_session! has already repointed `last_session_id` at
    # the new one, which is exactly the identity tested here.
    #
    # A burst-notice session is not that. #spawn_burst_notice_session!
    # deliberately leaves `last_session_id` alone (a reuse trigger must never
    # follow up INTO the notice), so the trigger still points at the stuck
    # session. Clearing on it would restart the count from zero on every fire
    # while the trigger is bursting, and the alert would never arrive.
    clear_missed_fires! if spawned && last_session_id == spawned.id
    spawned
  end

  # True when this trigger is currently inside a burst it has already noticed:
  # every fire is suppressed until the burst ends. Requires a cap to be set —
  # clearing the cap ends any burst (see #clear_burst_state_when_limit_changes),
  # and an unbounded trigger is never suppressed regardless of leftover state.
  def bursting?
    max_sessions_per_minute.present? &&
      burst_active_until.present? &&
      burst_active_until > Time.current
  end

  # Whether the most recent #create_session! call on this in-memory instance was
  # dropped by burst control. Callers use this to distinguish "nothing spawned
  # because we're rate-limited" from "nothing spawned because the target session
  # was gone."
  def last_fire_burst_suppressed?
    @last_fire_burst_suppressed == true
  end

  # Whether this trigger currently has scheduled runs that did not happen — its
  # fires are being coalesced into a prompt the reused session has not consumed.
  #
  # Read by the trigger page, the trigger list and the MCP `search_triggers`
  # detail view, so the state is legible from any surface an operator can reach
  # without a shell on the box. Before this, a trigger in this condition was
  # indistinguishable from a healthy one on every one of them.
  def missing_fires?
    missed_fire_count.to_i.positive?
  end

  # Whether `skip_if_pending_session` is doing nothing on this trigger right now.
  #
  # It is consulted only by #spawn_unless_pending_session!, on the SPAWN path. A
  # reuse trigger holding a live, reusable `last_session_id` returns out of
  # #create_session! through #follow_up_session! well before that, so on those
  # fires the checkbox is inert — and every surface that renders it used to claim
  # it was in force, the trigger page and `search_triggers` both saying "Yes
  # (nothing pending — the next fire spawns)" about a branch that could not run.
  #
  # "Right now", not "structurally": the same trigger DOES reach the spawn path
  # on a fire where it has no reusable target — it has never fired, or the target
  # was archived or failed and a recurring trigger spawns a replacement. The
  # setting applies in full on those fires. The surfaces say so in those words,
  # rather than promising more than this cheap predicate checks; resolving the
  # target here would put a session lookup in every row of the trigger list.
  #
  # Surfaced rather than validated away: existing triggers carry the combination
  # (trigger 4730, the Daily Backlog Groomer, is one), and a create/update
  # validation would start rejecting saves of rows that are already stored.
  # #coalesce_recurring_fire? is the reuse-path control that actually bounds the
  # backlog, and it needs no opt-in.
  def skip_if_pending_session_inert?
    skip_if_pending_session? && reuse_session?
  end

  # The still-pending session that made the most recent #create_session! call on
  # this in-memory instance spawn nothing, or nil when dedup did not apply. Given
  # to callers so they can name the session that already covers the work rather
  # than reporting a bare "nothing happened".
  attr_reader :last_fire_pending_session

  # Whether the most recent #create_session! call was skipped because a session
  # this trigger already spawned is still pending (see PENDING_INTENT_STATUSES).
  #
  # Callers must NOT treat this like #last_fire_burst_suppressed?. A
  # burst-suppressed fire is an event DROPPED — the work it asked for will not
  # happen, and a caller holding a retryable edge should put that edge back. A
  # dedup-skipped fire is the opposite: the work is already in hand, spawned and
  # queued, so the fire was HANDLED. Re-arming on it would mean firing again,
  # skipping again, and re-arming again, forever.
  def last_fire_skipped_for_pending_session?
    @last_fire_pending_session.present?
  end

  # The pending session that blocks a new spawn, or nil when there is none.
  # Newest first, so the session a caller is pointed at is the most recent one
  # still carrying the intent.
  def pending_intent_session
    Session
      .for_trigger(id)
      .where(status: PENDING_INTENT_STATUSES)
      .where("metadata->>'burst_notice' IS DISTINCT FROM 'true'")
      .order(created_at: :desc)
      .first
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

  # True when NO condition on this trigger is a one-shot — neither a one-time
  # schedule nor a session-scoped ao_event.
  #
  # Not the negation of #one_time_reuse_trigger?, and the gap between them is the
  # point. That method demands that EVERY condition be one-shot, so a trigger
  # mixing a recurring schedule with a one-time one satisfies neither: it is not
  # a wake, and it is not purely recurring either. #coalesce_recurring_fire?
  # keys on this rather than on `!one_time_reuse_trigger?` so that mixed shape
  # keeps its previous behaviour — ScheduleTriggerJob would otherwise consume its
  # one-shot schedule, and destroy the trigger, on a fire that delivered nothing.
  def purely_recurring?
    trigger_conditions.any? &&
      trigger_conditions.none? { |c| c.one_time_schedule? || c.session_scoped_ao_event? }
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
  #
  # A sibling in the `failed` status is exempt. It is not a moot wake — it is the
  # record of a wake that TRIED and could not, parked by ScheduleTriggerJob so the
  # user would see it. Destroying it here would delete that evidence as a side
  # effect of a later sibling succeeding, which is the silent loss this whole
  # mechanism exists to prevent. Only the user clears a failed trigger.
  def destroy_sibling_wakes!
    return 0 unless one_time_reuse_trigger?
    return 0 if last_session_id.blank?

    siblings = Trigger
      .where(last_session_id: last_session_id, reuse_session: true)
      .where.not(id: id)
      .where.not(status: "failed")
      .includes(:trigger_conditions)
      .to_a
      .select(&:one_time_reuse_trigger?)

    return 0 if siblings.empty?

    sibling_ids = siblings.map(&:id)
    Trigger.where(id: sibling_ids).destroy_all
    sibling_ids.size
  end

  private

  def normalize_scheduling_class
    self.scheduling_class = nil if scheduling_class.blank?
  end

  def normalize_precedence
    self.precedence = nil if precedence_before_type_cast.is_a?(String) && precedence_before_type_cast.strip.empty?
  end

  # "ClassName: message", bounded. Accepts an exception or a plain string so
  # callers don't have to care which they have.
  def format_last_error(error)
    text = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    text.truncate(MAX_LAST_ERROR_CHARS)
  end

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

    # Outside the branch, and AFTER the status work rather than before it.
    #
    # Outside, because every branch reaches a session this wake is now responsible
    # for: `needs_input` sleeps, `running` sleeps at its turn end, and a session
    # already `waiting` still has the wake armed against it. A marker cleared on
    # only one of the three leaves the other two holding a wake that will be
    # dropped on arrival.
    #
    # After, because `sleep!` can raise — aasm's `whiny_persistence` turns a failed
    # save into an exception, and the rescue below swallows it. A session left in
    # `needs_input` with the marker already gone is one the bulk refresh will
    # auto-continue, resuming work a human deliberately stopped. Clearing last
    # means a failed sleep leaves the session exactly as it was found.
    clear_stale_user_pause!(session)
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

  # Drop `paused_by: "user"` from a session this wake is putting to sleep.
  #
  # The marker means "a human has taken this session over", and #reusable_session?
  # refuses to deliver into a session carrying it. That is right for a session
  # sitting in needs_input where somebody hit Pause — and wrong the moment the
  # same human arms a wake on it, because the pair says "come back at 9am" and
  # then guarantees the 9am delivery is dropped. Pause-then-Pause-Until is an
  # ordinary sequence in the UI (the buttons sit next to each other), and it left
  # the session asleep forever.
  #
  # Only "user" is cleared. `recovery` and `spot_quota` mark sessions their own
  # sweeps are still responsible for, and this wake does not relieve them of it.
  #
  # Nothing else guards a *sleeping* session on this marker: the bulk-refresh
  # nudge skips a `waiting` session by asking whether a wake is armed
  # (Session.ids_awaiting_scheduled_wake), which is precisely what has just
  # become true here.
  #
  # `remove_metadata!` rather than a whole-column write: a session coming to rest
  # still has a job writing its own keys to the same column from another process,
  # and a read-modify-write of the hash this callback happens to be holding would
  # drop whatever was written in between. It deletes the one key in a single
  # UPDATE and leaves every other key alone.
  def clear_stale_user_pause!(session)
    return unless session.metadata&.dig("paused_by") == "user"
    # The same status gate #reusable_session? applies, so this clears the marker
    # exactly where it is the thing standing between the wake and delivery. On a
    # `failed` or `archived` session the wake is undeliverable for a reason this
    # marker has nothing to do with, and clearing it would only lose the record of
    # who stopped the session.
    return unless session.needs_input? || session.running? || session.waiting?

    session.remove_metadata!("paused_by")
    session.logs.create!(
      content: "[Trigger##{id}] Cleared the user-pause marker — this session is now asleep on a " \
               "wake-up rather than held for a human, so the wake can resume it",
      level: "info"
    )
  end

  def ao_event_target_status(event_name)
    case event_name
    when "session_needs_input" then "needs_input"
    when "session_failed" then "failed"
    when "session_archived" then "archived"
    end
  end

  # Can this archived session be brought back at all?
  #
  # Only if there is something to bring back. UnarchiveSessionService restores a
  # transcript so the agent can resume, and refuses a session with no
  # `session_id` ("Session has no session_id") because that is the name it would
  # write the transcript under. So a session with neither is refused on this fire
  # and on every later one — it is not a reuse candidate, and a trigger that
  # keeps it as one is dead for good, since the candidate never changes and each
  # fire raises the same error.
  #
  # That pair is the state the spot gate produces at scale: a `spot` session
  # held at the starting line for a whole quota window, never started, then
  # archived. `session_id` is stamped once the spawn pipeline has the session's
  # clone and BEFORE the runtime is launched (AgentSessionJob passes it to the
  # CLI as `--session-id`), so blank means the session never got that far, and
  # its transcript is blank for the same reason.
  #
  # The transcript is checked as well as the id because the two can come apart:
  # a runtime that mints its own conversation id (codex) has that id cleared by
  # ProcessLifecycleManager#release_stale_runtime_session_id! on a fresh-start
  # recovery, so a long-running session can hold a full transcript with no id.
  # That session HAS state, and the service still cannot restore it — which is
  # exactly a failure a human should see. It keeps raising.
  #
  # Deliberately narrow for the same reason. The service's other failures — a
  # clone that would not restore, a DB error, a state the row cannot leave — say
  # nothing about whether the session holds work worth resuming, so they raise
  # rather than quietly spawning a duplicate alongside it.
  def resuscitatable_session?(session)
    session.session_id.present? || session.transcript.present?
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

      if coalesce_recurring_fire?(session)
        # The previous beat is still sitting in the queue undelivered, so this
        # one would stack a second copy of the same drumbeat behind it. Skip.
        #
        # This case used to be reachable ONLY through the `running?` branch
        # below, which is why it went unnoticed for so long: an IDLE session
        # (`waiting` / `needs_input`) took the delivery branch instead, and that
        # branch had no duplicate guard at all. That is not a theoretical gap —
        # a spot session held at the quota gate sits in `waiting`, and
        # `deliver_follow_up!` on it resumes it into a job that SpotSessionHold
        # promptly defers, converting the "delivery" into one more queued row
        # via #queue_behind_scheduled_turn. Five nightly fires against one
        # quota-held session produced five byte-identical copies, none of them
        # ever delivered, and the schedule reported success every time.
        #
        # Skipping is a coalesce, not a drop: the copy already queued carries
        # exactly this intent and runs when the session next takes a turn. What
        # must NOT happen is the fire passing silently — #record_missed_fire!
        # counts it, and a run of them alerts.
        Rails.logger.info(
          "[Trigger#follow_up_session!] Coalescing fire for recurring trigger #{id} — session " \
          "#{session.id} (#{session.status}) still holds #{session.enqueued_messages.pending.count} " \
          "undelivered prompt(s); not stacking another copy"
        )
        @last_follow_up_status = :skipped_pending_exists
      elsif session.needs_input? || session.waiting?
        session.deliver_follow_up!(prompt, clear_metadata_keys: Session::SIGTERM_RETRY_METADATA_KEYS)
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

    # Outside the transaction that locked the session: this only writes the
    # trigger's own bookkeeping and may raise an alert, and neither belongs
    # inside a lock held on somebody else's row.
    record_fire_outcome!(session)

    session
  end

  # Whether this fire should be coalesced into a prompt the target session is
  # already holding rather than adding another copy.
  #
  # Scoped to PURELY RECURRING triggers on purpose. A recurring trigger is a
  # drumbeat: if the session has not consumed the last beat, a second one is
  # duplication, and the queue is the wrong place to accumulate a backlog of
  # them. A one-shot signal is the opposite — it must deliver durably across the
  # race window #follow_up_session! documents — so it is exempt here and keeps
  # the narrower guard on the `running?` branch, which treats an existing pending
  # message as already representing the watched event.
  #
  # The test is #purely_recurring?, NOT `!one_time_reuse_trigger?`, and the
  # difference is load-bearing. `one_time_reuse_trigger?` requires *every*
  # condition to be one-shot, so a trigger mixing a recurring schedule with a
  # one-time one would fail it and be coalesced here — and ScheduleTriggerJob
  # keys its auto-delete on `condition.one_time_schedule?`, checking only
  # #last_follow_up_dropped? before destroying the trigger. A coalesced fire is
  # not `:dropped`, so that trigger would be destroyed and its one-shot schedule
  # consumed having delivered nothing. Refusing to coalesce any trigger that
  # carries a one-shot condition at all keeps the pre-existing behaviour intact
  # for those shapes and confines this to the daily-cron shape the incident had.
  #
  # Deliberately NOT gated behind `skip_if_pending_session`. That setting is a
  # SPAWN-path control (see #spawn_unless_pending_session!) and is unreachable
  # from here — a reuse trigger returns from #follow_up_session! long before
  # #create_session! would consult it. Gating this on an opt-in that defaults
  # off would reproduce exactly the silence being fixed.
  #
  # The predicate is ANY pending message, not just one this trigger queued, and
  # that is a deliberate over-reach with a known cost: a message a human queued
  # onto the reused session also coalesces tonight's fire. Two reasons to accept
  # it. It is the predicate the `running?` branch below has always used, so this
  # makes the two branches agree rather than inventing a third rule. And
  # per-trigger provenance would not actually catch the incident this fixes:
  # those rows were written by SpotSessionHold#queue_behind_scheduled_turn, which
  # holds only a session and a prompt and has no idea which trigger sent it — so
  # a `trigger_id` column would have missed all five. The cost is bounded at one
  # occurrence (the session consumes the queue, and the next fire lands) and it
  # is now counted rather than silent.
  def coalesce_recurring_fire?(session)
    return false unless purely_recurring?

    session.enqueued_messages.pending.exists?
  end

  # Record whether this fire actually reached the session, and page when a run
  # of them has not.
  #
  # The invariant: a scheduled fire either runs, or somebody learns it did not.
  # A coalesced fire is a scheduled run that did NOT happen, and before this it
  # was indistinguishable from a successful one — `last_triggered_at` advanced
  # either way, so the trigger page, the MCP surface and the operator all read
  # "fired daily, last night included" while six nights in a row had gone
  # nowhere. The counter is what makes the miss countable; the alert is what
  # makes it reach a human without waiting for an unrelated archive to notice.
  def record_fire_outcome!(session)
    case @last_follow_up_status
    when :skipped_pending_exists
      record_missed_fire!(session)
    when :delivered, :queued
      # The trigger is reaching its session again; whatever run it was carrying
      # is over.
      clear_missed_fires!
    end
    # `:dropped` is deliberately neither. It is the pre-existing "don't barge a
    # busy session" behaviour of a recurring trigger with `enqueue_messages`
    # off, and it is common and benign — but it is not progress either, so
    # clearing a run of real misses on one would hide them.
  rescue StandardError => e
    # Never let bookkeeping fail a fire that otherwise landed.
    Rails.logger.error("[Trigger#record_fire_outcome!] Trigger #{id}: #{e.class}: #{e.message}")
  end

  def record_missed_fire!(session)
    # Atomic, because two jobs can fire one trigger concurrently
    # (ScheduleTriggerJob and AoEventTriggerJob overlap) and this runs outside
    # the session lock. A read-modify-write on a possibly-stale attribute would
    # undercount the run and reach the alert threshold late.
    Trigger.update_counters(id, missed_fire_count: 1)
    reload
    update_columns(first_missed_fire_at: Time.current) if first_missed_fire_at.nil?

    count = missed_fire_count.to_i
    first_at = first_missed_fire_at || Time.current
    return unless count >= MISSED_FIRE_ALERT_THRESHOLD

    # By `created_at`, not by `position`: #reorder_to lets a caller shuffle
    # positions, so the lowest-positioned row is not necessarily the oldest, and
    # age is the whole point of this gate.
    stalled_since = session.enqueued_messages.pending.minimum(:created_at)
    return if stalled_since.blank? || stalled_since > MISSED_FIRE_MIN_QUEUE_AGE.ago

    AlertService.raise_alert(
      "Recurring trigger is not reaching its session",
      details: "Trigger '#{name}' (ID: #{id}) has had #{count} consecutive fires coalesced away since " \
               "#{first_at.iso8601}. It reuses session #{session.id}, which has been holding an " \
               "undelivered prompt since #{stalled_since.iso8601}.\n\n" \
               "The scheduled work has not run for #{count} occurrence(s). Nothing is queued up behind " \
               "this — the duplicate copies are deliberately not stacked — so the schedule resumes as " \
               "soon as session #{session.id} takes a turn and drains its queue.\n\n" \
               "Check that something WILL make it take one. A spot session held for quota headroom " \
               "re-checks on its own; a session sitting in `waiting` for any other reason may need to " \
               "be started by hand, because nothing sweeps a waiting session's queue.\n\n" \
               "If that session is a spot session held for quota headroom, this is budget pacing rather " \
               "than a failure: either let it drain, or make it priority to start it now. If it is stuck " \
               "for any other reason, that is the thing to fix.\n\n" \
               "Trigger: #{trigger_url(id)}",
      source: "Trigger#record_missed_fire!",
      dedup_key: "trigger_missed_fires_#{id}"
    )
  end

  def clear_missed_fires!
    return if missed_fire_count.to_i.zero? && first_missed_fire_at.nil?

    update_columns(missed_fire_count: 0, first_missed_fire_at: nil)
  end

  # A `/triggers/:id` link for the alert above. Mirrors ApplicationJob#trigger_url,
  # including its fallback: AppUrl.base_url reads configuration, and a deployment
  # that has it wrong must lose the link rather than the alert.
  def trigger_url(trigger_id)
    "#{AppUrl.base_url}/triggers/#{trigger_id}"
  rescue StandardError => e
    Rails.logger.warn("[Trigger] Could not build a trigger URL: #{e.class}: #{e.message}")
    "/triggers/#{trigger_id}"
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

  # The dedup gate, in front of the burst gate. Both sit on the SPAWN path only:
  # a fire that follows up into a reused session has already returned by now, and
  # rightly so — it adds no session to the pile.
  #
  # Ordering matters. Dedup runs first because it is the cheaper and more
  # specific answer: when a pending session already covers the intent, this fire
  # should consume no burst budget and leave no trace, exactly as if the event
  # had not arrived.
  #
  # Deliberately NOT under a row lock, and the residual race is worth naming: two
  # fires landing in the same instant can both read "nothing pending" and both
  # spawn. Holding a lock across the spawn would close that, and would cost more
  # than it buys — #reserve_burst_slot! would join the outer transaction, so a
  # spawn that raises would roll back the attempt it is supposed to consume AND
  # the burst-latch clear that keeps a failed notice from silently disabling the
  # trigger. Those two properties guard against runaway spawning; a same-instant
  # duplicate is the pre-existing behavior of every trigger, and unchanged here.
  # What this setting bounds is the backlog ACROSS fires, which is where the
  # duplicates actually came from — fires minutes or quarter-hours apart.
  def spawn_unless_pending_session!(prompt:)
    return spawn_with_burst_control!(prompt: prompt) unless skip_if_pending_session?

    pending = pending_intent_session

    if pending
      @last_fire_pending_session = pending
      Rails.logger.info(
        "[Trigger#create_session!] Trigger '#{name}' (ID: #{id}) skipped this fire — session " \
        "#{pending.id} (#{pending.status}) is still pending and already carries this intent"
      )
      return nil
    end

    spawn_with_burst_control!(prompt: prompt)
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
      begin
        spawn_burst_notice_session!(triggering_prompt: prompt)
      rescue
        # The notice is the ONLY thing the operator gets out of a burst. If
        # spawning it fails (unhealable agent root, DB error), do not leave the
        # trigger latched into a burst it never announced — that is silent death,
        # the worst outcome available. Clear the burst so the next fire re-opens
        # it and tries the notice again; the window is still over the cap, so
        # that fire cannot spawn an ordinary session instead.
        update_columns(burst_active_until: nil, updated_at: Time.current)
        raise
      end
    else
      session = create_new_session!(prompt: prompt)
      record_burst_window_session!(session)
      session
    end
  end

  # Atomically decide what this fire may do. The read-modify-write of the window
  # counters happens under a row lock, so two jobs firing the same trigger
  # concurrently (ScheduleTriggerJob and AoEventTriggerJob can overlap) can
  # neither both take the last slot nor both open the burst.
  #
  # `burst_window_count` counts FIRES ATTEMPTED in the current window, not
  # sessions spawned. That distinction is what lets the burst end: the cooldown
  # is pushed forward only by a window that is itself over the cap, so the burst
  # lasts as long as the trigger keeps EXCEEDING its cap — not as long as any
  # event at all keeps arriving. Extending it on every suppressed fire (the
  # obvious implementation) would mean a channel with any baseline chatter could
  # never leave a burst: one 50-message spike would silently disable the trigger
  # forever.
  #
  # The slot is reserved BEFORE the session exists, so a spawn that then raises
  # still consumes budget. That errs toward under-spawning, the safe direction
  # for a control whose whole job is to bound spawns.
  def reserve_burst_slot!
    return :allowed if max_sessions_per_minute.blank?

    with_lock do
      now = Time.current

      # Read the burst state BEFORE this fire touches it: a fire that lands
      # inside an already-open burst is suppressed, whatever it does to the
      # counters below.
      was_bursting = burst_active_until.present? && burst_active_until > now

      # The window is anchored at the first fire and rolls over wholesale once it
      # ages out (a tumbling window, not a sliding one — minute-resolution pollers
      # don't justify the bookkeeping a sliding window would need).
      if burst_window_started_at.blank? || burst_window_started_at <= now - BURST_WINDOW
        roll_burst_window!(now)
      end

      attempts = burst_window_count + 1
      update_columns(burst_window_count: attempts, updated_at: now)

      # A window that exceeds the cap holds the burst open — and opens it, if it
      # wasn't. A window that stays under the cap does neither, so the burst
      # expires BURST_COOLDOWN after the trigger last exceeded its cap.
      over_cap = attempts > max_sessions_per_minute
      update_columns(burst_active_until: now + BURST_COOLDOWN, updated_at: now) if over_cap

      next :suppressed if was_bursting
      next :burst if over_cap

      :allowed
    end
  end

  # Start a new counting window. Deliberately does NOT touch burst_active_until:
  # whether a burst is open is a question of time since the cap was last
  # exceeded, not of which window we're in.
  def roll_burst_window!(now)
    update_columns(
      burst_window_started_at: now,
      burst_window_count: 0,
      burst_window_session_ids: [],
      updated_at: now
    )
  end

  # Editing the cap clears any burst in progress. This is the operator's escape
  # hatch: a trigger stuck suppressing (because events really are still pouring
  # in) can be brought back immediately by re-saving its cap, rather than waiting
  # the burst out. Internal bookkeeping writes all go through update_columns, so
  # they never trip this callback.
  def clear_burst_state_when_limit_changes
    return unless will_save_change_to_max_sessions_per_minute?

    self.burst_window_started_at = nil
    self.burst_window_count = 0
    self.burst_window_session_ids = []
    self.burst_active_until = nil
  end

  # A trigger that is no longer `failed` must not keep advertising the failure it
  # recovered from — the API serializes both fields unconditionally, and the UI
  # renders them. Keyed on the status transition rather than on #enable! so every
  # route off `failed` sheds it: the toggle, the edit form, PATCH /api/v1/triggers,
  # action_trigger's update. mark_failed writes through update_columns and so
  # never trips this.
  def clear_failure_state_when_leaving_failed
    return unless will_save_change_to_status?
    return if status == "failed"

    self.failed_at = nil
    self.last_error = nil
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
      genesis: session_genesis,
      scheduling_class: session_scheduling_class,
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
      instead. The trigger now spawns nothing at all until the burst ends — #{BURST_COOLDOWN.inspect} after the
      last minute in which it exceeded its cap. Events that arrive in the meantime are dropped —
      not queued, not replayed. You will not get another burst notice for this burst.

      Sessions this trigger spawned in this window before it hit the cap:
      #{links.join("\n")}

      The trigger page lists every session it has spawned, which is the authoritative list:
      #{base}/triggers/#{id}

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
      genesis: session_genesis,
      scheduling_class: session_scheduling_class,
      precedence: session_precedence,
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
      # without paging (the `Zimmer backend logging errors (excludes staging)`
      # Grafana rule matches severity_text:ERROR only). The unhealable branch
      # below still raises → .error → page, which IS correct (a scheduled wake
      # was genuinely lost); see
      # https://github.com/tadasant/zimmer-catalog/issues/4409.
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

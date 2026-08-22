class Session < ApplicationRecord
  include ActionView::RecordIdentifier
  include SessionStateMachine
  include AtomicJsonMetadata
  include SessionGenesisClassification
  include SessionPrecedence

  has_many :logs, dependent: :destroy
  has_many :subagent_transcripts, dependent: :destroy
  has_many :enqueued_messages, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :mcp_oauth_pending_flows, dependent: :destroy

  # Outcome analyses OF this session's transcript (the Outcomes view). No
  # `dependent:` — the foreign key is ON DELETE CASCADE, so the database already
  # guarantees an analysis cannot outlive the transcript it describes, and adding
  # a Rails-side sweep would only duplicate that at the cost of a query per
  # destroy. The reverse direction (analyses this session PRODUCED) is nullified,
  # so it is deliberately not modeled here as an ownership edge.
  has_many :outcome_analyses
  has_many :elicitations, dependent: :destroy

  # What Zimmer knows a named human said TO THIS SESSION. Read-only once
  # recorded (HumanMessage refuses update/destroy); it only goes away with the
  # session itself. Read it through SessionHumanMessages, which gathers the
  # whole spawn hierarchy's records and marks which were authored here.
  has_many :human_messages, dependent: :destroy

  # The cached "where things stand" blurb shown in the Status panel, plus the
  # bookkeeping that decides when it may be regenerated. See
  # SessionStatusSummary and SessionStatusSummaryGenerator.
  has_one :status_summary, class_name: "SessionStatusSummary", dependent: :destroy

  belongs_to :parent_session, class_name: "Session", optional: true
  has_many :child_sessions, class_name: "Session", foreign_key: :parent_session_id, dependent: :nullify

  # The second lineage edge: seniors that queued or interrupted this session
  # ("uncles"), and the sessions this one is senior to. Unlike the spawn edge
  # above, these are many-to-many, and they are DESTROYED rather than nullified —
  # an edge with one end missing asserts nothing, so it stops existing when
  # either session does. Written only by Sessions::RecordUncleEdge.
  has_many :session_uncle_links, dependent: :destroy
  has_many :uncle_sessions, through: :session_uncle_links, source: :uncle_session
  has_many :junior_uncle_links, class_name: "SessionUncleLink", foreign_key: :uncle_session_id, dependent: :destroy
  has_many :junior_sessions, through: :junior_uncle_links, source: :session

  # Organizational category for the sessions dashboard. A NULL category means the
  # session is "Uncategorized". Assigned via drag-and-drop on the index grid.
  belongs_to :category, optional: true

  # Throwaway forks that exist only to write another session's Status blurb (see
  # SessionStatusSummaryGenerator). They are ordinary sessions mechanically —
  # they run, pause, and get archived — but they are Zimmer's own bookkeeping
  # rather than the operator's work, so the lists an operator reads exclude them.
  scope :excluding_status_summary_forks, lambda {
    where("metadata->>? IS NULL", SessionStatusSummaryGenerator::FORK_MARKER)
  }

  # The sessions Zimmer spawns to analyze another session's transcript for the
  # Outcomes view (OutcomeAnalyses::SpawnAnalysisSession). An "Analyze All" batch
  # can put hundreds of these in flight at once, so they carry a marker that makes
  # them identifiable rather than being indistinguishable from the operator's own
  # work — the Outcomes ledger excludes them from the analyzable set, and the
  # dashboard offers them as a filter.
  OUTCOME_ANALYSIS_MARKER = "outcome_analysis_target_session_id"

  scope :outcome_analysis_sessions, lambda {
    where("metadata->>? IS NOT NULL", OUTCOME_ANALYSIS_MARKER)
  }
  scope :excluding_outcome_analysis_sessions, lambda {
    where("metadata->>? IS NULL", OUTCOME_ANALYSIS_MARKER)
  }

  scope :root_sessions, -> { where(parent_session_id: nil) }
  scope :children_of, ->(parent_id) { where(parent_session_id: parent_id) }

  # Sessions with an active heartbeat.
  scope :heartbeat_active, -> { where(heartbeat_enabled: true) }

  # Heartbeat-enabled sessions that are due for their next beat: either they have
  # never beaten, or one full interval has elapsed since the last beat. The
  # interval is per-row, so the comparison adds it to the last-beat timestamp in
  # SQL rather than assuming a fixed cadence. Used by HeartbeatSweepJob.
  scope :heartbeat_due, ->(now = Time.current) {
    heartbeat_active.where(
      "heartbeat_last_beat_at IS NULL OR heartbeat_last_beat_at + (heartbeat_interval_seconds * interval '1 second') <= ?",
      now
    )
  }

  # Sessions carrying the `blocked_on_elicitation` metadata marker (set by
  # block_on_elicitation, cleared by unblock_from_elicitation). Used by the
  # periodic reconciliation sweep in CleanupExpiredElicitationsJob to find
  # sessions whose marker may have been stranded (set with no active elicitation
  # remaining). Mirrors the instance-level `blocked_on_elicitation?` predicate.
  scope :blocked_on_elicitation, -> { where("metadata ->> 'blocked_on_elicitation' = 'true'") }

  # Excludes sessions that belong to a frozen category. Frozen categories are a
  # "park it and leave it alone" bucket: their sessions must be skipped by every
  # bulk "refresh / recover all sessions" flow. A LEFT JOIN is required so that
  # Uncategorized sessions (NULL category_id) are KEPT — a plain
  # `where.not(category_id: frozen_ids)` would silently drop NULL rows.
  scope :not_in_frozen_category, -> {
    left_joins(:category).where("categories.id IS NULL OR categories.is_frozen = ?", false)
  }

  # Active (non-archived, non-failed) sessions that have at least one associated
  # GitHub PR URL. Used by the GitHub poller jobs, which all scan the same set
  # every cron tick. The predicate is backed by a partial index on `id`
  # (index_sessions_on_pr_url_active_id, see the migration) whose WHERE clause
  # mirrors this scope exactly so the planner can use it to satisfy the
  # `ORDER BY id ASC LIMIT` batching that `find_each` generates. Keep the two in
  # sync: `where.not(status:)` emits `status NOT IN (3, 4)`, matching the index's
  # `status <> ALL (ARRAY[3, 4])` predicate, and the JSONB expression is byte-for-byte
  # identical. Diverging here silently demotes the query back to a full sequential scan.
  scope :with_github_prs, -> {
    where.not(status: %w[archived failed])
      .where("custom_metadata->>'github_pull_request_urls' IS NOT NULL")
  }

  # Broadcast changes to sessions index page
  # Only broadcast when attributes visible in the session card change
  # A status-summary fork is excluded from every server-rendered session list;
  # the live broadcasts have to agree, or it appears on the dashboard anyway —
  # once per completed turn, per session — and vanishes only when archived.
  after_update_commit :broadcast_update_to_sessions_index, if: :should_broadcast_to_index?
  after_create_commit :broadcast_create_to_sessions_index, unless: :status_summary_fork?
  after_destroy_commit :broadcast_remove_from_sessions_index

  # Deleting the row deletes the bytes it owns. `dependent: :destroy` above covers
  # the DB side; these three roots are the filesystem side — scratch, and the two
  # prompt-attachment trees — and they are keyed on the session id, so the moment
  # the row is gone nothing can query for them again (#340).
  #
  # after_destroy_commit, not before_destroy: the directories go only once the row
  # is really gone, so a destroy that rolls back — the row survives, and with it a
  # session that may still be resumed — cannot take that session's state with it.
  # Nothing on disk here is reconstructable, so the ordering is the difference
  # between a survivable rollback and an unrecoverable one.
  #
  # StaleCloneCleanupJob's per-session orphan sweep is the safety net behind this
  # — for rows deleted before this shipped, and for any delete path that skips
  # callbacks. This callback is what makes the common case prompt instead of
  # hourly. The clone is deliberately not reclaimed here: it already has its own
  # DB-driven and filesystem-driven reapers, and tearing one down means Docker
  # Compose teardown, which does not belong in a DELETE request.
  after_destroy_commit :reclaim_session_directories

  # Broadcast status changes to session detail page
  #
  # IMPORTANT: We use a before_save callback to track status changes instead of
  # checking saved_change_to_status? directly in the after_update_commit condition.
  #
  # This is necessary because when multiple database saves occur in a single transaction
  # (e.g., session.resume! followed by session.update!(metadata: ...)), the saved_changes
  # hash is reset after each save. By the time after_update_commit runs (after the
  # transaction commits), saved_change_to_status? reflects only the LAST save operation,
  # not any status changes that occurred earlier in the transaction.
  #
  # By tracking status changes in an instance variable during before_save, we ensure
  # the broadcast callback fires correctly even when status changes are followed by
  # other database operations in the same transaction.
  before_save :track_status_change_for_broadcast
  after_update_commit :broadcast_status_change, if: :status_changed_in_transaction?

  # Broadcast metadata changes to session detail page (e.g., clone_path, failure_reason, exit_status, exception_class)
  after_update_commit :broadcast_metadata_change, if: :should_broadcast_metadata_change?

  # Broadcast custom_metadata changes to session detail page (e.g., github_pull_request_statuses)
  after_update_commit :broadcast_custom_metadata_change, if: :saved_change_to_custom_metadata?

  # A newly-spawned child changes the hierarchy and human-message scope for
  # every open detail page in that lineage. The fresh GET path already computes
  # this correctly; this keeps already-open pages from staying on the solitary
  # snapshot they rendered before the child existed.
  after_create_commit :broadcast_provenance_change_to_hierarchy, if: -> { lineage_parent_id.present? }

  # Define the enum for status column - this provides helper methods and query scopes
  # AASM uses this enum for state transitions with enum: true option
  # Order must match database integer values:
  # NOTE: corrupted (5) was removed - sessions now transition to failed instead
  enum :status, {
    running: 0,
    waiting: 1,
    needs_input: 2,
    archived: 3,
    failed: 4
  }

  # Live, non-terminal statuses. A clone belonging to a session in one of these
  # states must NEVER be garbage-collected, no matter how old the clone is — a
  # session can sit idle in `needs_input` for weeks and still be resumed with its
  # filesystem expected intact. Archived and failed sessions are intentionally
  # excluded: their clones are reclaimed by the dedicated reapers after their own
  # grace windows (DeferredCloneCleanupJob / EmptyTrashJob for archived,
  # StaleCloneCleanupJob for failed-after-24h).
  NON_REAPABLE_STATUSES = %w[running waiting needs_input].freeze

  # Absolute, normalized clone paths for every live (non-reapable) session.
  #
  # This is the authoritative "never reap this, regardless of age" set shared by
  # the filesystem clone reapers. Paths are run through File.expand_path so the
  # comparison is robust to trailing slashes / non-canonical forms and can never
  # spuriously treat a live clone as an orphan.
  #
  # @return [Set<String>]
  def self.live_clone_paths
    where(status: NON_REAPABLE_STATUSES)
      .where("metadata->>'clone_path' IS NOT NULL")
      .pluck(Arel.sql("metadata->>'clone_path'"))
      .compact
      .map { |p| File.expand_path(p) }
      .to_set
  end

  # Sessions burning Claude Code quota right now — the number the spot gate
  # checks its fleet cap against, and the number recorded on every quota
  # snapshot so a reading can be attributed to the fleet that produced it.
  #
  # `running` only: a `waiting` session has no process and a `needs_input` one is
  # idle at a prompt. Runtime-scoped because a Codex session spends nothing
  # against a Claude account.
  #
  # Any database trouble reads as zero rather than raising: the spot gate calls
  # this on the path that decides whether a session may start, and a monitoring
  # gap must never fail a session. ConnectionNotEstablished descends from
  # AdapterError rather than StatementInvalid, so the rescue is deliberately the
  # whole ActiveRecordError family.
  def self.running_claude_code_count
    where(status: :running, agent_runtime: ClaudeAuthProvider::RUNTIME).count
  rescue ActiveRecord::ActiveRecordError
    0
  end

  # The SIGTERM retry counters alone. Follow-up delivery paths that only need to hand
  # the session a fresh SIGTERM budget (triggers, the GitHub pollers) clear this subset
  # rather than the full stale set, which would also discard state those paths have no
  # business touching.
  SIGTERM_RETRY_METADATA_KEYS = %w[
    sigterm_retry_count
    sigterm_retry_timestamps
    last_sigterm_at
  ].freeze

  # Metadata keys that should be cleared when restarting or resuming a session.
  # These track retry state and transcript polling state from previous execution
  # lifecycles and would cause false failures or silent transcripts if preserved
  # across restarts. Opens with SIGTERM_RETRY_METADATA_KEYS, the subset above.
  #
  # NOTE: api_error_last_checked_line is intentionally NOT included here.
  # It tracks the transcript scan position (which errors have already been handled)
  # and must be preserved across restarts. Clearing it causes the scanner to
  # re-process old errors, which can misclassify new transient rate limits as
  # quota limits when an old quota entry is encountered first.
  # The retry COUNTS (api_error_retry_count, last_api_error_retry_at) are cleared
  # to give fresh retry budget, but the scan position is preserved.
  #
  # The same split applies to auth recovery: the budget counters
  # (auth_recovery_count / last_auth_recovery_at and the adoption pair
  # auth_recovery_adoptions / last_auth_adoption_at) ARE cleared (fresh budget on
  # resume) but auth_error_last_checked_line is NOT — it is the AuthRecoveryService
  # scan position and must survive restarts so an already-handled "Not logged in"
  # entry isn't re-detected. auth_identity_email is likewise NOT cleared: it names
  # the login identity the process was spawned with, and AuthRecoveryCoordinator
  # needs it to tell an adoption from a rotation.
  #
  # The auth_outage_* keys (AuthOutageParkService) describe a session that is
  # dormant because its login pool had nothing usable. Any resume — the fleet
  # wake, a user follow-up, deployment recovery — ends that state, so they are
  # cleared here rather than by the one path that knows about them. Leaving them
  # behind would render an outage banner for an outage that is over, and would
  # keep matching AuthOutageParkService.parked_sessions, so a later ordinary
  # sleep could be force-resumed as if it were still parked.
  #
  # `auth_outage_early_wakes` is the deliberate exception — it records when the
  # sweep has already resumed one session on a changed account pool, and it has
  # to outlive the resume it paid for or it would never bound anything. See
  # AuthOutageParkService::EARLY_WAKE_LOG_KEY.
  #
  # SpotSessionPause::METADATA_KEYS are on the list for the same reason
  # `paused_by` is: they say the session is dormant in the spot queue, and a
  # session somebody restarted, continued or unarchived is not. Left behind, the
  # record outlives the park — and the next ordinary "Pause Until 9 AM" on that
  # session would land in `waiting` still matching SpotSessionPause.paused?, so
  # the ceiling sweep would resume it long before the time its human chose.
  STALE_RETRY_METADATA_KEYS = (SIGTERM_RETRY_METADATA_KEYS + %w[
    failure_reason
    exit_status
    mcp_failed_servers
    paused_by
    compact_retry_count
    pending_compact_continuation
    context_length_last_checked_line
    last_compact_at
    prompt_too_long_hang_detected
    prompt_too_long_hang_detected_at_line
    api_error_retry_count
    last_api_error_retry_at
    signal_death_retry_count
    last_signal_death_at
    quota_limit_count
    last_quota_limit_at
    last_quota_limit_message
    auth_recovery_count
    last_auth_recovery_at
    auth_recovery_adoptions
    last_auth_adoption_at
    auth_outage_reason
    auth_outage_parked_at
    auth_outage_pool_recovers_at
    auth_outage_pool_fingerprint
    mcp_retry_count
    mcp_last_retry_at
    broadcast_message_count
    transcript_waiting_logged
    transcript_files_waiting_logged
    transcript_reading_started_logged
    interrupted_start_requeue_count
    recovery_continue_attempts
  ] + SpotSessionPause::METADATA_KEYS).freeze

  # Metadata keys rendered by the session metadata partial. A change to any of them is
  # what makes a metadata write worth broadcasting.
  METADATA_DISPLAY_FIELDS = %w[
    clone_path
    full_clone_path
    failure_reason
    exit_status
    exception_class
  ].freeze

  # Failure reasons that indicate the session failed before the initial prompt
  # was ever processed by the agent. When restarting a session with one of these
  # failure reasons, the original prompt should be re-sent instead of a generic
  # system recovery message.
  #
  # IMPORTANT: If you add a new failure_reason in AgentSessionJob that occurs before
  # the initial prompt is processed, add it here too. See AgentSessionJob for all
  # failure_reason assignments.
  PRE_PROMPT_FAILURE_REASONS = %w[
    mcp_connection_failed
    oauth_required
    spawn_failed
    git_clone_failed
    clone_validation_failed
  ].freeze

  # Metadata keys that represent setup artifacts created during session initialization.
  # These are cleared when restarting a session from scratch (e.g., after git clone
  # failure) to ensure the job starts with a clean slate. Stored alongside
  # STALE_RETRY_METADATA_KEYS because both are cleared during restart, but these
  # represent infrastructure state rather than retry counters.
  SETUP_ARTIFACT_KEYS = %w[
    clone_path
    working_directory
    full_clone_path
    process_pid
    runtime_started
  ].freeze

  # Marks an empty mcp_servers column as a deliberate "no servers" choice rather
  # than a column that landed empty by accident. See #record_explicit_mcp_servers.
  EXPLICIT_EMPTY_MCP_SERVERS_KEY = "mcp_servers_explicitly_empty"

  # The agent root used for routing freeform user requests from the dashboard
  ROUTER_AGENT_ROOT = "zimmer-router"

  # Execution providers a session may declare. Local filesystem is the only one: agents run
  # unsandboxed on the app host, and Zimmer has no sandboxed alternative to offer. The one
  # other provider class that exists, lib/execution/providers/remote_sandbox.rb, is an unwired
  # stub whose every method returns Result.failure("not yet implemented"), so this enum lists
  # only what can actually run. See docs limitations.md and
  # https://github.com/tadasant/zimmer/issues/49.
  EXECUTION_PROVIDERS = %w[local_filesystem].freeze

  # Character limits for prompts and goals
  # These limits are set to allow for large prompts while staying well within
  # Claude's ~200k token context window (~800k-1M characters). The prompt limit
  # of 500k characters leaves ample room for conversation history and system context.
  PROMPT_MAX_LENGTH = 500_000
  GOAL_MAX_LENGTH = 50_000

  # Upper bound for the Claude Code auto-compact window (context window, in
  # tokens). 1M is well above any realistic Claude Code model context (~200K)
  # while still preventing runaway/typo values from polluting the spawn env.
  MAX_AUTO_COMPACT_WINDOW = 1_000_000

  # Heartbeat: how often (in seconds) an enabled heartbeat may beat. The floor
  # keeps the recurring sweep from hammering a session; the ceiling caps a beat
  # at once per day. The UI presents a curated subset of these values.
  HEARTBEAT_MIN_INTERVAL_SECONDS = 30
  HEARTBEAT_MAX_INTERVAL_SECONDS = 86_400
  HEARTBEAT_DEFAULT_INTERVAL_SECONDS = 60

  # Curated interval choices offered in the heartbeat popout (label => seconds).
  # The default (1 minute) is the second entry so it lands selected out of the box.
  HEARTBEAT_INTERVAL_OPTIONS = [
    [ "30 seconds", 30 ],
    [ "1 minute", 60 ],
    [ "2 minutes", 120 ],
    [ "5 minutes", 300 ],
    [ "10 minutes", 600 ],
    [ "15 minutes", 900 ],
    [ "30 minutes", 1800 ],
    [ "1 hour", 3600 ]
  ].freeze

  # Whether the web UI should offer "Pause Until" for this session.
  #
  # Narrower than Sessions::ScheduleWakeUp::WAKEABLE_STATUSES, which is the
  # question an agent asks about itself. A `waiting` session that has never
  # started is not asleep — it is queued for spawn, and `waiting` is simply the
  # AASM initial state. Arming a wake there tells the operator the session is
  # paused while the spawn pipeline goes right on starting it: `start` (unlike
  # `resume`) does not consume the wake, so the trigger is left armed behind a
  # session that is already running.
  def pausable_until?
    return false unless Sessions::ScheduleWakeUp::WAKEABLE_STATUSES.include?(status.to_s)
    return false if waiting? && session_id.blank?

    true
  end

  # Choices offered by the "Pause Until" control, in order. `key` is the contract
  # with pause_until_controller.js, which resolves each one to an absolute time in
  # the BROWSER's timezone — the wall-clock presets ("Tomorrow, 9:00 AM") mean the
  # operator's morning, not the server's, and only the browser knows which that is.
  # Anything not on this list goes through the datetime picker instead.
  PAUSE_UNTIL_PRESETS = [
    { key: "15m", label: "In 15 minutes" },
    { key: "1h", label: "In 1 hour" },
    { key: "3h", label: "In 3 hours" },
    { key: "tonight", label: "Tonight, 6 PM" },
    { key: "tomorrow", label: "Tomorrow, 9 AM" },
    { key: "monday", label: "Monday, 9 AM" }
  ].freeze

  # The one choice in the same panel that is not a time, and therefore not a
  # preset: "Spot Queue" sleeps the session and slots it into the spot queue
  # instead of arming a wake-up (Sessions::PauseIntoSpotQueue). It is deliberately
  # NOT in PAUSE_UNTIL_PRESETS — every entry there is a key the browser resolves
  # to an absolute instant, and there is no instant to resolve here. The value is
  # the `mode` SessionsController#pause_until switches on.
  PAUSE_UNTIL_SPOT_QUEUE_MODE = "spot_queue"

  # Validations
  # Prompt is now optional to allow for "clone only" sessions
  validates :prompt, length: { maximum: PROMPT_MAX_LENGTH, message: "is too long (maximum #{PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)" }, allow_blank: true
  # The valid set tracks RuntimeRegistry rather than a hardcoded list, so a
  # session may declare any registered runtime (today only "claude_code"). This
  # lets a caller spawn a session under a non-default runtime once a second
  # runtime is registered, without revisiting this validation.
  validates :agent_runtime, inclusion: { in: ->(_) { RuntimeRegistry.registered_runtimes }, message: "%{value} is not a valid agent runtime" }
  validates :execution_provider, inclusion: { in: EXECUTION_PROVIDERS, message: "%{value} is not a valid execution provider" }
  validates :git_root, presence: true
  validates :branch, presence: true
  validates :slug, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/, message: "only allows lowercase letters, numbers, and hyphens" }, allow_nil: true
  validates :title, length: { maximum: 100, message: "is too long (maximum 100 characters)" }, allow_nil: true
  validates :goal, length: { maximum: GOAL_MAX_LENGTH, message: "is too long (maximum #{GOAL_MAX_LENGTH.to_fs(:delimited)} characters)" }, allow_nil: true
  validates :session_notes, length: { maximum: 50_000, message: "is too long (maximum 50,000 characters)" }, allow_nil: true
  # Cap at 1M tokens — well above any realistic Claude Code model context (~200K)
  # while still preventing runaway/typo values from polluting the spawn env.
  # This budget is runtime-scoped: the runtime adapter decides whether to surface
  # and honor it (Claude does; runtimes without a token-budget knob ignore it).
  validates :auto_compact_window, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_AUTO_COMPACT_WINDOW }
  validates :heartbeat_interval_seconds, numericality: { only_integer: true, greater_than_or_equal_to: HEARTBEAT_MIN_INTERVAL_SECONDS, less_than_or_equal_to: HEARTBEAT_MAX_INTERVAL_SECONDS }
  validate :mcp_servers_must_be_array
  validate :mcp_servers_must_exist_in_catalog, if: :mcp_servers_changed?
  validate :catalog_skills_must_be_array
  validate :catalog_skills_must_exist_in_catalog, if: :catalog_skills_changed?
  validate :catalog_hooks_must_be_array
  validate :catalog_hooks_must_exist_in_catalog, if: :catalog_hooks_changed?
  validate :catalog_plugins_must_be_array
  validate :catalog_plugins_must_exist_in_catalog, if: :catalog_plugins_changed?
  validate :git_root_format, if: :git_root?
  # parent_session_id is client-supplied (POST /api/v1/sessions permits it, and the
  # dashboard passes it straight through from params), and `belongs_to ..., optional:
  # true` does not check that the row exists. The database refuses a pointer to a
  # missing session, so without this an unknown id would surface as an
  # ActiveRecord::InvalidForeignKey 500 instead of a 422 naming the bad field.
  validate :parent_session_must_exist, if: :parent_session_id_changed?

  after_create :set_default_title
  after_create_commit :enqueue_session_inference

  # The session that SPAWNED this one, as an id.
  #
  # Two representations, one meaning. `parent_session_id` is the first-class
  # column and wins when set. Sessions spawned before that was wired recorded
  # the same fact in `custom_metadata["router_session_id"]`, so the tree is
  # derived from that as a fallback rather than backfilled — no migration
  # rewrites what a session recorded about itself, and nothing is lost if the
  # derivation is later removed.
  #
  # This is spawn lineage. A session is routinely followed up by a router other
  # than the one that spawned it, so this is NOT "who talked to me last".
  def lineage_parent_id
    return parent_session_id if parent_session_id.present?

    derived = custom_metadata&.dig("router_session_id")
    return nil if derived.blank?

    Integer(derived, exception: false)
  end

  # The whole family of sessions this one belongs to — origin at the root, every
  # descendant below. Not memoized: the per-turn prompt build and the detail
  # screen both want current state.
  def hierarchy
    SessionHierarchy.new(self)
  end

  # Every human message in that hierarchy, each marked as authored here or
  # elsewhere.
  def human_message_record
    SessionHumanMessages.new(self)
  end

  # True when this session was forked purely to write another session's Status
  # blurb. Such a fork never gets a summary of its own, never notifies, and is
  # archived as soon as its answer has been harvested.
  def status_summary_fork?
    metadata&.dig(SessionStatusSummaryGenerator::FORK_MARKER).present?
  end

  # The source session a summary fork is summarizing, or nil.
  def status_summary_source_id
    metadata&.dig(SessionStatusSummaryGenerator::FORK_MARKER)
  end

  # The bundle of pluggable implementations for this session's agent runtime
  # (CLI adapter, retry strategy, transcript source/normalizer, prompt
  # contribution, ...). Resolved from RuntimeRegistry by agent_runtime. Callers
  # read the class slot they need and instantiate with their own dependencies.
  def runtime
    RuntimeRegistry.for(agent_runtime)
  end

  # The directory the runtime CLI is (or was) spawned in: the recorded working
  # directory, which is the clone root for a session without an agent root and a
  # subdirectory of it for one with. A session that has a clone but has not been
  # spawned in yet records only the clone root, which is the correct answer for it.
  #
  # @return [String, nil] nil until the session establishes a clone
  def working_directory
    metadata&.dig("working_directory").presence || metadata&.dig("clone_path").presence
  end

  # Where this session's spawned process writes its stderr.
  #
  # Every caller that reconnects to a process it did not spawn — the job resuming
  # monitoring, ProcessLifecycleManager after a recovery spawn, the interrupt and
  # termination paths — has to rebuild this path from session state. It must be
  # built from the WORKING directory (an agent-root session spawns in a
  # subdirectory of the clone, and its log lives there) and named by the session's
  # own runtime (a Codex session writes codex_stderr.log, not claude_stderr.log).
  # Rebuilding it any other way points the monitoring loop at a file that does not
  # exist, which silently disables context-length and failed-resume recovery —
  # both of which are detected by reading this log.
  #
  # @return [String, nil] nil until the session establishes a working directory
  def stderr_log_path
    RuntimeRegistry.cli_adapter_class_for(agent_runtime).stderr_log_path(working_directory)
  end

  # Record the agent process this session is now running, in one statement.
  #
  # `process_pid` alone is not a usable handle: a pid is only meaningful in the PID
  # namespace it was issued in, and it can be recycled. AgentProcessLiveness captures
  # both facts alongside it, and the spawn-time orphan guard reads that identity — so
  # the two keys must never drift apart. Every site that records a freshly spawned agent
  # process goes through here for that reason; writing "process_pid" on its own leaves
  # the guard pointed at the *previous* turn's pid, which reads dead and silently
  # disables it.
  #
  # @param pid [Integer] the pid just spawned, in THIS process's namespace
  # @param extra [Hash] additional metadata keys to set in the same UPDATE
  # @param remove [Array<String>] metadata keys to drop in the same UPDATE
  def record_agent_process!(pid, extra = {}, remove = [])
    merge_metadata!(
      {
        "process_pid" => pid,
        AgentProcessLiveness::IDENTITY_KEY => AgentProcessLiveness.identity_for(pid)
      }.merge(extra),
      remove
    )
  end

  # Whether this session's heartbeat is due to beat again. Mirrors the
  # `heartbeat_due` scope so HeartbeatSweepJob can re-check a single session
  # under lock (guarding against two overlapping sweeps beating twice).
  def heartbeat_due?(now = Time.current)
    return false unless heartbeat_enabled?
    return true if heartbeat_last_beat_at.nil?

    heartbeat_last_beat_at + heartbeat_interval_seconds <= now
  end

  # True when replacing +stored+ with +incoming+ would drop conversation events —
  # i.e. the incoming transcript has fewer lines than what is already stored.
  #
  # session.transcript is the only durable record of a session's conversation: the
  # UI renders from it and the on-disk clone is transient (recreated at a new path
  # after a deploy wipes the working tree, then reclaimed by cleanup jobs). When a
  # clone is recreated the runtime starts a fresh, shorter transcript file;
  # persisting that over the stored transcript would orphan and ultimately destroy
  # the prior history. Callers use this to refuse such overwrites. Equal-or-greater
  # counts are NOT regressions (normal append growth, or an in-place edit of the
  # latest event).
  def self.transcript_regression?(stored, incoming)
    transcript_line_count(incoming) < transcript_line_count(stored)
  end

  # Parse the stored transcript into raw event hashes via the runtime source.
  def parsed_transcript
    return [] unless transcript.present?

    # Handle both array (legacy) and string (JSONL) formats
    if transcript.is_a?(Array)
      return transcript
    end

    transcript_source.parse_events(transcript)
  end

  # Parse only the last N lines of the JSONL transcript.
  # Much faster than parsed_transcript for large transcripts when only
  # recent entries are needed (e.g., initial page load showing last 100 items).
  #
  # Returns [entries, total_line_count] where entries is an array of parsed
  # JSON objects and total_line_count is the total number of lines in the transcript.
  # The transcript_offset in each entry reflects its position in the full transcript.
  def parsed_transcript_tail(n)
    return [ [], 0 ] unless transcript.present?

    if transcript.is_a?(Array)
      total = transcript.size
      offset = [ total - n, 0 ].max
      entries = transcript.last(n).each_with_index.map do |entry, i|
        entry.merge("_transcript_index" => offset + i)
      end
      return [ entries, total ]
    end

    all_lines = transcript.lines
    total = all_lines.size
    tail_lines = all_lines.last(n)
    offset = total - tail_lines.size

    entries = tail_lines.each_with_index.filter_map do |line, i|
      parsed = transcript_source.parse_events(line).first
      next if parsed.nil?

      parsed["_transcript_index"] = offset + i
      parsed
    end

    [ entries, total ]
  end

  # Parse transcript lines within a specific index range [start_idx, end_idx).
  # Used by timeline_items for efficient infinite scroll pagination.
  def parsed_transcript_range(start_idx, end_idx)
    return [] unless transcript.present?

    if transcript.is_a?(Array)
      selected = transcript[start_idx...end_idx] || []
      return selected.each_with_index.map do |entry, i|
        entry.merge("_transcript_index" => start_idx + i)
      end
    end

    all_lines = transcript.lines
    selected = all_lines[start_idx...end_idx] || []
    selected.each_with_index.filter_map do |line, i|
      parsed = transcript_source.parse_events(line).first
      next if parsed.nil?

      parsed["_transcript_index"] = start_idx + i
      parsed
    end
  end

  # Count total transcript lines without parsing.
  # Orders of magnitude faster than parsed_transcript.count for large transcripts.
  def transcript_line_count
    self.class.transcript_line_count(transcript)
  end

  # Count the lines (events) in any transcript value, without needing a Session
  # instance. JSONL transcripts store one event per line; the legacy array format
  # stores one event per element. Used both by the instance method above and by
  # transcript_regression? to compare a stored transcript against an incoming one.
  def self.transcript_line_count(value)
    return 0 unless value.present?
    return value.size if value.is_a?(Array)
    newline_count = value.count("\n")
    # If the transcript doesn't end with a newline, there's one more line
    newline_count += 1 unless value.end_with?("\n")
    newline_count
  end

  # Format transcript as conversation messages for display
  # Groups related messages and extracts all content properly
  def formatted_conversation
    entries = parsed_transcript
    return [] if entries.empty?

    messages = []

    # Filter to only user and assistant type messages
    conversation_entries = entries.select { |e| e["type"].in?([ "user", "assistant" ]) }

    conversation_entries.each do |entry|
      message_data = entry["message"] || {}
      role = message_data["role"] || entry["type"]
      timestamp = entry["timestamp"]

      # Extract all content from the message
      content_parts = []

      if message_data["content"].is_a?(Array)
        # Process array content (assistant messages, tool results)
        message_data["content"].each do |block|
          case block["type"]
          when "text"
            content_parts << { type: "text", text: block["text"] } if block["text"].present?
          when "tool_use"
            # Format tool use nicely
            tool_name = block["name"]
            tool_input = block["input"] || {}
            description = tool_input["description"]
            command = tool_input["command"]

            tool_text = "**Using tool: #{tool_name}**"
            tool_text += "\n#{description}" if description.present?
            tool_text += "\n```\n#{command}\n```" if command.present?

            content_parts << { type: "tool_use", text: tool_text }
          when "tool_result"
            # Format tool results
            result_content = block["content"]
            if result_content.present?
              result_text = "**Tool Result:**\n```\n#{result_content}\n```"
              content_parts << { type: "tool_result", text: result_text }
            end
          end
        end
      elsif message_data["content"].is_a?(String)
        # Simple string content (user messages)
        content_parts << { type: "text", text: message_data["content"] } if message_data["content"].present?
      end

      # Only add messages that have content
      next if content_parts.empty?

      messages << {
        role: role,
        content: content_parts.map { |p| p[:text] }.join("\n\n"),
        timestamp: timestamp,
        has_tool_use: content_parts.any? { |p| p[:type] == "tool_use" },
        has_tool_result: content_parts.any? { |p| p[:type] == "tool_result" }
      }
    end

    messages
  end

  # Extract agent root name from git root URL
  def agent_root_name
    return nil if git_root.blank?

    # Extract repo name from URL
    # Examples:
    # https://github.com/anthropics/anthropic-cookbook.git -> anthropic-cookbook
    # https://github.com/user/repo -> repo
    # /path/to/local/repo -> repo
    if git_root.match?(%r{github\.com|gitlab\.com|bitbucket\.org})
      # Remote URL
      git_root.split("/").last&.gsub(/\.git$/, "")
    else
      # Local path
      File.basename(git_root)
    end
  end

  # Get full agent root path including subdirectory
  # Examples:
  # git_root: "agents", subdirectory: "zimmer" -> "agents/zimmer"
  # git_root: "agents", subdirectory: nil -> "agents"
  def agent_root_path
    return nil if agent_root_name.blank?

    if subdirectory.present?
      "#{agent_root_name}/#{subdirectory}"
    else
      agent_root_name
    end
  end

  # The agent root this session resolves to in the *current* catalog, or nil if
  # it can't be resolved (no agent_root_key and no URL+subdirectory match).
  #
  # Deliberately NOT memoized: resolution keys off mutable attributes
  # (metadata["agent_root_key"], git_root, subdirectory), so caching the result
  # on the instance would go stale if those change after the first call — e.g. a
  # session built then `update!`d to set its agent_root_key resolves to nil on
  # the first touch and would keep returning nil. The underlying catalog
  # (AgentRootsConfig.all) is itself cached, so re-resolving per call is cheap.
  def resolved_agent_root
    AgentRootsConfig.find_for_session(self)
  end

  # The canonical key of the session's agent root from roots.json
  # (e.g., "zimmer", "agents", "zimmer-router").
  #
  # Prefers the explicit key stored in metadata at creation time, then falls back
  # to resolving by git_root URL + subdirectory against the current catalog.
  # Returns nil if the session cannot be resolved to a catalog entry.
  def agent_root_key
    resolved_agent_root&.name
  end

  # The artifact defaults the session's agent root *currently* declares. A
  # session freezes its own catalog columns at creation time, but those columns
  # can land empty when the catalog transiently resolved no defaults for the root
  # (e.g. a last-known-good snapshot predating a default_in_roots migration). The
  # detail UI uses these to show what the root provides — clearly labeled as
  # inherited — instead of a bare "None" for such sessions. Returns [] when the
  # root can't be resolved.
  def agent_root_default_mcp_servers
    resolved_agent_root&.default_mcp_servers || []
  end

  def agent_root_default_skills
    resolved_agent_root&.default_skills || []
  end

  def agent_root_default_hooks
    resolved_agent_root&.default_hooks || []
  end

  def agent_root_default_plugins
    resolved_agent_root&.default_plugins || []
  end

  # Override to_param to use slug if available, otherwise use id
  def to_param
    slug.presence || id.to_s
  end

  # Check if the session was recently recovered by the cleanup job. The detail
  # view uses this to show the "connection recovered" banner on the page load
  # right after a recovery; the 5-second window keeps the banner to that one
  # load rather than following the session around.
  #
  # Re-establishing the Turbo Stream subscriptions is not this flag's job — the
  # cable-reconnect Stimulus controller does that from the subscription's own
  # connection state, whether or not a recovery happened.
  #
  # @return [Boolean] true if a recovery log exists within the last 5 seconds
  def recently_recovered?
    logs.where(level: "info")
        .where("content LIKE ?", "%Recovery job enqueued%")
        .where("created_at > ?", 5.seconds.ago)
        .exists?
  end

  # Timestamp of the most recent explicit user interaction with this session
  # (creating it, sending a follow-up, enqueueing a message, or interrupting
  # with "send now"). Used by PollBackoff to decide how often to poll GitHub
  # for this session.
  #
  # Falls back to created_at when no activity timestamp has been recorded yet.
  # Background-job updates (e.g., transcript polling, status broadcasts) do
  # NOT touch this — keeping the signal a true measure of user engagement.
  def last_user_activity_at
    raw = metadata&.dig("last_user_activity_at")
    if raw.present?
      parsed = parse_metadata_timestamp(raw)
      return parsed if parsed
    end
    created_at
  end

  # Stamp the session with a fresh user-activity marker. Called from controller
  # actions where the user explicitly engages with the session (follow-ups,
  # enqueueing, interrupting).
  def touch_user_activity!
    merge_metadata!("last_user_activity_at" => Time.current.iso8601)
  end

  # Resume this session because Zimmer restarted its process, not because anyone
  # decided it should wake up.
  #
  # Every automatic recovery path (deployment restart, orphaned process,
  # hung-process reap, health-monitor retry) resumes a session that may have been
  # asleep on wake-up triggers. Going through `resume!` directly consumes those
  # triggers, which is right for a deliberate resume and wrong here — see
  # SessionStateMachine#system_recovery_resume. Recovery paths call this instead.
  #
  # The flag is cleared in an ensure block so it can never leak into a later,
  # genuinely deliberate resume of the same in-memory instance.
  #
  # @return [Boolean] true when the session was resumed, false when it was not in
  #   a resumable state
  def resume_for_system_recovery!
    return false unless may_resume?

    self.system_recovery_resume = true
    resume!
    true
  ensure
    self.system_recovery_resume = false
  end

  # Deliver a follow-up prompt to an idle (waiting / needs_input) session.
  #
  # Drop the stale per-turn state, transition to running, stamp the prompt where the
  # recovery paths look for it, enqueue the agent job, and record the job id. That
  # sequence lived in five near-identical copies — the web follow-up form, triggers, the
  # GitHub comment and merge-conflict pollers, and the heartbeat sweep — so every fix to
  # the delivery path had to be made five times. The heartbeat sweep said so in a comment.
  # Those five now share this one copy.
  #
  # Two direct-delivery paths deliberately do NOT route here, and it is worth knowing
  # which: `Api::V1::SessionsController#follow_up` (which never stamped
  # `pending_follow_up_prompt` and would change behaviour if it started) and
  # `EnqueuedMessageProcessorService` (which delivers a message it has already claimed
  # from a queue, under different locking). #105 is not fully closed by this method.
  #
  # Callers keep what is genuinely theirs (validation, logging, broadcasting) and pass
  # only what differs. The prompt is stamped AFTER the state transition, so a reader who
  # sees `pending_follow_up_prompt` is guaranteed to also see `running`.
  #
  # The sequence is not atomic end to end: `resume!` runs state-machine callbacks that
  # rewrite `metadata` whole-column (`clear_pending_sleep`, `clear_paused_by_metadata`),
  # between the two merges here. Each individual write is atomic; a key another writer
  # sets during the transition itself can still be lost.
  #
  # @param prompt [String] the prompt to deliver
  # @param clear_metadata_keys [Array<String>] stale metadata keys to drop first
  # @param metadata_updates [Hash] extra metadata stamped alongside the prompt
  # @param stamp_pending_prompt [Boolean] whether to record `pending_follow_up_prompt`,
  #   the marker SigtermRetryService and the pause path read to recover an undelivered
  #   prompt. False for the heartbeat nudge, which is a system drumbeat: resurrecting it
  #   after a SIGTERM would deliver a beat for a moment that has already passed.
  # @param images [Array, nil] image paths forwarded to the job
  # @param files [Array, nil] file paths forwarded to the job
  # @return [ActiveJob::Base] the enqueued job
  def deliver_follow_up!(prompt, clear_metadata_keys: [], metadata_updates: {}, stamp_pending_prompt: true, images: nil, files: nil)
    # Clear the whole set once any member of it is present, rather than clearing only
    # the present members. That is what the five call sites did, and the difference is
    # real: a key held as `false`, `""` or `[]` is not `present?`, so per-key filtering
    # would leave it behind for the next turn to read.
    stale = Array(clear_metadata_keys)
    remove_metadata!(stale) if stale.any? { |key| metadata&.dig(key).present? }

    resume! if may_resume?

    updates = metadata_updates.to_h
    updates = updates.merge("pending_follow_up_prompt" => prompt) if stamp_pending_prompt
    merge_metadata!(updates) if updates.any?

    # Record running_job_id immediately rather than waiting for the job to record it
    # itself. That closes the window where the session is "running" with no tracked job —
    # a window in which a delayed or dead job leaves the session stuck with no feedback,
    # and orphan detection has nothing to look at.
    job = AgentSessionJob.enqueue_with_prompt(id, prompt, images: images, files: files)
    job_id = job.try(:job_id)

    if job_id.present?
      update!(running_job_id: job_id)
    else
      # ActiveJob's contract lets `perform_later` return false when a callback aborts
      # the enqueue. No job registers such a callback today, so this is unreachable
      # rather than tolerated — but if it ever fires, the session is left `running` with
      # a stamped prompt, no job, and nothing for orphan detection to find. Say so
      # loudly instead of returning quietly; no caller inspects the return value.
      Rails.logger.error(
        "[Session#deliver_follow_up!] Session #{id} was resumed but AgentSessionJob.enqueue_with_prompt " \
        "returned no job id — the session is running with no tracked job"
      )
    end

    job
  end

  # Records a human "view" of this session (opening its page or drawer in the
  # web UI) as user activity. A view is genuine human engagement — "eyes on the
  # session" — so it shares the same last_user_activity_at marker that
  # touch_user_activity! writes, which also keeps PollBackoff's notion of
  # engagement accurate.
  #
  # Unlike touch_user_activity!, this writes via update_column so a mere view
  # does NOT fire the after_update_commit callbacks (should_broadcast_to_index?
  # treats any metadata change as broadcast-worthy). Without this, every page
  # view would rebroadcast the session card to every connected dashboard. This
  # mirrors how last_broadcast_to_index_at is written via update_column.
  def touch_user_view!
    update_column(
      :metadata, (metadata || {}).merge("last_user_activity_at" => Time.current.iso8601)
    )
  end

  # Returns true if the session failed before the initial prompt was ever
  # processed by the agent. This happens when MCP servers fail to connect,
  # OAuth is required, the git clone fails, or the CLI process fails to spawn.
  # In these cases, restarting should re-send the original prompt rather than
  # a generic system recovery message.
  def failed_before_initial_prompt?
    failure_reason = metadata&.dig("failure_reason")
    failure_reason.present? && PRE_PROMPT_FAILURE_REASONS.include?(failure_reason)
  end

  # Human-readable one-line summary of why this session failed. Suitable for
  # push notification bodies, titles, and the session UI — a single source of
  # truth so every surface describes a failure the same way.
  #
  # Names the failing MCP server(s) for MCP connection / OAuth failures so the
  # user knows *which* server to look at, not just that "an error" occurred.
  #
  # @return [String, nil] summary string, or nil when no failure_reason recorded
  def failure_summary
    reason = metadata&.dig("failure_reason")
    return nil if reason.blank?

    case reason
    when "mcp_connection_failed"
      servers = failed_mcp_server_names
      if servers.any?
        "MCP server(s) failed to connect: #{servers.join(', ')}"
      else
        # Fall back to the pre-computed reason persisted by McpStatusPersisting
        # when the per-server list was cleared but the summary string remains.
        custom_metadata&.dig("mcp_failure_reason").presence || "MCP server connection failed"
      end
    when "oauth_required"
      servers = oauth_required_server_names
      servers.any? ? "OAuth authorization required: #{servers.join(', ')}" : "OAuth authorization required"
    when "air_secret_unresolvable"
      # AgentSessionJob persists the names AirPrepareService extracted from the
      # `air prepare` failure. Without this branch they had no reader at all and
      # the user saw "Air secret unresolvable" — a restatement of the failure
      # that names neither the secret nor the fix.
      variables = unresolved_variable_names
      if variables.any?
        "Missing secret(s): #{variables.join(', ')} — add them to Zimmer's mcp_secrets credentials, " \
          "or deselect the MCP server that needs them"
      else
        "An MCP server requires a secret Zimmer does not carry — add it to Zimmer's mcp_secrets credentials, " \
          "or deselect the server that needs it"
      end
    else
      reason.humanize
    end
  end

  # Longer per-server error detail for an MCP connection failure, joining each
  # failed server's specific error message. Returns nil when there is nothing
  # beyond what failure_summary already conveys.
  #
  # @return [String, nil]
  def failure_detail
    return nil unless metadata&.dig("failure_reason") == "mcp_connection_failed"

    details = (custom_metadata&.dig("mcp_failed_servers") || []).filter_map do |server|
      error = server["error"].presence
      error ? "#{server['name']}: #{error}" : nil
    end
    details.any? ? details.join("; ") : nil
  end

  # Names of MCP servers that failed to connect, from the persisted failure metadata.
  # @return [Array<String>]
  def failed_mcp_server_names
    (custom_metadata&.dig("mcp_failed_servers") || []).filter_map { |s| s["name"] }
  end

  # Names of the ${VAR} references `air prepare` could not resolve, from the
  # failure metadata AgentSessionJob persists on an air_secret_unresolvable fail.
  # @return [Array<String>]
  def unresolved_variable_names
    Array(metadata&.dig("unresolved_variables")).compact_blank
  end

  # Names of MCP servers awaiting OAuth authorization, from the failure metadata.
  # @return [Array<String>]
  def oauth_required_server_names
    (metadata&.dig("oauth_required_servers") || []).filter_map { |s| s["server_name"] || s[:server_name] }
  end

  # Returns true if the session's setup artifacts are complete enough to restart
  # with a follow-up prompt. Returns false when setup never completed (e.g., git
  # clone failed before session_id and clone_path were populated).
  #
  # @return [Boolean] true if session_id and clone_path exist
  def setup_complete?
    session_id.present? && metadata&.dig("clone_path").present?
  end

  # How many slug candidates to try before giving up. Each rejected write costs
  # one round trip; a session that cannot find a free suffix in this many tries
  # is hitting something no amount of further spinning will resolve.
  MAX_SLUG_ATTEMPTS = 10

  # The unique index that arbitrates slug ownership. `sessions` carries other
  # unique indexes, so a rejected write is only ours to retry when it names this
  # one — a collision anywhere else must surface on the first attempt.
  SLUG_UNIQUE_INDEX = "index_sessions_on_slug"

  # Generate slug from title + datetime
  # Called by SessionTitleJob after title is generated
  def generate_slug_from_title!
    return if slug.present? || title.blank?

    # Create slug from title + datetime
    # Format: "fix-authentication-bug-20251114-1430" (title-yyyymmdd-hhmm)
    timestamp = created_at.strftime("%Y%m%d-%H%M")
    # parameterize preserves underscores (its regex allows [a-z0-9\-_]), but the
    # slug column validation only permits /\A[a-z0-9-]+\z/. Fold underscores into
    # hyphens, then collapse runs and trim so any title yields a valid slug.
    title_slug = title.parameterize.tr("_", "-").squeeze("-").delete_prefix("-").delete_suffix("-")
    base_slug = "#{title_slug}-#{timestamp}"

    # Picking a free suffix by reading first is check-then-act: two title jobs
    # for sessions created in the same minute compute the same base_slug, both
    # read it as free, and both write it. The read below only skips suffixes
    # already visible; `index_sessions_on_slug` is the authority, so a lost race
    # arrives as a rejected write — advance the counter and try the next suffix
    # rather than leaving the losing session slug-less.
    candidate_for = ->(n) { n.zero? ? base_slug : "#{base_slug}-#{n}" }
    counter = 0
    attempts = 0

    begin
      attempts += 1
      counter += 1 while Session.exists?(slug: candidate_for.call(counter))
      # requires_new so a rejected write unwinds to a savepoint rather than
      # poisoning an enclosing transaction, which would strand the retry.
      self.class.transaction(requires_new: true) { update!(slug: candidate_for.call(counter)) }
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise unless slug_collision?(e)

      if attempts >= MAX_SLUG_ATTEMPTS
        # Leave the caller a record whose slug is nil rather than one holding a
        # value the index has already refused.
        restore_attributes([ :slug ])
        raise
      end

      counter += 1
      retry
    end
  end

  # Create a session from an agent root configuration and start it.
  # Shared by Trigger#create_session! and the dashboard quick prompt.
  #
  # @param agent_root_name [String] name of the agent root in the catalog
  # @param prompt [String] the prompt to send to the agent
  # @param agent_runtime [String, nil] per-spawn runtime override. When blank,
  #   the spawned root's default_runtime applies. Lets a caller (e.g. a parent
  #   spawning a subagent) run the new session under a different runtime than the
  #   root declares, without changing the root's catalog entry.
  # @param mcp_servers [Array<String>, nil] override MCP servers (uses agent root defaults if nil or blank)
  # @param catalog_skills [Array<String>, nil] override catalog skills (uses agent root defaults if nil)
  # @param catalog_hooks [Array<String>, nil] override catalog hooks (uses agent root defaults if nil)
  # @param catalog_plugins [Array<String>, nil] override catalog plugins (uses agent root defaults if nil)
  # @param goal [String, nil] optional goal
  # @param parent_session_id [Integer, nil] ID of the parent session (used by the dependency graph and forking)
  # @param scheduling_class [String, nil] "spot"/"priority" for this session; nil
  #   derives it from the genesis
  # @param precedence [Integer, nil] where this session sits in the spot queue —
  #   higher is handled sooner, on an absolute scale. nil lands it just above its
  #   parent, or at the default when it has none. See SessionPrecedence.
  # @param metadata [Hash] additional metadata to store on the session
  # @param custom_metadata [Hash] additional custom metadata
  # @return [Session] the created and enqueued session
  def self.create_from_agent_root!(agent_root_name:, prompt:, agent_runtime: nil, mcp_servers: nil, catalog_skills: nil, catalog_hooks: nil, catalog_plugins: nil, goal: nil, parent_session_id: nil, metadata: {}, custom_metadata: {}, images: nil, files: nil, skip_enqueue: false, genesis: nil, scheduling_class: nil, precedence: nil)
    agent_root = AgentRootsConfig.find!(agent_root_name)

    # An explicit override wins over the root's declared runtime; either way the
    # value is normalized through RuntimeRegistry so a blank/absent runtime
    # resolves to the default and an unknown runtime fails loudly at the registry
    # rather than tripping the agent_runtime inclusion validation with a vaguer
    # error. agent_root.default_runtime already folds in the global base default.
    resolved_runtime = RuntimeRegistry.resolve_key(agent_runtime.presence || agent_root.default_runtime)

    # agent_root.default_model folds in the global base default, but a root that
    # explicitly pins a Claude model would carry an invalid model into a Codex
    # spawn (and vice versa). Self-heal to the global base default for the resolved
    # runtime (falling back to that runtime's catalog default) so the persisted
    # model is always valid for the runtime.
    resolved_model = agent_root.default_model
    unless ModelCatalog.valid_model?(resolved_runtime, resolved_model)
      resolved_model = AppSetting.current.resolved_default_model_for(resolved_runtime)
    end

    session = create!(
      prompt: prompt,
      agent_runtime: resolved_runtime,
      git_root: agent_root.url,
      branch: agent_root.default_branch,
      subdirectory: agent_root.subdirectory,
      # On THIS path, nil and [] both inherit the root's defaults, and that is
      # deliberate. Its callers are the dashboard quick prompt, the chat bubble,
      # and Trigger — and a Trigger's mcp_servers column is `default: [], null:
      # false`, so [] is what an untouched trigger stores, not a request for
      # none. Reading it as "no servers" would silently strip every existing
      # trigger's servers.
      #
      # The surfaces where a caller can genuinely say "none" — MCP start_session,
      # POST /api/v1/sessions, the new-session form — build the Session directly
      # and distinguish an omitted list from an explicit [] there, recording the
      # choice via #record_explicit_mcp_servers.
      #
      # agent_root is guaranteed non-nil here (AgentRootsConfig.find! above raises
      # otherwise), so dereferencing its defaults is safe. Sessions created without
      # an agent root use a different path (SessionsController / REST create) and
      # are unaffected.
      #
      # Persisting catalog_plugins from default_plugins is what makes a later full
      # AIR prepare! (run with --without-defaults, which builds its server/skill/
      # hook list ONLY from these columns) reconstruct the plugin-derived MCP
      # servers — those come from default_plugins, NOT default_mcp_servers, so they
      # must be captured here rather than copied into mcp_servers.
      mcp_servers: mcp_servers.presence || agent_root.default_mcp_servers || [],
      catalog_skills: catalog_skills.presence || agent_root.default_skills || [],
      catalog_hooks: catalog_hooks.presence || agent_root.default_hooks || [],
      catalog_plugins: catalog_plugins.presence || agent_root.default_plugins || [],
      goal: goal,
      parent_session_id: parent_session_id,
      # nil leaves the decision to SessionGenesisClassification#assign_genesis,
      # which inherits from `parent_session_id` when one was passed.
      genesis: genesis,
      # nil means nobody chose a spot/priority class for this session, so it
      # derives from the genesis above — see SessionGenesisClassification.
      scheduling_class: scheduling_class,
      # nil means nobody ranked this session, so SessionPrecedence lands it just
      # above the session that spawned it.
      precedence: precedence,
      metadata: metadata.merge("agent_root_key" => agent_root_name),
      custom_metadata: custom_metadata,
      config: { "model" => resolved_model }
    )

    AgentSessionJob.enqueue_new_session(session.id, images: images.presence, files: files.presence) unless skip_enqueue
    session
  end

  # Combined list of explicitly configured, plugin-bundled, and auto-injected
  # MCP servers. This is the effective server set that the runtime should see.
  # Auto-injected servers (e.g. zimmer for subagent roots) are
  # stored in custom_metadata by AgentSessionJob after AIR prepare.
  def all_mcp_servers
    injected = custom_metadata&.dig("injected_mcp_servers") || []
    (user_selected_mcp_servers + injected).uniq
  end

  # MCP servers selected by the user, whether directly or through selected
  # catalog plugins. Excludes auto-injected runtime servers.
  def user_selected_mcp_servers
    ((mcp_servers || []) + plugin_mcp_servers).uniq
  end

  # MCP servers contributed by selected catalog plugins, excluding servers that
  # are already directly selected by the session. This intentionally does NOT
  # exclude auto-injected servers because runtime preparation and failure
  # escalation should still treat a plugin-bundled server as user-selected even
  # if the runtime also injects a server with the same name. Use
  # plugin_derived_mcp_servers when UI attribution needs to hide injected servers.
  def plugin_mcp_servers
    derive_from_plugins(:mcp_servers, exclude: mcp_servers || []).keys
  end

  # Returns ONLY the MCP server names Zimmer auto-injected during session startup —
  # the self-session server, and the subagent-spawning zimmer server
  # for roots that declare default_subagent_roots. It deliberately excludes every
  # user-selected and plugin-bundled server.
  #
  # This is NOT the set of servers the session has wired, and must never be read
  # as one. On a perfectly healthy session it reads `["...-self-session"]` while
  # several user-selected servers are connected, so a narrow value here is not
  # evidence that anything was lost. Callers asking "what does this session
  # actually have?" want #all_mcp_servers. The UI reads this field only to tag
  # which chips were injected rather than chosen.
  def injected_mcp_servers
    custom_metadata&.dig("injected_mcp_servers") || []
  end

  # Drop connection-status entries for MCP servers a user deliberately removed.
  #
  # `custom_metadata["mcp_servers_status"]` records the runtime status of each
  # server the session has configured. It is otherwise append-only, so without
  # this the removed server lingers as a status entry forever — leaving a stale
  # chip in the UI, and making McpServerBackfill#detect_lost_mcp_servers report
  # an intentional removal as an unexplained loss on every later config
  # regeneration. Call this only from user-initiated removal paths; an
  # unexplained disappearance must keep its history so it can be detected.
  def forget_mcp_server_status!(removed_servers)
    return if removed_servers.blank?

    status = (custom_metadata || {})["mcp_servers_status"]
    return if status.blank?

    remaining = status.except(*removed_servers)
    return if remaining == status

    merge_custom_metadata!("mcp_servers_status" => remaining)
  end

  # Record whether a caller that named the mcp_servers list itself asked for zero
  # servers.
  #
  # An empty mcp_servers column is ambiguous on its own. It is what a session
  # lands on when the catalog failed to resolve its root's defaults at create
  # time — the defect McpServerBackfill exists to heal — and it is also what a
  # caller gets when it deliberately asks for none. Healing the second case
  # re-attaches the very servers the caller declined, which for a root whose
  # defaults carry SSH access silently upgrades a least-privilege request.
  #
  # This flag is what tells the two apart, so it must be set by every surface
  # that lets someone name the list: session creation (MCP start_session, the
  # REST API, the new-session form) and the mid-life change paths.
  #
  # @param servers [Array<String>, nil] the list the caller named
  def record_explicit_mcp_servers(servers)
    remaining = (metadata || {}).except(EXPLICIT_EMPTY_MCP_SERVERS_KEY)
    remaining[EXPLICIT_EMPTY_MCP_SERVERS_KEY] = true if Array(servers).empty?
    self.metadata = remaining
  end

  # True when an empty mcp_servers column is a deliberate choice rather than a
  # failed resolve. See #record_explicit_mcp_servers.
  def mcp_servers_explicitly_empty?
    metadata&.dig(EXPLICIT_EMPTY_MCP_SERVERS_KEY) == true
  end

  # Plugin composition: returns a hash of { item_name => contributing_plugin_id }
  # for items contributed by the session's selected plugins. Items already
  # present in the explicit selection (or auto-injected, for MCP servers) are
  # excluded so each item is rendered exactly once. When multiple plugins
  # contribute the same item, the first plugin in catalog_plugins wins.
  def plugin_derived_skills
    derive_from_plugins(:skills, exclude: catalog_skills || [])
  end

  def plugin_derived_hooks
    derive_from_plugins(:hooks, exclude: catalog_hooks || [])
  end

  def plugin_derived_mcp_servers
    derive_from_plugins(:mcp_servers, exclude: (mcp_servers || []) + injected_mcp_servers)
  end

  # Minimum interval between broadcasts triggered by last_timeline_entry_at changes
  BROADCAST_THROTTLE_INTERVAL = 30.seconds

  # Postgres advisory lock namespace for per-session serialization. Different
  # numerical "classes" let us reuse the bigint key space across unrelated
  # subsystems without collisions; we hash with the session_id to produce a
  # unique 64-bit lock id.
  #
  # The two-int form `pg_advisory_xact_lock(int4, int4)` is used so the
  # namespace is explicit at the call site and can be paired with any
  # 32-bit identifier (session_id is an integer column). Both args must
  # fit in signed int4 (max 2,147,483,647), so the namespace is chosen to
  # stay below that ceiling — session.id is also a 4-byte int and will
  # never realistically exceed it.
  SESSION_ADVISORY_LOCK_NAMESPACE = 0x415F_5253 # "A_RS" ASCII — Race-Safe Session advisory lock namespace (value fixed for cross-process lock compatibility)

  # Acquire a transaction-scoped Postgres advisory lock keyed on session_id and
  # yield. All callers entering this block for the same session_id are
  # serialized at the database level — different sessions still run in parallel.
  # The lock is released automatically when the surrounding transaction commits
  # or rolls back (xact = transaction-scoped).
  #
  # Use this around any sequence that mutates session state OR the enqueued
  # message queue and must not interleave with another concurrent request on
  # the same session (interrupt, follow-up, queue claim).
  #
  # @param session_id [Integer] the session to serialize on
  # @yield runs inside an ActiveRecord transaction with the lock held
  # @return whatever the block returns
  def self.with_session_lock(session_id)
    raise ArgumentError, "session_id required" if session_id.nil?

    transaction do
      connection.execute(
        sanitize_sql_array([
          "SELECT pg_advisory_xact_lock(?, ?)",
          SESSION_ADVISORY_LOCK_NAMESPACE,
          session_id.to_i
        ])
      )
      yield
    end
  end

  # Get the next pending enqueued message by position
  # @return [EnqueuedMessage, nil] the next pending message or nil if none exist
  def next_enqueued_message
    enqueued_messages.pending.ordered.first
  end

  # Process the next enqueued message atomically
  # Prevents race conditions where multiple workers could grab the same message.
  #
  # Uses SELECT FOR UPDATE SKIP LOCKED for optimal performance.
  # SKIP LOCKED ensures workers skip already-locked rows rather than waiting.
  #
  # This method must be called within a transaction for proper locking behavior.
  # If called outside a transaction, the lock is released immediately after the query.
  #
  # @return [EnqueuedMessage, nil] the message being processed or nil if none exist
  def process_next_enqueued_message!
    # Use FOR UPDATE SKIP LOCKED to atomically claim a message
    # SKIP LOCKED ensures that if another worker already has a message locked,
    # we'll skip it rather than waiting (which could cause deadlocks)
    message = enqueued_messages
      .pending
      .order(position: :asc)
      .lock("FOR UPDATE SKIP LOCKED")
      .first

    return nil unless message

    message.update!(status: "processing")
    message
  end

  private

  # Reclaim the on-disk state a destroyed session owned: its durable scratch
  # directory and its two prompt-attachment directories. See the callback
  # declaration above for why this runs after commit rather than before destroy.
  #
  # Best-effort by construction — each cleanup_for already swallows and logs its
  # own errors — and wrapped again here so that an unreadable volume cannot turn
  # a completed delete into an exception raised after the row is already gone.
  #
  # The same three roots are what DurableSessionStorage reaps for the jobs. That
  # concern confirms each deletion so a job can write an honest per-session log
  # line; here the row (and its logs) are already gone, so there is nothing left
  # to tell, and the direct calls are the whole of it.
  def reclaim_session_directories
    SessionScratchDirectory.cleanup_for(id)
    FileStorageService.cleanup_for(id)
    ImageStorageService.cleanup_for(id)
  rescue => e
    Rails.logger.warn "[Session] Failed to reclaim directories for deleted session #{id}: #{e.class} - #{e.message}"
  end

  # Whether a rejected write is another session having claimed the slug we were
  # about to take. The race has two shapes: the winner commits after the
  # uniqueness validator's read (the index rejects us, as RecordNotUnique) or
  # before it (the validator rejects us, as RecordInvalid). Anything else —
  # another unique index, an unrelated validation — is not ours to retry.
  #
  # @param error [ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid]
  # @return [Boolean]
  def slug_collision?(error)
    case error
    when ActiveRecord::RecordInvalid then error.record.errors.of_kind?(:slug, :taken)
    when ActiveRecord::RecordNotUnique then error.message.include?(SLUG_UNIQUE_INDEX)
    else false
    end
  end

  # The runtime transcript source, used to parse the stored transcript into raw
  # event hashes. Parsing is pure (no IO), so the default file_system is fine.
  def transcript_source
    @transcript_source ||= TranscriptRuntime.source_for(self)
  end

  def parse_metadata_timestamp(value)
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
    Time.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  # Resolve the session's catalog_plugins into Plugin objects, dropping any IDs
  # that are no longer in the catalog. Order matches catalog_plugins so that the
  # first plugin to contribute a given item is recorded as the source.
  def selected_plugins
    return [] if catalog_plugins.blank?

    catalog_plugins.filter_map { |id| PluginsConfig.find(id) }
  end

  # Walk the selected plugins and collect items from the named attribute,
  # excluding any items already present in `exclude` (so directly-selected items
  # don't appear twice). Returns { item_name => first_contributing_plugin_id }.
  def derive_from_plugins(attribute, exclude:)
    return {} if catalog_plugins.blank?

    excluded = exclude.to_set
    selected_plugins.each_with_object({}) do |plugin, acc|
      plugin.public_send(attribute).each do |item|
        next if excluded.include?(item)
        acc[item] ||= plugin.id
      end
    end
  end

  # Track status changes during save to support reliable broadcasting in transactions.
  # This is called before_save and sets an instance variable if the status is changing.
  # The variable accumulates across multiple saves in a transaction using ||= to ensure
  # we don't lose track of a status change even if subsequent saves don't change status.
  def track_status_change_for_broadcast
    @status_changed_in_transaction ||= status_changed?
  end

  # Check if status changed at any point during this transaction.
  # Called by after_update_commit to determine if we should broadcast.
  # Also clears the tracking flag after checking so it doesn't persist to future transactions.
  def status_changed_in_transaction?
    changed = @status_changed_in_transaction
    @status_changed_in_transaction = nil
    changed
  end

  # Determine if we should broadcast updates to the sessions index
  # Only broadcast when attributes visible in the session card change
  def should_broadcast_to_index?
    # A fork the index never lists has nothing to update there.
    return false if status_summary_fork?

    # Check if any of the attributes displayed in the session card changed
    return true if saved_change_to_status? ||
      saved_change_to_title? ||
      saved_change_to_slug? ||
      saved_change_to_git_root? ||
      saved_change_to_prompt? ||
      saved_change_to_mcp_servers? ||
      saved_change_to_catalog_skills? ||
      saved_change_to_catalog_hooks? ||
      saved_change_to_catalog_plugins? ||
      saved_change_to_metadata? ||
      saved_change_to_custom_metadata? ||
      saved_change_to_favorited? ||
      saved_change_to_is_autonomous? ||
      (saved_change_to_session_notes? && (session_notes_previously_was.blank? != session_notes.blank?))

    # For last_timeline_entry_at changes, throttle broadcasts to avoid overwhelming the index page
    # Only broadcast if >=30 seconds since last broadcast
    if saved_change_to_last_timeline_entry_at?
      return last_broadcast_to_index_at.nil? || last_broadcast_to_index_at <= BROADCAST_THROTTLE_INTERVAL.ago
    end

    false
  end

  def mcp_servers_must_be_array
    return if mcp_servers.nil? || mcp_servers.is_a?(Array)

    errors.add(:mcp_servers, "must be an array")
  end

  def mcp_servers_must_exist_in_catalog
    return if mcp_servers.nil? || !mcp_servers.is_a?(Array)

    # Filter out blank entries (Rails params can send [""] for empty arrays)
    non_blank_servers = mcp_servers.reject(&:blank?)
    invalid_servers = non_blank_servers.reject { |name| ServersConfig.exists?(name) }
    return if invalid_servers.empty?

    errors.add(:mcp_servers, "contains invalid server(s): #{invalid_servers.join(', ')}")
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

  def parent_session_must_exist
    return if parent_session_id.blank?
    return if Session.exists?(id: parent_session_id)

    errors.add(:parent_session_id, "must reference an existing session")
  end

  def git_root_format
    return unless git_root.present?

    # Check for SSH URL format (e.g., git@github.com:user/repo or git@github.com:user/repo.git)
    # SSH URL pattern: git@hostname:path/to/repo or git@hostname:path/to/repo.git
    # Allow alphanumeric, hyphens, underscores, dots in hostname and path
    # Make .git extension optional with (?:\.git)?
    ssh_pattern = /\A[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+:[a-zA-Z0-9._\/-]+(?:\.git)?\z/
    return if git_root.match?(ssh_pattern)

    # Check for HTTP/HTTPS URLs or local paths
    uri = URI.parse(git_root)

    # Accept HTTP/HTTPS URLs
    return if uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    # Accept absolute local paths (start with /)
    return if git_root.start_with?("/")

    # Reject anything that looks like it has an @ symbol (malformed SSH URL)
    if git_root.include?("@")
      errors.add(:git_root, "must be a valid URL or git path")
      return
    end

    # Accept other generic URIs (relative paths, etc.)
    errors.add(:git_root, "must be a valid URL or git path") unless uri.is_a?(URI::Generic)
  rescue URI::InvalidURIError
    errors.add(:git_root, "must be a valid URL or git path")
  end


  def set_default_title
    # Only set default title if no title was provided
    return if title.present?

    # Set default title to "Session {id}" after creation
    # Store a flag in metadata to indicate this is an auto-generated title
    # so the background job can update it later
    update_columns(
      title: "Session #{id}",
      metadata: (metadata || {}).merge("auto_generated_title" => true)
    )
  end

  # SessionTitleJob both names the session and auto-sorts it into a category,
  # from a single inference over the early transcript. Enqueue it when there is
  # a prompt (skip clone-only sessions) and either piece of work is pending:
  # the title is still the auto-generated placeholder, or the session is
  # uncategorized and there are non-frozen categories to sort into. The
  # 2-minute delay lets a few minutes of conversation accumulate so the
  # inference works off what the agent actually did, not just the raw prompt.
  # (A pause/fail transition also enqueues it promptly once a transcript exists
  # — see SessionStateMachine#enqueue_session_inference_if_needed.)
  def enqueue_session_inference
    return if prompt.blank?

    title_pending = metadata&.dig("auto_generated_title") == true
    category_pending = category_id.blank? && Category.where(is_frozen: false).exists?
    return unless title_pending || category_pending

    SessionTitleJob.set(wait: 2.minutes).perform_later(id)
  end

  def broadcast_update_to_sessions_index
    # If session is now archived, remove it from the index instead of updating it.
    # The /sessions page filters out archived sessions by default, so broadcasting
    # a REPLACE would incorrectly show the archived session.
    if archived?
      broadcast_remove_from_sessions_index
      return
    end

    # Replace the session's card in place (wherever it currently lives in the grid,
    # regardless of which category section it has been dragged into).
    broadcast_individual_card_to_sessions_index(:replace)

    # Record broadcast time for throttling (only for last_timeline_entry_at changes)
    # Use update_column to avoid triggering callbacks
    update_column(:last_broadcast_to_index_at, Time.current) if saved_change_to_last_timeline_entry_at?
  end

  def broadcast_create_to_sessions_index
    # New sessions are uncategorized by default, so they prepend into the
    # "Uncategorized" grid (target "sessions_grid").
    broadcast_individual_card_to_sessions_index(:prepend)
  end

  def broadcast_remove_from_sessions_index
    broadcast_remove_to("sessions_index_individual", target: dom_id(self))
  end

  # Renders this session as an individual card and broadcasts to the individual-view channel.
  # Supports :replace (for updates) and :prepend (for new sessions).
  def broadcast_individual_card_to_sessions_index(action)
    rendered_html = render_index_card_html
    if action == :prepend
      broadcast_prepend_to(
        "sessions_index_individual",
        target: "sessions_grid",
        html: rendered_html
      )
    else
      broadcast_replace_to(
        "sessions_index_individual",
        target: dom_id(self),
        html: rendered_html
      )
    end
  end

  # Renders this session as an individual card wrapped in a turbo frame.
  # Used by individual-view broadcasts.
  def render_index_card_html
    SessionsController.render(
      inline: "<%= turbo_frame_tag dom_id(agent_session) do %><%= render 'sessions/session_card', agent_session: agent_session %><% end %>",
      locals: { agent_session: self }
    )
  end

  def broadcast_status_change
    # Broadcast each component independently with individual error handling.
    # This ensures that if one broadcast fails (e.g., due to rendering error),
    # the remaining broadcasts still execute.
    broadcast_status_badge
    broadcast_follow_up_form
    broadcast_running_loader
    broadcast_header_actions
    # Also broadcast metadata - it may contain status-dependent UI elements
    # (e.g., OAuth authorization buttons only shown when status is failed)
    broadcast_metadata_change
  end

  def broadcast_status_badge
    broadcast_replace_to(
      "session_#{id}_status",
      target: "session_#{id}_status_badge",
      partial: "sessions/status_badge",
      locals: { agent_session: self }
    )
  rescue => e
    Rails.logger.error "[Session] Broadcast status badge failed for session #{id}: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: id, broadcast: "status_badge" })
  end

  def broadcast_follow_up_form
    # Use SessionsController.render to ensure route helpers (follow_up_session_path) are available
    # This is necessary because this callback can be triggered from background jobs
    # Pre-fetch session skills to avoid cache hit in view
    session_skills = ClaudeSkillsCacheService.get_for_session(self)
    follow_up_html = SessionsController.render(
      partial: "sessions/follow_up_form",
      locals: { agent_session: self, session_skills: session_skills }
    )
    broadcast_replace_to(
      "session_#{id}_status",
      target: "session_#{id}_follow_up_form",
      html: follow_up_html
    )
  rescue => e
    Rails.logger.error "[Session] Broadcast follow-up form failed for session #{id}: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: id, broadcast: "follow_up_form" })
  end

  def broadcast_running_loader
    broadcast_replace_to(
      "session_#{id}_status",
      target: "session_#{id}_running_loader",
      partial: "sessions/running_loader",
      locals: { agent_session: self }
    )
  rescue => e
    Rails.logger.error "[Session] Broadcast running loader failed for session #{id}: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: id, broadcast: "running_loader" })
  end

  def broadcast_header_actions
    # Use SessionsController.render to ensure route helpers are available
    header_actions_html = SessionsController.render(
      partial: "sessions/session_header_actions",
      locals: { agent_session: self }
    )
    broadcast_replace_to(
      "session_#{id}_status",
      target: "session_#{id}_header_actions",
      html: header_actions_html
    )
  rescue => e
    Rails.logger.error "[Session] Broadcast header actions failed for session #{id}: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: id, broadcast: "header_actions" })
  end

  # Check if metadata fields displayed on the detail page have changed
  # Broadcasts when clone_path is set or failure_reason/exit_status/exception_class change
  def should_broadcast_metadata_change?
    return false unless saved_change_to_metadata?

    metadata_display_fields_changed?(*saved_change_to_metadata)
  end

  # Same question, asked with an explicit before/after pair. AtomicJsonMetadata writes
  # the column with a raw UPDATE, so it has no `saved_change_to_metadata` to consult and
  # calls this directly.
  def metadata_display_fields_changed?(old_metadata, new_metadata)
    METADATA_DISPLAY_FIELDS.any? do |field|
      old_metadata&.dig(field) != new_metadata&.dig(field)
    end
  end

  def broadcast_metadata_change
    # Broadcast metadata update to session detail page
    # Use SessionsController.render to ensure route helpers are available
    # Pass select data as locals so the partial renders edit affordances
    # (without these, the edit buttons disappear because the partial checks for them)
    metadata_html = SessionsController.render(
      partial: "sessions/session_metadata",
      locals: metadata_broadcast_locals
    )
    broadcast_replace_to(
      "session_#{id}_status",
      target: "session_#{id}_metadata",
      html: metadata_html
    )
  rescue => e
    # Log broadcast errors but don't let them fail the parent operation
    Rails.logger.error "[Session] Broadcast metadata change failed for session #{id}: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: id, broadcast: "metadata_change" })
  end

  # `mcp_status_changed` defaults to the dirty-tracking answer for the callback path;
  # AtomicJsonMetadata passes it explicitly because a raw UPDATE leaves no dirty state.
  def broadcast_custom_metadata_change(mcp_status_changed: custom_metadata_mcp_status_changed?)
    # Broadcast header actions update to session detail page
    # This includes the GitHub PR link button which depends on custom_metadata
    # Use SessionsController.render to ensure route helpers are available
    header_actions_html = SessionsController.render(
      partial: "sessions/session_header_actions",
      locals: { agent_session: self }
    )
    broadcast_replace_to(
      "session_#{id}_status",
      target: "session_#{id}_header_actions",
      html: header_actions_html
    )

    # Also broadcast metadata partial if MCP status changed
    # This updates the MCP server status indicators in real-time
    if mcp_status_changed
      metadata_html = SessionsController.render(
        partial: "sessions/session_metadata",
        locals: metadata_broadcast_locals
      )
      broadcast_replace_to(
        "session_#{id}_status",
        target: "session_#{id}_metadata",
        html: metadata_html
      )
    end
  rescue => e
    # Log broadcast errors but don't let them fail the parent operation
    Rails.logger.error "[Session] Broadcast custom metadata change failed for session #{id}: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: id, broadcast: "custom_metadata_change" })
  end

  def broadcast_provenance_change_to_hierarchy
    SessionHierarchy.new(self).session_ids.each do |viewer_id|
      viewer = Session.find_by(id: viewer_id)
      next unless viewer

      html = SessionsController.render(
        partial: "sessions/session_hierarchy",
        locals: { agent_session: viewer }
      )

      Turbo::StreamsChannel.broadcast_replace_to(
        "session_#{viewer.id}_status",
        target: "session_#{viewer.id}_provenance",
        html: html
      )
    end
  rescue => e
    Rails.logger.error "[Session] Broadcast provenance change failed for session #{id}: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: id, broadcast: "provenance_change" })
  end
  public :broadcast_provenance_change_to_hierarchy

  # Build locals hash for metadata partial broadcasts.
  # Includes the select data that the partial needs to render edit buttons.
  # Without these, broadcast-rendered HTML omits edit affordances because
  # the partial conditionally renders them based on these values.
  def metadata_broadcast_locals
    {
      agent_session: self,
      servers_for_select: ServersConfig.all.map { |s| { name: s.name, title: s.title, description: s.description } },
      catalog_skills_for_select: SkillsConfig.all.map { |s| { id: s.id, name: s.name, title: s.title, description: s.description, category: s.category } },
      catalog_hooks_for_select: HooksConfig.all.map { |h| { id: h.id, name: h.name, title: h.title, description: h.description } },
      plugins_for_select: PluginsConfig.all.map { |p| { id: p.id, title: p.title, description: p.description } },
      available_models: ModelCatalog.model_ids_for(agent_runtime),
      goals_for_select: GoalsConfig.all.map { |g| { id: g.id, name: g.name, description: g.description } }
    }
  end

  def custom_metadata_mcp_status_changed?
    return false unless saved_change_to_custom_metadata?

    old_metadata, new_metadata = saved_change_to_custom_metadata
    old_mcp_status = old_metadata&.dig("mcp_servers_status")
    new_mcp_status = new_metadata&.dig("mcp_servers_status")

    old_mcp_status != new_mcp_status
  end
end

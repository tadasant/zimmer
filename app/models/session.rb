class Session < ApplicationRecord
  include ActionView::RecordIdentifier
  include SessionStateMachine

  has_many :logs, dependent: :destroy
  has_many :subagent_transcripts, dependent: :destroy
  has_many :enqueued_messages, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :mcp_oauth_pending_flows, dependent: :destroy
  has_many :elicitations, dependent: :destroy

  belongs_to :parent_session, class_name: "Session", optional: true
  has_many :child_sessions, class_name: "Session", foreign_key: :parent_session_id, dependent: :nullify

  # Organizational category for the sessions dashboard. A NULL category means the
  # session is "Uncategorized". Assigned via drag-and-drop on the index grid.
  belongs_to :category, optional: true

  # Manual "blocked by" relationship: a session can be marked as blocked by another
  # session (the blocker). A blocked session is hidden from the default index until
  # its blocker is trashed (archived). The relationship is purely manual — there is
  # no automatic dependency detection.
  belongs_to :blocked_by_session, class_name: "Session", optional: true
  has_many :blocked_sessions, class_name: "Session", foreign_key: :blocked_by_session_id, dependent: :nullify

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

  # A session is "effectively blocked" when it has a blocker AND that blocker is not
  # yet archived (trashed). Once the blocker is archived, the session is no longer
  # effectively blocked and reappears in the default index.
  scope :effectively_blocked, -> {
    joins("INNER JOIN sessions blockers ON blockers.id = sessions.blocked_by_session_id")
      .where.not(blockers: { status: statuses[:archived] })
  }
  scope :not_effectively_blocked, -> {
    where(blocked_by_session_id: nil)
      .or(where("blocked_by_session_id IN (SELECT id FROM sessions WHERE status = ?)", statuses[:archived]))
  }

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
  after_update_commit :broadcast_update_to_sessions_index, if: :should_broadcast_to_index?
  after_create_commit :broadcast_create_to_sessions_index
  after_destroy_commit :broadcast_remove_from_sessions_index

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

  # Metadata keys that should be cleared when restarting or resuming a session.
  # These track retry state and transcript polling state from previous execution
  # lifecycles and would cause false failures or silent transcripts if preserved
  # across restarts.
  #
  # NOTE: api_error_last_checked_line is intentionally NOT included here.
  # It tracks the transcript scan position (which errors have already been handled)
  # and must be preserved across restarts. Clearing it causes the scanner to
  # re-process old errors, which can misclassify new transient rate limits as
  # quota limits when an old quota entry is encountered first.
  # The retry COUNTS (api_error_retry_count, last_api_error_retry_at) are cleared
  # to give fresh retry budget, but the scan position is preserved.
  #
  # The same split applies to auth recovery: auth_recovery_count / last_auth_recovery_at
  # ARE cleared (fresh budget on resume) but auth_error_last_checked_line is NOT —
  # it is the AuthRecoveryService scan position and must survive restarts so an
  # already-handled "Not logged in" entry isn't re-detected.
  STALE_RETRY_METADATA_KEYS = %w[
    sigterm_retry_count
    sigterm_retry_timestamps
    last_sigterm_at
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
    quota_limit_count
    last_quota_limit_at
    last_quota_limit_message
    auth_recovery_count
    last_auth_recovery_at
    mcp_retry_count
    mcp_last_retry_at
    broadcast_message_count
    transcript_waiting_logged
    transcript_files_waiting_logged
    transcript_reading_started_logged
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

  # The agent root used for routing freeform user requests from the dashboard
  ROUTER_AGENT_ROOT = "zimmer-router"

  # Execution providers
  EXECUTION_PROVIDERS = %w[local_filesystem remote_sandbox].freeze

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

  after_create :set_default_title
  after_create_commit :enqueue_session_inference

  # The bundle of pluggable implementations for this session's agent runtime
  # (CLI adapter, retry strategy, transcript source/normalizer, prompt
  # contribution, ...). Resolved from RuntimeRegistry by agent_runtime. Callers
  # read the class slot they need and instantiate with their own dependencies.
  def runtime
    RuntimeRegistry.for(agent_runtime)
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

  # Check if the session was recently recovered by the cleanup job
  # Used to trigger auto-refresh of the page to re-establish Turbo Stream connections
  #
  # Uses a 5-second window to ensure only one auto-refresh occurs. The meta refresh
  # takes 3 seconds, so by using 5 seconds we avoid multiple refreshes while still
  # catching the initial page load after recovery.
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
    update!(
      metadata: (metadata || {}).merge("last_user_activity_at" => Time.current.iso8601)
    )
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

    # Ensure uniqueness
    final_slug = base_slug
    counter = 1
    while Session.exists?(slug: final_slug)
      final_slug = "#{base_slug}-#{counter}"
      counter += 1
    end

    update!(slug: final_slug)
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
  # @param preserve_empty_mcp_servers [Boolean] when true, an explicit empty mcp_servers array overrides root defaults
  # @param catalog_skills [Array<String>, nil] override catalog skills (uses agent root defaults if nil)
  # @param catalog_hooks [Array<String>, nil] override catalog hooks (uses agent root defaults if nil)
  # @param catalog_plugins [Array<String>, nil] override catalog plugins (uses agent root defaults if nil)
  # @param goal [String, nil] optional goal
  # @param parent_session_id [Integer, nil] ID of the parent session (used by the dependency graph and forking)
  # @param metadata [Hash] additional metadata to store on the session
  # @param custom_metadata [Hash] additional custom metadata
  # @return [Session] the created and enqueued session
  def self.create_from_agent_root!(agent_root_name:, prompt:, agent_runtime: nil, mcp_servers: nil, catalog_skills: nil, catalog_hooks: nil, catalog_plugins: nil, goal: nil, parent_session_id: nil, metadata: {}, custom_metadata: {}, images: nil, files: nil, skip_enqueue: false, preserve_empty_mcp_servers: false)
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
      # Keep historical agent-root behavior: nil or [] inherits root defaults.
      # Callers that need "explicitly no MCP servers" can opt into preserving [].
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
      mcp_servers: if preserve_empty_mcp_servers && mcp_servers == []
                     []
                   else
                     mcp_servers.presence || agent_root.default_mcp_servers || []
                   end,
      catalog_skills: catalog_skills.presence || agent_root.default_skills || [],
      catalog_hooks: catalog_hooks.presence || agent_root.default_hooks || [],
      catalog_plugins: catalog_plugins.presence || agent_root.default_plugins || [],
      goal: goal,
      parent_session_id: parent_session_id,
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

    update!(custom_metadata: (custom_metadata || {}).merge("mcp_servers_status" => remaining))
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

  # True when this session is marked as blocked by another session whose blocker is
  # not yet archived (trashed). Such sessions are hidden from the default index.
  def effectively_blocked?
    blocked_by_session_id.present? && blocked_by_session.present? && !blocked_by_session.archived?
  end

  private

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
      saved_change_to_blocked_by_session_id? ||
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

    # If session is now effectively blocked, remove it from the default index just like
    # archived sessions. The /sessions page hides blocked sessions by default, so a
    # REPLACE would incorrectly keep showing it. Viewers with "Show Blocked" active will
    # see it again on reload (consistent with how the trash filter behaves).
    if effectively_blocked?
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

    old_metadata, new_metadata = saved_change_to_metadata

    # Fields that are displayed in the session metadata partial
    display_fields = %w[clone_path full_clone_path failure_reason exit_status exception_class]

    display_fields.any? do |field|
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

  def broadcast_custom_metadata_change
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
    if custom_metadata_mcp_status_changed?
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

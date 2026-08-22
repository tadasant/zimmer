# frozen_string_literal: true

# Represents a single condition that can fire a trigger.
# A Trigger (trigger flow) can have multiple conditions with OR semantics —
# if ANY condition fires, the trigger's session template executes.
#
# Condition types:
# - "slack": Fires when a new message is posted in a Slack channel. `event_type`
#     picks the flavour: "new_message" (everything in one channel), "bot_mention"
#     (@mentions + DMs), "dm_message" (DMs only — the DM half of bot_mention,
#     without the channel half), "passive_listen_thread" (replies in threads Zimmer
#     has participated in), or "passive_listen_channel" (top-level messages in
#     channels Zimmer posted in recently). The passive pair are separate conditions
#     on purpose: a Trigger ORs its conditions, so carrying both is how you get
#     "either".
# - "schedule": Fires on a time-based schedule (recurring or one-time)
#     Recurring: { "unit" => "hours", "interval" => 2, "timezone" => "UTC" }
#     One-time:  { "scheduled_at" => "2026-04-15T14:30:00", "timezone" => "America/New_York" }
# - "ao_event": Fires on internal Zimmer events (e.g., session transitions to needs_input)
# - "github_label": Fires when a watched label is ADDED to a PR/issue in a watched repo
#     { "repos" => ["owner/a"], "target" => "pull_request", "labels" => ["ready to merge"] }
# - "github_issue": Fires when a new issue is opened in a watched repo, unless the issue
#     carries one of the excluded labels — the opt-out an author sets at creation time.
#     { "repos" => ["owner/a"], "exclude_labels" => ["hold issue work gate"] }
#
# Both GitHub types are polled by GithubTriggerPollerJob, which owns the runtime keys
# it stores back into `configuration` (GITHUB_POLL_STATE_KEYS). See that job for the
# state-to-event semantics those keys implement.
class TriggerCondition < ApplicationRecord
  CONDITION_TYPES = %w[slack schedule ao_event github_label github_issue system_event].freeze

  # The passive-listening event types, in the order the UI offers them.
  #
  # "passive_listen" is the deprecated original, which fires on BOTH signals at
  # once. It is kept working so a deploy of the split can't strand a trigger that
  # still names it; new conditions should carry the two halves separately, which is
  # what lets a Trigger enable one without the other.
  PASSIVE_EVENT_TYPES = %w[passive_listen_thread passive_listen_channel passive_listen].freeze

  # Delete once no condition names a deprecated type — the check and the removal
  # steps are in https://github.com/tadasant/zimmer/issues/253.
  DEPRECATED_EVENT_TYPES = %w[passive_listen].freeze

  EVENT_TYPES = (%w[new_message bot_mention dm_message] + PASSIVE_EVENT_TYPES).freeze

  # Slack event types that monitor many sources rather than one channel, so
  # channel_id is optional for them and their cursors live per-source inside
  # `configuration` instead of in last_message_ts.
  #
  # `dm_message` qualifies for the same reason `bot_mention` does: it fans out
  # across one DM conversation per allowed user, each with its own entry in
  # `dm_timestamps`. There is no single "newest message" for the health check to
  # measure staleness against, and a thread_ts would have nothing to scope.
  ALL_CHANNEL_EVENT_TYPES = (%w[bot_mention dm_message] + PASSIVE_EVENT_TYPES).freeze
  SCHEDULE_UNITS = %w[minutes hours days weeks].freeze
  DAYS_OF_WEEK = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
  AO_EVENT_NAMES = %w[session_needs_input session_failed session_archived].freeze

  # Fleet-wide state transitions, as opposed to one session's. An `ao_event`
  # condition watches a SESSION changing state; a `system_event` condition watches
  # the deployment itself change, so it carries no session at all — which is
  # exactly why it needs its own type rather than a fourth AO_EVENT_NAME.
  #
  # `quota_available` fires on the edge where the account pool goes from having
  # nothing that can serve a request to having something: quota-full to
  # quota-available. It is an edge, not a level, so it fires once per recovery
  # rather than every time the pool is measured while healthy. See
  # QuotaAvailabilityMonitor.
  SYSTEM_EVENT_NAMES = %w[quota_available].freeze

  GITHUB_CONDITION_TYPES = %w[github_label github_issue].freeze
  GITHUB_TARGETS = %w[pull_request issue].freeze
  GITHUB_REPO_FORMAT = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

  # Bounds the length of the single search query the poller builds for a condition.
  # 20 repos is a ~750-character query, which GitHub accepts comfortably.
  MAX_GITHUB_REPOS = 20

  # Keys inside `configuration` that belong to the poller, not the user. They are
  # never rendered as form fields, so a UI edit submits a configuration hash without
  # them — see #preserve_github_poll_state for why they are merged back in.
  GITHUB_POLL_STATE_KEYS = %w[seen_items seen_missing_counts last_issue_at seen_issue_keys].freeze

  # The same problem on the Slack side, and worse: these keys are every cursor the
  # Slack poller owns, so a plain "save" in the UI — which submits only the rendered
  # fields — would reset a live condition to un-baselined. For a passive-listening
  # condition that means losing which threads Zimmer is in and re-backfilling up to
  # THREAD_BACKFILL_HORIZON of replies on the next poll.
  #
  # allowed_user_ids rides along for a different reason: it is user-facing but the
  # form does not render it, so without this a UI save would silently widen a
  # condition's allow-list back to the deployment default (which may be EVERYONE).
  # Preserving is keyed on ABSENCE, so an API caller can still clear it by sending
  # an explicit empty array.
  SLACK_POLL_STATE_KEYS = %w[
    channel_timestamps thread_timestamps bot_activity_timestamps
    participating_threads dm_timestamps allowed_user_ids
  ].freeze

  belongs_to :trigger

  validates :condition_type, presence: true, inclusion: { in: CONDITION_TYPES }
  validates :configuration, presence: true
  validate :validate_configuration_for_type

  before_validation :normalize_github_configuration, if: :github_condition?
  before_validation :preserve_github_poll_state, if: :github_condition?
  before_validation :preserve_slack_poll_state, if: -> { condition_type == "slack" }

  scope :slack, -> { where(condition_type: "slack") }
  scope :schedule, -> { where(condition_type: "schedule") }
  scope :ao_event, -> { where(condition_type: "ao_event") }
  scope :github, -> { where(condition_type: GITHUB_CONDITION_TYPES) }

  # Slack configuration accessors
  def channel_id
    configuration["channel_id"]
  end

  def channel_name
    configuration["channel_name"]
  end

  def event_type
    configuration["event_type"] || "new_message"
  end

  # Optional thread timestamp for new_message conditions. When present, the
  # condition monitors new REPLIES in this specific thread instead of new
  # top-level messages in the channel. This is required for channels whose
  # meaningful posts arrive as thread replies (e.g. a daily digest thread) —
  # plain conversations.history polling never surfaces thread replies, so a
  # top-level new_message condition can never fire on them.
  def thread_ts
    configuration["thread_ts"].presence
  end

  # True when this is a Slack condition scoped to a specific thread's replies.
  def thread_scoped?
    condition_type == "slack" && thread_ts.present?
  end

  # True when this is a Slack condition that listens passively — firing with no
  # @mention required on messages that continue a conversation Zimmer is already
  # part of. See SlackTriggerPollerJob#process_passive_listen_condition.
  def passive_listen?
    condition_type == "slack" && PASSIVE_EVENT_TYPES.include?(event_type)
  end

  # True when this condition follows threads Zimmer has participated in. No time
  # limit applies: a reply to a thread you are in is addressed to that conversation
  # whenever it lands.
  def passive_threads?
    passive_listen? && event_type != "passive_listen_channel"
  end

  # True when this condition follows top-level messages in channels Zimmer posted
  # in recently — "recently" being SlackTriggerPollerJob::CHANNEL_ENGAGEMENT_WINDOW.
  def passive_channel?
    passive_listen? && event_type != "passive_listen_thread"
  end

  # True when this condition names an event type kept only for compatibility.
  def deprecated_event_type?
    condition_type == "slack" && DEPRECATED_EVENT_TYPES.include?(event_type)
  end

  # The deployment-wide allow-list for bot_mention and passive-listening conditions: a comma-separated
  # list of Slack user IDs in SLACK_BOT_MENTION_ALLOWED_USER_IDS, resolved from
  # encrypted credentials first and process ENV second (the same order
  # SlackService#slack_bot_token and AlertService#channel_id use).
  #
  # Blank or unset means EVERYONE, not nobody. An unconfigured Zimmer lets any
  # workspace member @mention or DM the bot; a deployment narrows it by setting
  # this. The bound on "everyone" is that the bot only ever sees channels it has
  # been invited to, and DMs people choose to open with it.
  def self.default_allowed_user_ids
    raw = SecretsLoader.get("SLACK_BOT_MENTION_ALLOWED_USER_IDS") ||
      ENV["SLACK_BOT_MENTION_ALLOWED_USER_IDS"]

    raw.to_s.split(",").filter_map { |id| id.strip.presence }
  end

  # Allowed user IDs for bot_mention and passive_listen conditions: this condition's own explicit
  # list if it has one (set from the UI/API), else the deployment-wide default.
  # Empty means unrestricted -- ask allow_all_users? rather than reading this as
  # "nobody", and see the DM caveat there.
  # Memoized: the poller asks this once per message and once per thread reply, and
  # SecretsLoader deliberately does not memoize (it re-reads credentials on every
  # call so a deploy's new secrets are picked up mid-process). A condition object
  # lives for one poll, so caching here is safe and saves that work per message.
  def allowed_user_ids
    @allowed_user_ids ||= begin
      ids = configuration["allowed_user_ids"]
      ids.present? ? Array(ids) : self.class.default_allowed_user_ids
    end
  end

  # True when no allow-list applies, i.e. every workspace member may trigger.
  #
  # Callers MUST branch on this rather than passing allowed_user_ids around: the
  # DM path enumerates the allow-list (SlackService.list_dm_channels filters
  # conversations.list down to DMs with those users), and "everyone" cannot be
  # expressed as a list of IDs. Treating the empty list as a filter silently means
  # "nobody" and DMs stop working.
  def allow_all_users?
    allowed_user_ids.empty?
  end

  # Whether a Slack user may fire this condition.
  def user_allowed?(user_id)
    return false if user_id.blank?

    allow_all_users? || allowed_user_ids.include?(user_id)
  end

  # Get the per-user DM timestamps for bot_mention conditions.
  # Returns a hash of user_id => last_message_ts
  def dm_timestamps
    configuration["dm_timestamps"] || {}
  end

  # Update DM timestamp for a specific user
  def update_dm_timestamp!(user_id, ts)
    new_config = configuration.merge("dm_timestamps" => dm_timestamps.merge(user_id => ts))
    update!(configuration: new_config)
  end

  # Get the per-channel timestamps for bot_mention / passive_listen conditions
  # (all-channel monitoring).
  # Returns a hash of channel_id => last_message_ts
  def channel_timestamps
    configuration["channel_timestamps"] || {}
  end

  # Update channel timestamp for a specific channel
  def update_channel_timestamp!(channel_id, ts)
    new_config = configuration.merge("channel_timestamps" => channel_timestamps.merge(channel_id => ts))
    update!(configuration: new_config)
  end

  # Get per-thread "last reply checked" timestamps for bot_mention / passive_listen
  # conditions.
  # Returns a hash of "channel_id:thread_ts" => last_reply_ts
  def thread_timestamps
    configuration["thread_timestamps"] || {}
  end

  # Get per-channel "when did Zimmer last speak here" timestamps for passive_listen
  # conditions. Returns a hash of channel_id => ts.
  #
  # This is the channel-engagement signal, and it is a cursor like the two above
  # rather than a second source of truth: the poller learns Zimmer's activity from
  # the channel history it already fetches — its own TOP-LEVEL posts, only — and
  # remembers the newest it has seen, so a channel stays "engaged" for the whole
  # window even once that post scrolls out of the history slice. See
  # SlackTriggerPollerJob::CHANNEL_ENGAGEMENT_WINDOW.
  def bot_activity_timestamps
    configuration["bot_activity_timestamps"] || {}
  end

  # Thread keys ("channel_id:thread_ts") Zimmer has been seen speaking in, for
  # passive_listen conditions.
  #
  # Participation is permanent — a thread you have joined stays yours — so it is
  # remembered rather than re-derived. Without this the poller would have to re-read
  # a thread's entire history on every tick to answer the same question, which for a
  # long-lived thread is several paginated API calls a minute for as long as it
  # stays tracked.
  def participating_threads
    Array(configuration["participating_threads"])
  end

  # Schedule configuration accessors
  def scheduled_at
    configuration["scheduled_at"]
  end

  def one_time_schedule?
    condition_type == "schedule" && scheduled_at.present?
  end

  def schedule_interval
    (configuration["interval"] || 1).to_i
  end

  def schedule_unit
    configuration["unit"]
  end

  def schedule_time
    configuration["time"]
  end

  def schedule_day_of_week
    configuration["day_of_week"]
  end

  def schedule_timezone
    configuration["timezone"] || "UTC"
  end

  # Zimmer event configuration accessors
  def ao_event_name
    configuration["event_name"]
  end

  # The fleet-wide event a system_event condition fires on.
  def system_event_name
    return nil unless condition_type == "system_event"

    configuration["event_name"]
  end

  # Optional session id this ao_event condition is scoped to. When set, the
  # condition only fires when the specified session transitions to the watched
  # state. When nil, the condition fires for any session transitioning to the
  # watched state (broadcast semantics).
  def watched_session_id
    return nil unless condition_type == "ao_event"
    value = configuration["watched_session_id"]
    return nil if value.blank?
    value.to_i
  end

  # Returns true if this ao_event condition is scoped to a specific session.
  def session_scoped_ao_event?
    condition_type == "ao_event" && watched_session_id.present?
  end

  # GitHub configuration accessors
  def github_condition?
    GITHUB_CONDITION_TYPES.include?(condition_type)
  end

  # Repositories this condition watches, as "owner/name" strings.
  def github_repos
    Array(configuration["repos"]).filter_map { |repo| repo.to_s.strip.presence }
  end

  # Labels a github_label condition fires on (OR semantics: any one of them).
  def github_labels
    Array(configuration["labels"]).filter_map { |label| label.to_s.strip.presence }
  end

  # Labels that suppress a github_issue condition (OR semantics: any one of them is
  # enough to keep the issue from firing). This is an opt-out for the author, not a
  # filter for the watcher — see the query builder in GithubTriggerPollerJob.
  def github_exclude_labels
    Array(configuration["exclude_labels"]).filter_map { |label| label.to_s.strip.presence }
  end

  # Whether a github_label condition watches pull requests or issues.
  def github_target
    configuration["target"].presence || "pull_request"
  end

  def github_pull_requests?
    github_target == "pull_request"
  end

  # ── Poller state (owned by GithubTriggerPollerJob) ──────────────────────────

  # The set of "owner/repo#number:label" keys the poller saw carrying a watched
  # label on its last tick. Its ABSENCE — not its emptiness — is what marks a
  # condition as never-polled: a condition whose repos genuinely have no labelled
  # items has a present-but-empty seen-set, and must not be re-baselined.
  def github_baselined?
    configuration.key?("seen_items")
  end

  def github_seen_items
    Array(configuration["seen_items"])
  end

  # Companion to seen_items: how many consecutive polls each seen key has been ABSENT
  # from the search. GitHub's search index is eventually consistent, so a still-labelled
  # PR can vanish from one tick's results and reappear on the next; dropping its key on
  # the first miss re-fires it. The poller keeps a key through a short grace window,
  # counting misses here, and only accepts a key as genuinely unlabelled once it has
  # been absent long enough. A confirmed-present key carries no entry.
  def github_seen_missing_counts
    raw = configuration["seen_missing_counts"]
    raw.is_a?(Hash) ? raw : {}
  end

  # Cursor for github_issue conditions: the created_at of the newest issue fired.
  def github_last_issue_at
    configuration["last_issue_at"].presence
  end

  # Keys of the issues already fired that were created in the cursor's exact second.
  # GitHub's `created:` qualifier has second granularity, so that second is re-queried
  # on every tick and its already-fired issues have to be filtered out by identity.
  def github_seen_issue_keys
    Array(configuration["seen_issue_keys"])
  end

  # What this condition watches. The poller snapshots this at the start of a tick and
  # re-checks it before writing, so a UI edit that lands mid-tick is not clobbered by
  # state computed against the old scope.
  #
  # `exclude_labels` is deliberately NOT part of it. A change to the scope re-baselines
  # the condition — it throws the poll state away (see #preserve_github_poll_state) —
  # which is the right trade when the change WIDENS what is watched. An exclusion only
  # ever narrows, and it exists on `github_issue` alone, whose state is a time cursor:
  # narrowing a time-ordered query cannot make an old issue look new, so there is no
  # retroactive fire to protect against. Re-baselining on every edit would instead
  # discard a live cursor for nothing — the one direction that loses real issues.
  def github_watch_scope
    [ github_repos.sort, github_target, github_labels.sort ]
  end

  # Persist poller state without disturbing the user-facing configuration keys.
  #
  # last_triggered_at rides along in the SAME write as the state it belongs to. Updating it
  # per-fire in a separate statement left a window where the session was created, that write
  # raised, and the item was therefore never recorded as seen — so the next tick created a
  # second session for it.
  def write_github_state!(state, fired: false)
    attrs = { configuration: configuration.merge(state), last_polled_at: Time.current }
    attrs[:last_triggered_at] = Time.current if fired
    update!(attrs)
  end

  # Human-readable schedule description
  def schedule_description
    return nil unless condition_type == "schedule"

    if one_time_schedule?
      tz = schedule_timezone
      zone = ActiveSupport::TimeZone[tz]
      return "Once at #{scheduled_at} (#{tz})" unless zone

      begin
        parsed = zone.parse(scheduled_at)
        "Once at #{parsed.strftime('%Y-%m-%d %H:%M')} (#{tz})"
      rescue ArgumentError
        "Once at #{scheduled_at} (#{tz})"
      end
    else
      interval = schedule_interval
      unit = schedule_unit
      time = schedule_time
      day = schedule_day_of_week
      tz = schedule_timezone

      base = interval == 1 ? "Every #{unit&.singularize}" : "Every #{interval} #{unit}"

      case unit
      when "minutes"
        base
      when "hours"
        time_part = time.present? ? " at :#{time.to_s.split(':').last || '00'}" : ""
        "#{base}#{time_part}"
      when "days"
        time_part = time.present? ? " at #{time}" : ""
        "#{base}#{time_part} (#{tz})"
      when "weeks"
        day_part = day.present? ? " on #{day.capitalize}" : ""
        time_part = time.present? ? " at #{time}" : ""
        "#{base}#{day_part}#{time_part} (#{tz})"
      else
        "Custom schedule"
      end
    end
  end

  # Human-readable description for any condition type
  def description
    case condition_type
    when "slack"
      case event_type
      when "bot_mention"
        channel_name.present? ? "Slack: @mention in ##{channel_name} + DMs" : "Slack: @mention in all channels + DMs"
      when "dm_message"
        allow_all_users? ? "Slack: DMs to Zimmer" : "Slack: DMs to Zimmer from #{allowed_user_ids.size} allowed user(s)"
      when "passive_listen_thread"
        scope = channel_name.present? ? "in ##{channel_name}" : "in all channels"
        "Slack: replies in threads Zimmer joined, #{scope}"
      when "passive_listen_channel"
        scope = channel_name.present? ? "##{channel_name}" : "all channels"
        "Slack: messages in #{scope} Zimmer posted in recently"
      when "passive_listen"
        scope = channel_name.present? ? "##{channel_name}" : "all channels"
        "Slack: passive listening (deprecated: threads + channels) in #{scope}"
      else
        channel_name.present? ? "Slack: ##{channel_name}" : "Slack trigger"
      end
    when "schedule"
      schedule_description || "Schedule trigger"
    when "ao_event"
      base = case ao_event_name
      when "session_needs_input"
        "Zimmer Event: Session needs input"
      when "session_failed"
        "Zimmer Event: Session failed"
      when "session_archived"
        "Zimmer Event: Session archived"
      else
        "Zimmer Event: #{ao_event_name}"
      end
      session_scoped_ao_event? ? "#{base} (session ##{watched_session_id})" : base
    when "system_event"
      case system_event_name
      when "quota_available"
        "System Event: Quota available again"
      else
        "System Event: #{system_event_name}"
      end
    when "github_label"
      kind = github_pull_requests? ? "PRs" : "issues"
      quoted = github_labels.map { |label| "'#{label}'" }.join(" or ")
      "GitHub: #{quoted.presence || '(no labels)'} added to #{kind} in #{github_repos_summary}"
    when "github_issue"
      excluded = github_exclude_labels.map { |label| "'#{label}'" }.join(" or ")
      base = "GitHub: new issue in #{github_repos_summary}"
      excluded.present? ? "#{base}, unless labelled #{excluded}" : base
    else
      "Unknown trigger"
    end
  end

  # Compact repo list for #description — the full list can run to 20 entries.
  def github_repos_summary
    repos = github_repos
    return "(no repos)" if repos.empty?
    return repos.join(", ") if repos.length <= 2

    "#{repos.first}, #{repos.second} +#{repos.length - 2} more"
  end

  # Check if the schedule trigger should fire now
  def schedule_due?
    return false unless condition_type == "schedule"
    return false unless trigger&.enabled?

    now = Time.current.in_time_zone(schedule_timezone)
    last = last_triggered_at&.in_time_zone(schedule_timezone)

    if one_time_schedule?
      return false if last.present?
      parsed = ActiveSupport::TimeZone[schedule_timezone].parse(scheduled_at)
      return now >= parsed
    end

    case schedule_unit
    when "minutes"
      last.nil? || now - last >= schedule_interval.minutes
    when "hours"
      last.nil? || now - last >= schedule_interval.hours
    when "days"
      return true if last.nil?
      target = parse_schedule_time(now)
      now >= target && (now.to_date - last.to_date).to_i >= schedule_interval
    when "weeks"
      return true if last.nil?
      target_day = DAYS_OF_WEEK.index(schedule_day_of_week) # 0=monday
      current_day = (now.wday - 1) % 7 # Convert Sunday=0 to Monday=0
      target = parse_schedule_time(now)
      weeks_elapsed = ((now.to_date - last.to_date).to_i / 7.0).floor
      current_day == target_day && now >= target && weeks_elapsed >= schedule_interval
    else
      false
    end
  rescue ArgumentError
    Rails.logger.warn "[TriggerCondition#schedule_due?] Invalid timezone '#{schedule_timezone}' for condition #{id}"
    false
  end

  # Update the last polled timestamp (for Slack polling)
  def mark_polled!(message_ts: nil)
    attrs = { last_polled_at: Time.current }
    attrs[:last_message_ts] = message_ts if message_ts
    update!(attrs)
  end

  private

  # The trigger form submits repos and labels as one-per-line textareas (a single
  # array element containing newlines); the REST API and MCP surface send real JSON
  # arrays. Flatten both into a deduped array of strings so validation, the poller,
  # and the query builder all see one shape.
  def normalize_github_configuration
    return unless configuration.is_a?(Hash)

    configuration["repos"] = split_lines(configuration["repos"])

    if condition_type == "github_label"
      configuration["labels"] = split_lines(configuration["labels"])
      configuration["target"] = configuration["target"].presence || "pull_request"
      # The mirror image of the deletes below: an exclusion list is a github_issue
      # field, so a type switch must not leave one behind on a label condition that
      # neither the UI nor the query builder would ever consult again.
      configuration.delete("exclude_labels")
    else
      # A github_issue condition fires on creation, not on labels. Drop the fields
      # so a type switch in the form can't leave a stale label filter behind that
      # the UI no longer shows but #description would still claim.
      configuration.delete("labels")
      configuration.delete("target")
      configuration["exclude_labels"] = split_lines(configuration["exclude_labels"])
    end
  end

  # Labels may legitimately contain commas ("needs review, blocked"), so lines are
  # the only separator. Repos cannot contain either.
  def split_lines(value)
    Array(value)
      .flat_map { |entry| entry.to_s.split(/\r?\n/) }
      .filter_map { |entry| entry.strip.presence }
      .uniq
  end

  # The poller stores its cursor inside `configuration`, but the trigger form only
  # renders the user-facing keys — so a plain "save" in the UI submits a hash with
  # the cursor missing and would silently reset it. Merge the persisted state back in
  # whenever the incoming configuration omits it.
  #
  # The exception is a change to WHAT the condition watches. Adding a repo or a label
  # widens the query, and every item already carrying the label in the newly-watched
  # scope would look new against the old seen-set and fire at once. Dropping the state
  # instead re-baselines the condition on the next tick, which keeps the guarantee that
  # matters: an item labelled before you asked to watch it does not fire retroactively.
  # Merge the Slack poller's cursors back in whenever the incoming configuration
  # omits them. Unlike the GitHub equivalent there is no scope-change branch that
  # drops them: every Slack cursor is keyed by channel or by thread, so a condition
  # that changes channel or event type simply stops consulting the entries that no
  # longer apply rather than being re-baselined by them.
  def preserve_slack_poll_state
    return if new_record?
    return unless configuration.is_a?(Hash) && configuration_was.is_a?(Hash)
    return unless configuration_changed?

    SLACK_POLL_STATE_KEYS.each do |key|
      next if configuration.key?(key)
      configuration[key] = configuration_was[key] if configuration_was.key?(key)
    end
  end

  def preserve_github_poll_state
    return if new_record?
    return unless configuration.is_a?(Hash) && configuration_was.is_a?(Hash)
    return unless configuration_changed?

    if github_watch_scope_changed?
      GITHUB_POLL_STATE_KEYS.each { |key| configuration.delete(key) }
      return
    end

    GITHUB_POLL_STATE_KEYS.each do |key|
      next if configuration.key?(key)
      configuration[key] = configuration_was[key] if configuration_was.key?(key)
    end
  end

  def github_watch_scope_changed?
    scope_of = lambda do |config|
      [
        split_lines(config["repos"]).sort,
        config["target"].to_s,
        split_lines(config["labels"]).sort
      ]
    end

    scope_of.call(configuration) != scope_of.call(configuration_was)
  end

  def parse_schedule_time(reference_time)
    return reference_time.beginning_of_day unless schedule_time.present?
    parts = schedule_time.to_s.split(":")
    hour = (parts[0] || "0").to_i
    minute = (parts[1] || "0").to_i
    reference_time.change(hour: hour, min: minute, sec: 0)
  end

  def validate_configuration_for_type
    unless configuration.is_a?(Hash)
      errors.add(:configuration, "must be a hash")
      return
    end

    case condition_type
    when "slack"
      validate_slack_configuration
    when "schedule"
      validate_schedule_configuration
    when "ao_event"
      validate_ao_event_configuration
    when "system_event"
      validate_system_event_configuration
    when "github_label", "github_issue"
      validate_github_configuration
    end
  end

  def validate_system_event_configuration
    event_name = configuration["event_name"]
    if event_name.blank?
      errors.add(:configuration, "must include event_name for System Event conditions")
      return
    end

    unless SYSTEM_EVENT_NAMES.include?(event_name)
      errors.add(:configuration, "event_name must be one of: #{SYSTEM_EVENT_NAMES.join(', ')}")
    end
  end

  def validate_github_configuration
    repos = github_repos

    if repos.empty?
      errors.add(:configuration, "must include at least one repo for GitHub conditions")
    elsif repos.length > MAX_GITHUB_REPOS
      errors.add(:configuration, "must watch at most #{MAX_GITHUB_REPOS} repos (got #{repos.length})")
    else
      malformed = repos.reject { |repo| repo.match?(GITHUB_REPO_FORMAT) }
      if malformed.any?
        errors.add(:configuration, "repos must be in owner/name format: #{malformed.join(', ')}")
      end
    end

    return unless condition_type == "github_label"

    if github_labels.empty?
      errors.add(:configuration, "must include at least one label for GitHub label conditions")
    end

    unless GITHUB_TARGETS.include?(github_target)
      errors.add(:configuration, "target must be one of: #{GITHUB_TARGETS.join(', ')}")
    end
  end

  def validate_slack_configuration
    # channel_id is required for new_message, optional for the all-channel event
    # types (bot_mention also monitors DMs; passive_listen sweeps every channel
    # the bot is in).
    if configuration["channel_id"].blank? && !ALL_CHANNEL_EVENT_TYPES.include?(event_type)
      errors.add(:configuration, "must include channel_id for Slack conditions")
    end

    if configuration["event_type"].present? && !EVENT_TYPES.include?(configuration["event_type"])
      errors.add(:configuration, "event_type must be one of: #{EVENT_TYPES.join(', ')}")
    end

    # thread_ts scopes a new_message condition to a single thread's replies. It
    # requires a channel_id (which thread to read), and is meaningless for the
    # all-channel event types — those walk threads themselves, filtering by
    # @mention (bot_mention) or by prior participation (passive_listen).
    if configuration["thread_ts"].present?
      if configuration["channel_id"].blank?
        errors.add(:configuration, "thread_ts requires a channel_id")
      end
      if ALL_CHANNEL_EVENT_TYPES.include?(event_type)
        errors.add(:configuration, "thread_ts is not supported for #{event_type} conditions")
      end
    end
  end

  def validate_schedule_configuration
    if configuration["scheduled_at"].present?
      validate_one_time_schedule_configuration
    else
      validate_recurring_schedule_configuration
    end

    if configuration["timezone"].present? && !ActiveSupport::TimeZone[configuration["timezone"]]
      errors.add(:configuration, "timezone is not a recognized timezone")
    end
  end

  # Validates that scheduled_at is a parseable ISO 8601 datetime.
  # This only checks format — schedule_due? interprets the value relative to
  # the configured timezone. Past datetimes are allowed ("fire ASAP" semantics).
  #
  # Also normalizes the value: HTML datetime-local inputs submit "YYYY-MM-DDTHH:MM"
  # (no seconds), but Time.iso8601 requires seconds. Appends ":00" if needed.
  def validate_one_time_schedule_configuration
    value = configuration["scheduled_at"]

    # Normalize datetime-local format (YYYY-MM-DDTHH:MM) to full ISO 8601
    if value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/)
      configuration["scheduled_at"] = "#{value}:00"
      value = configuration["scheduled_at"]
    end

    parsed = begin
      Time.iso8601(value)
    rescue ArgumentError, TypeError
      nil
    end
    unless parsed
      errors.add(:configuration, "scheduled_at must be a valid datetime (ISO 8601 format)")
    end
  end

  def validate_recurring_schedule_configuration
    unit = configuration["unit"]
    if unit.blank?
      errors.add(:configuration, "must include unit for Schedule conditions")
      return
    end

    unless SCHEDULE_UNITS.include?(unit)
      errors.add(:configuration, "unit must be one of: #{SCHEDULE_UNITS.join(', ')}")
      return
    end

    interval = configuration["interval"]
    if interval.blank?
      errors.add(:configuration, "must include interval for Schedule conditions")
      return
    end

    interval_val = interval.to_i
    if interval_val < 1
      errors.add(:configuration, "interval must be at least 1")
    end

    if %w[days weeks].include?(unit) && configuration["time"].blank?
      errors.add(:configuration, "must include time for #{unit} schedules")
    end

    if unit == "weeks" && configuration["day_of_week"].blank?
      errors.add(:configuration, "must include day_of_week for weekly schedules")
    end

    if configuration["day_of_week"].present? && !DAYS_OF_WEEK.include?(configuration["day_of_week"])
      errors.add(:configuration, "day_of_week must be one of: #{DAYS_OF_WEEK.join(', ')}")
    end

    if configuration["time"].present? && !configuration["time"].match?(/\A([01]\d|2[0-3]):[0-5]\d\z/)
      errors.add(:configuration, "time must be in HH:MM format")
    end
  end

  def validate_ao_event_configuration
    event_name = configuration["event_name"]
    if event_name.blank?
      errors.add(:configuration, "must include event_name for Zimmer Event conditions")
      return
    end

    unless AO_EVENT_NAMES.include?(event_name)
      errors.add(:configuration, "event_name must be one of: #{AO_EVENT_NAMES.join(', ')}")
    end

    if configuration.key?("watched_session_id") && configuration["watched_session_id"].present?
      raw = configuration["watched_session_id"]
      session_id = raw.is_a?(Integer) ? raw : raw.to_s.to_i

      if session_id <= 0
        errors.add(:configuration, "watched_session_id must be a positive integer")
      elsif !Session.where(id: session_id).exists?
        errors.add(:configuration, "watched_session_id #{session_id} does not reference an existing session")
      else
        # Normalize to integer so JSON storage is canonical
        configuration["watched_session_id"] = session_id
      end
    end
  end
end

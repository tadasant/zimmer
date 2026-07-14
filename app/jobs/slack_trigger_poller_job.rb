# frozen_string_literal: true

# Job that polls Slack channels for new messages and creates sessions based on trigger conditions.
#
# This job runs on a cron schedule (every minute) and:
# 1. Iterates through all Slack-type trigger conditions on enabled triggers
# 2. Fetches messages newer than the condition's last_message_ts
# 3. Skips thread replies for new_message conditions (but NOT bot messages - bots are valid trigger sources)
# 4. Creates sessions for each new message using the trigger's template
# 5. Updates the condition's last_message_ts to prevent duplicates
#
# For bot_mention conditions:
# - If a channel is configured, monitors that channel for @mentions of the bot
# - If no channel is configured, monitors ALL channels the bot is a member of for @mentions
# - Always monitors DM channels with allowed users for any messages
# - Also monitors thread replies for @mentions (so replying to a thread with @bot works)
# - Only processes messages from allowed users: the condition's own allowed_user_ids if
#   set, else the SLACK_BOT_MENTION_ALLOWED_USER_IDS allow-list, else EVERYONE (see
#   TriggerCondition#allow_all_users?). The bot's own messages never trigger anything.
class SlackTriggerPollerJob < ApplicationJob
  # Runs on the dedicated `pollers` queue (like every other *PollerJob), NOT on
  # `default`. A single poll is a long, external-API-bound unit of work: it makes
  # many Slack calls, and SlackService retries rate-limited calls with blocking
  # `sleep`s (up to MAX_RETRIES per call), so a rate-limited run can hold its
  # worker thread for minutes. On the shared `default` queue those minutes-long
  # runs starved the latency-sensitive periodic jobs that also live there
  # (HeartbeatSweepJob every 30s, the cleanup/refresh crons), collapsing
  # background throughput. The `pollers` queue is isolated for exactly this kind
  # of slow, self-contained polling job.
  queue_as :pollers

  # Singleton pattern: at most one poll unfinished (running or queued) at a time,
  # matching every other poller (GithubCommentPollerJob, CliStatusRefreshJob, …).
  # The cron enqueues a poll every minute, but a rate-limited run can take several
  # minutes; without this cap those runs pile up — each holding a worker thread in
  # a Slack-rate-limit `sleep` — until they saturate the queue's whole thread pool
  # and no other polling work can run. total_limit: 1 makes an enqueue while a
  # poll is still in flight a no-op, so a slow poll can never stack against itself.
  # Polling is idempotent (timestamps only advance on success), so a skipped tick
  # is simply picked up by the next cron run.
  good_job_control_concurrency_with(
    key: -> { "slack_trigger_poller" },
    total_limit: 1
  )

  # Cap on how many aged-out tracked threads to re-check per channel per poll,
  # bounding the extra conversations.replies calls. Prioritized by most-recent
  # tracked activity so the busiest long-lived threads are always covered.
  MAX_TRACKED_THREAD_RECHECKS = 20

  # Only re-check tracked threads whose last seen reply is within this window;
  # older ones are treated as dead to avoid steady wasted API calls. A thread
  # that resumes within the horizon is picked back up and, once re-checked each
  # poll, keeps its tracked timestamp fresh so it stays eligible going forward.
  RECHECK_HORIZON = 45.days

  # Lightweight stand-in for a thread parent synthesized from a tracked
  # thread_timestamps key: we know the thread_ts but not its latest_reply, so
  # latest_reply is nil to force a direct replies fetch in the checking loop.
  RecheckThreadParent = Struct.new(:ts, :latest_reply)

  def perform
    return unless SlackService.configured?

    # Wrap iteration in an AlertBatcher scope so catalog issues affecting many
    # triggers in one tick emit a single aggregated Slack message.
    AlertBatcher.with_batch do
      TriggerCondition.slack
        .joins(:trigger)
        .where(triggers: { status: "enabled" })
        .includes(:trigger)
        .find_each do |condition|
        process_condition(condition)
      rescue => e
        Rails.logger.error "[SlackTriggerPollerJob] Error processing condition #{condition.id}: #{e.message}"
        AlertService.raise_alert(
          "Slack trigger poller error",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) failed:\n#{e.message}",
          source: "SlackTriggerPollerJob",
          dedup_key: "slack_trigger_condition_#{condition.id}"
        )
      end
    end
  end

  private

  def process_condition(condition)
    if condition.event_type == "bot_mention"
      process_bot_mention_condition(condition)
    else
      process_new_message_condition(condition)
    end
  end

  # Process a standard new_message condition: all messages create sessions.
  #
  # Two modes, keyed on whether the condition is thread-scoped:
  # - Channel mode (default): new TOP-LEVEL messages in the channel fire the trigger.
  # - Thread mode (thread_ts configured): new REPLIES in that specific thread fire
  #   the trigger. Required for feeds whose posts arrive as thread replies (e.g. a
  #   daily digest thread), which conversations.history-based channel polling never
  #   surfaces.
  def process_new_message_condition(condition)
    channel_id = condition.channel_id
    return if channel_id.blank?

    # Get messages since last poll
    messages = if condition.thread_scoped?
      fetch_new_thread_replies(channel_id, condition.thread_ts, condition.last_message_ts)
    else
      fetch_new_messages(channel_id, condition.last_message_ts)
    end
    return if messages.empty?

    source = condition.thread_scoped? ? "thread #{condition.thread_ts}" : condition.channel_name
    Rails.logger.info "[SlackTriggerPollerJob] Found #{messages.length} new message(s) in #{source} for condition #{condition.id}"

    # Process each message
    messages.each do |message|
      process_message(condition, message, channel_id: channel_id)
    end

    # Update last polled timestamp with the newest message's timestamp
    newest_ts = messages.map { |m| m.ts }.max
    condition.mark_polled!(message_ts: newest_ts)
  end

  # Process a bot_mention condition:
  # 1. Poll configured channel (if any) for @mentions from allowed users,
  #    OR poll all member channels if no specific channel is configured
  # 2. Poll DM channels with allowed users for any messages
  def process_bot_mention_condition(condition)
    bot_id = SlackService.bot_user_id

    # Part 1: Poll channel(s) for @mentions
    if condition.channel_id.present?
      # Single configured channel
      process_channel_mentions(condition, bot_id: bot_id)
    else
      # No channel configured — poll all channels the bot is a member of
      process_all_channel_mentions(condition, bot_id: bot_id)
    end

    # Part 2: Poll DM channels with allowed users
    process_dm_messages(condition, bot_id: bot_id)

    condition.update!(last_polled_at: Time.current)
  end

  # Whether a message is an @mention of the bot that this condition may fire on.
  #
  # The bot's OWN messages never qualify, whatever the allow-list says. Zimmer posts
  # to Slack with this same token (AlertService), and a bot_mention condition with no
  # channel configured polls EVERY channel the bot is in -- so without this, an alert
  # quoting "<@bot>" would trigger a session, which would alert, which would trigger.
  #
  # Messages from OTHER apps still qualify, as long as Slack attributes them to a user
  # (apps posting with a bot token carry the bot's user ID). The poller already treats
  # bots as valid trigger sources for new_message conditions, and "an alerting app
  # @mentions Zimmer to open a session" is a use case, not an accident -- only the
  # self-loop is closed. Messages with no `user` at all (legacy webhooks) never fire
  # anything: there is no identity to check an allow-list against.
  def mention_for?(condition, message, bot_id)
    return false unless message.text&.include?("<@#{bot_id}>")
    return false if message.user == bot_id

    condition.user_allowed?(message.user)
  end

  # Poll a single configured channel for @bot mentions from allowed users
  def process_channel_mentions(condition, bot_id:)
    all_messages = fetch_new_messages(condition.channel_id, condition.last_message_ts)

    if all_messages.any?
      # Filter to messages that mention the bot AND are from allowed users
      mentions = all_messages.select { |msg| mention_for?(condition, msg, bot_id) }

      mentions.each do |message|
        process_message(condition, message, channel_id: condition.channel_id)
      end

      # Always advance last_message_ts to avoid reprocessing, even if no mentions matched
      newest_ts = all_messages.map { |m| m.ts }.max
      condition.update!(last_message_ts: newest_ts)
    end

    # Check thread replies for @mentions (even when no new top-level messages,
    # since replies to old threads won't appear in conversations.history)
    check_thread_replies_for_mentions(condition, condition.channel_id, all_messages, bot_id: bot_id)
  end

  # Poll all channels the bot is a member of for @bot mentions from allowed users.
  # Uses per-channel timestamps stored in condition.channel_timestamps.
  # Batches all timestamp updates into a single DB write at the end.
  def process_all_channel_mentions(condition, bot_id:)
    member_channels = SlackService.list_member_channels
    updated_timestamps = {}

    member_channels.each do |channel|
      last_ts = condition.channel_timestamps[channel.id]

      all_messages = fetch_new_messages(channel.id, last_ts)

      if all_messages.any?
        # Filter to messages that mention the bot AND are from allowed users
        mentions = all_messages.select { |msg| mention_for?(condition, msg, bot_id) }

        mentions.each do |message|
          process_message(condition, message, channel_id: channel.id, prior_ts: last_ts)
        end

        # Collect timestamp update (written in batch below)
        updated_timestamps[channel.id] = all_messages.map { |m| m.ts }.max
      end

      # Check thread replies for @mentions (even when no new top-level messages,
      # since replies to old threads won't appear in conversations.history)
      check_thread_replies_for_mentions(condition, channel.id, all_messages, bot_id: bot_id)
    rescue => e
      Rails.logger.error "[SlackTriggerPollerJob] Error polling channel #{channel.id} for mentions: #{e.message}"
    end

    # Batch-write all channel timestamp updates in a single DB call
    if updated_timestamps.any?
      new_timestamps = condition.channel_timestamps.merge(updated_timestamps)
      new_config = condition.configuration.merge("channel_timestamps" => new_timestamps)
      condition.update!(configuration: new_config)
    end
  end

  # Check thread replies in a channel for @bot mentions from allowed users.
  #
  # For each thread parent in the given messages (identified by reply_count > 0),
  # fetches new replies since the last checked timestamp and looks for @mentions.
  # Also scans recent channel history for older threads with new replies.
  #
  # Thread timestamps are stored in condition.thread_timestamps as
  # "channel_id:thread_ts" => last_reply_ts to track what's been checked.
  # Batches all thread timestamp updates into a single DB write.
  #
  # @param condition [TriggerCondition] the trigger condition
  # @param channel_id [String] the channel being polled
  # @param recent_messages [Array] messages already fetched from conversations.history
  # @param bot_id [String] the bot's user ID
  def check_thread_replies_for_mentions(condition, channel_id, recent_messages, bot_id:)
    # Skip thread checking on first poll for a channel (no baseline established yet).
    # For single-channel: check last_message_ts; for all-channels: check channel_timestamps.
    channel_baseline_ts = condition.last_message_ts.presence || condition.channel_timestamps[channel_id]
    return if channel_baseline_ts.blank?

    thread_ts_updates = {}

    # Find thread parents from the messages we already have
    thread_parents = recent_messages.select { |msg| msg.reply_count.to_i > 0 }

    # Also check for older threads with new replies by fetching a wider window.
    # This catches the key scenario: user replies to an OLD thread (whose parent
    # won't appear in fetch_new_messages since it predates last_message_ts).
    # Only fetch wider window when we have tracked threads or recent_messages is
    # empty/small (avoids redundant API calls when we already have recent data).
    if recent_messages.length < 10 || condition.thread_timestamps.keys.any? { |k| k.start_with?("#{channel_id}:") }
      wider_messages = fetch_recent_thread_parents(channel_id)
      existing_ts = thread_parents.map(&:ts).to_set
      wider_messages.each do |msg|
        thread_parents << msg unless existing_ts.include?(msg.ts)
      end
    end

    # Re-check tracked threads whose parent has aged out of the recent-history
    # window. fetch_recent_thread_parents only surfaces threads whose parent is
    # among the last 50 top-level messages, so a long-lived thread — e.g. a
    # months-old digest thread that still receives daily replies — stops being
    # visited once its parent scrolls past that window, even though it remains
    # tracked in thread_timestamps. Without this, @mentions posted as replies to
    # such a thread are silently missed.
    #
    # Fan-out is one conversations.replies call per re-checked thread, so bound
    # these aged-out additions (the recent-window parents above are already
    # limited by fetch_recent_thread_parents): drop threads with no tracked
    # activity within RECHECK_HORIZON (treated as dead) and keep only the
    # MAX_TRACKED_THREAD_RECHECKS most-recently-active per channel. Threads
    # already covered above (parent still near the top of the channel) are
    # skipped to avoid duplicate fetches.
    already_covered = thread_parents.map(&:ts).to_set
    horizon_ts = RECHECK_HORIZON.ago.to_f
    aged_out = condition.thread_timestamps.select do |key, last_reply_ts|
      key.start_with?("#{channel_id}:") &&
        !already_covered.include?(key.split(":", 2).last) &&
        last_reply_ts.to_f >= horizon_ts
    end
    aged_out = aged_out.sort_by { |_key, last_reply_ts| -last_reply_ts.to_f }
      .first(MAX_TRACKED_THREAD_RECHECKS)
    aged_out.each do |key, _last_reply_ts|
      thread_parents << RecheckThreadParent.new(key.split(":", 2).last, nil)
    end

    thread_parents.each do |parent|
      thread_key = "#{channel_id}:#{parent.ts}"
      last_reply_ts = condition.thread_timestamps[thread_key]

      # Skip threads we've already fully checked (no new replies since last check)
      latest_reply = parent.latest_reply
      next if latest_reply.present? && last_reply_ts.present? && latest_reply <= last_reply_ts

      # Fetch new replies in this thread
      replies = SlackService.get_thread_replies(channel_id, parent.ts, oldest: last_reply_ts)
      # Slack's oldest parameter is inclusive, so filter out the already-seen reply
      replies.reject! { |r| r.ts == last_reply_ts } if last_reply_ts.present?
      next if replies.empty?

      # Filter to @mentions from allowed users
      mention_replies = replies.select { |reply| mention_for?(condition, reply, bot_id) }

      # For threads we haven't seen before (no thread-level timestamp), use the
      # channel baseline to determine which replies are new. This avoids the
      # per-thread baseline problem where the first poll after deployment swallows
      # all replies, even ones that arrived after the channel was already being polled.
      effective_prior_ts = last_reply_ts || channel_baseline_ts

      mention_replies.each do |reply|
        # Only process replies newer than our effective baseline
        next if reply.ts <= effective_prior_ts

        process_message(condition, reply, channel_id: channel_id, prior_ts: effective_prior_ts)
      end

      # Track the newest reply timestamp for this thread
      newest_reply_ts = replies.map { |r| r.ts }.max
      thread_ts_updates[thread_key] = newest_reply_ts
    rescue => e
      Rails.logger.error "[SlackTriggerPollerJob] Error checking thread #{parent.ts} in #{channel_id}: #{e.message}"
    end

    # Batch-write thread timestamp updates
    if thread_ts_updates.any?
      new_thread_ts = condition.thread_timestamps.merge(thread_ts_updates)
      new_config = condition.configuration.merge("thread_timestamps" => new_thread_ts)
      condition.update!(configuration: new_config)
    end
  end

  # Fetch recent thread parents from a channel to catch old threads with new replies.
  # Uses a small limit since we only need to find active threads.
  # Returns messages that have replies (reply_count > 0).
  def fetch_recent_thread_parents(channel_id)
    messages = SlackService.get_channel_history(channel_id, limit: 50)
    messages.select { |msg| msg.reply_count.to_i > 0 }
  rescue => e
    Rails.logger.error "[SlackTriggerPollerJob] Error fetching recent threads for #{channel_id}: #{e.message}"
    []
  end

  # Poll DM channels with allowed users for any messages.
  #
  # This path ENUMERATES the allow-list rather than filtering with it, which is why it
  # must branch on allow_all_users? instead of just passing allowed_user_ids down: an
  # unrestricted condition has an empty list, and handing that to list_dm_channels
  # would match no DMs at all -- "everyone" would silently become "nobody".
  def process_dm_messages(condition, bot_id:)
    user_ids = condition.allow_all_users? ? nil : condition.allowed_user_ids
    dm_channels = SlackService.list_dm_channels(user_ids: user_ids)

    # Never poll a DM with ourselves (the unrestricted path lists every IM there is).
    dm_channels = dm_channels.reject { |dm_channel| dm_channel.user == bot_id }

    dm_channels.each do |dm_channel|
      user_id = dm_channel.user
      last_ts = condition.dm_timestamps[user_id]

      messages = fetch_new_messages(dm_channel.id, last_ts)
      next if messages.empty?

      # Filter to only messages from the allowed user (not the bot's own messages)
      user_messages = messages.select { |msg| msg.user == user_id }

      user_messages.each do |message|
        process_message(condition, message, channel_id: dm_channel.id, dm: true)
      end

      # Advance DM timestamp for this user
      newest_ts = messages.map { |m| m.ts }.max
      condition.update_dm_timestamp!(user_id, newest_ts)
    rescue => e
      Rails.logger.error "[SlackTriggerPollerJob] Error polling DMs for user #{user_id}: #{e.message}"
    end
  end

  # Fetch new messages from a channel since a given timestamp.
  # On first poll (no timestamp), establishes a baseline without processing.
  # Returns messages oldest-first, excluding thread replies.
  def fetch_new_messages(channel_id, last_ts)
    # If no previous poll, just get the most recent message to establish a baseline
    # This prevents creating sessions for historical messages on first enable
    if last_ts.blank?
      messages = SlackService.get_channel_history(channel_id, limit: 1)
      return messages.presence || []
    end

    # Get all messages newer than last_message_ts
    messages = SlackService.get_messages_since(channel_id, since_ts: last_ts)

    # Filter out thread replies and already-processed messages
    messages.reject do |msg|
      (msg.thread_ts.present? && msg.thread_ts != msg.ts) || msg.ts == last_ts
    end
  end

  # Fetch new replies in a specific thread since a given timestamp.
  # On first poll (no timestamp), establishes a baseline (the newest existing
  # reply) without processing history — mirroring fetch_new_messages, so enabling
  # a thread-scoped condition never replays the whole digest backlog.
  # Returns replies excluding the thread parent and the already-processed reply.
  #
  # NOTE: Slack's conversations.replies is NOT guaranteed to return messages in
  # globally chronological order across paginated pages — the array's last element
  # is not necessarily the newest reply. Always select the newest by comparing
  # timestamps (.max_by) rather than relying on array position.
  def fetch_new_thread_replies(channel_id, thread_ts, last_ts)
    # get_thread_replies excludes the parent message.
    if last_ts.blank?
      replies = SlackService.get_thread_replies(channel_id, thread_ts)
      return [] if replies.empty?

      # Newest existing reply becomes the baseline; nothing is processed yet.
      [ replies.max_by { |r| r.ts.to_f } ]
    else
      replies = SlackService.get_thread_replies(channel_id, thread_ts, oldest: last_ts)
      # Slack's oldest parameter is inclusive, so drop the already-seen reply.
      replies.reject { |r| r.ts == last_ts }
    end
  end

  def process_message(condition, message, channel_id:, dm: false, prior_ts: nil)
    trigger = condition.trigger

    # For first-poll baseline messages, just record the timestamp.
    # Determine the relevant prior timestamp based on message source:
    # - DMs: per-user dm_timestamps
    # - All-channel monitoring: per-channel channel_timestamps (passed as prior_ts)
    # - Single configured channel: condition.last_message_ts
    relevant_ts = if dm
      condition.dm_timestamps[message.user]
    elsif prior_ts
      prior_ts
    else
      condition.last_message_ts
    end
    return if relevant_ts.blank?

    # Get message details for the prompt
    permalink = SlackService.get_message_permalink(channel_id, message.ts)
    author_name = get_author_name(message)
    message_text = message.text || ""

    channel_name = dm ? "DM" : (condition.channel_name.presence || resolve_channel_name(channel_id))

    prompt = trigger.interpolate_prompt(
      link: permalink,
      text: message_text,
      author: author_name,
      channel: channel_name
    )

    session = trigger.create_session!(prompt: prompt)

    # Burst control can suppress the spawn (see Trigger::BURST_WINDOW). The
    # message is then DROPPED, not retried: the caller advances the condition's
    # cursor to the newest message it fetched regardless of what each message
    # produced, which is exactly what we want here — replaying a burst once it
    # subsides would spawn the very sessions the cap exists to prevent.
    if session.nil?
      Rails.logger.info "[SlackTriggerPollerJob] Trigger #{trigger.id} spawned nothing for message #{message.ts} (burst-suppressed) — dropping it"
      return
    end

    # Update condition's last_triggered_at
    condition.update!(last_triggered_at: Time.current)

    Rails.logger.info "[SlackTriggerPollerJob] Created session #{session.id} for trigger #{trigger.id} from #{dm ? 'DM' : 'channel'} message #{message.ts}"
  rescue => e
    Rails.logger.error "[SlackTriggerPollerJob] Failed to create session for message #{message.ts}: #{e.message}"
  end

  def resolve_channel_name(channel_id)
    @channel_name_cache ||= {}
    @channel_name_cache[channel_id] ||= begin
      SlackService.get_channel(channel_id)&.name || channel_id
    rescue SlackService::SlackError
      channel_id
    end
  end

  def get_author_name(message)
    # For bot messages, use the bot's username or name
    if message.bot_id.present?
      return message.username || message.bot_profile&.name || "Bot"
    end

    return "Unknown" if message.user.blank?

    SlackService.get_user_name(message.user)
  rescue SlackService::SlackError
    message.user
  end
end

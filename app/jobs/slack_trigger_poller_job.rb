# frozen_string_literal: true

# Job that polls Slack channels for new messages and creates sessions based on trigger conditions.
#
# This job runs on a cron schedule (every minute) and:
# 1. Iterates through all Slack-type trigger conditions on enabled triggers
# 2. Fetches messages newer than the condition's last_message_ts
# 3. Skips thread replies for new_message conditions (but NOT bot messages - bots are valid trigger sources)
# 4. Creates sessions for each new message using the trigger's template — one per
#    EVENT, not one per message: messages in the same conversation that landed
#    within the trigger's coalescing window of each other are one event, and the
#    ones folded away are carried in the surviving session's prompt (see
#    #coalesced_groups and Trigger::DEFAULT_COALESCE_WINDOW_SECONDS)
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
#
# For passive-listening conditions (see #process_passive_listen_condition):
# - Same channel sweep and same per-channel/per-thread bookkeeping as bot_mention,
#   but the filter is PARTICIPATION rather than @mention. The two signals are two
#   separately selectable event types, because a Trigger ORs its conditions:
#   passive_listen_thread fires on a reply in a thread Zimmer has spoken in, and
#   passive_listen_channel fires on a top-level message in a channel Zimmer posted
#   in within CHANNEL_ENGAGEMENT_WINDOW.
# - Same allow-list, and the same rule that the bot's own messages never fire. Other
#   apps' messages don't fire passively either — passive listening is for the
#   conversation Zimmer is already in, not for feeds — and neither do @mentions,
#   which belong to bot_mention (see #passive_candidate?).
# - No DM polling: every DM to the bot is already directed at it, and both the
#   bot_mention and dm_message condition types cover DMs unconditionally.
class SlackTriggerPollerJob < ApplicationJob
  # Runs on the dedicated `pollers` queue (like every other *PollerJob), NOT on
  # `default`. A single poll is a long, external-API-bound unit of work: it makes
  # many Slack calls, each of which may absorb a short blip with a blocking
  # `sleep` (SlackService::MAX_RETRIES per call). On the shared `default` queue a
  # run that slow starves the latency-sensitive periodic jobs that live there
  # (HeartbeatSweepJob every 30s, the cleanup/refresh crons) and collapses
  # background throughput. The `pollers` queue is isolated for exactly this kind
  # of slow, self-contained polling job.
  queue_as :pollers

  # Singleton pattern: at most one poll unfinished (running or queued) at a time,
  # matching every other poller (GithubCommentPollerJob, CliStatusRefreshJob, …).
  # The cron enqueues a poll every minute, but a poll can outrun a minute; without
  # this cap those runs pile up — each holding a worker thread — until they
  # saturate the queue's whole thread pool and no other polling work can run.
  # total_limit: 1 makes an enqueue while a poll is still in flight a no-op, so a
  # slow poll can never stack against itself. Polling is idempotent (timestamps
  # only advance on success), so a skipped tick is simply picked up by the next
  # cron run.
  #
  # The flip side, and the reason for #defer_poll below: while this job is in
  # flight it IS Slack polling for the whole instance. A run that parks itself in
  # a long `sleep` waiting out a Slack rate limit does not just delay itself — it
  # rejects every cron tick that lands in that window, for every trigger. So a
  # transient Slack failure must end the run, not be waited out inside it.
  good_job_control_concurrency_with(
    key: -> { "slack_trigger_poller" },
    total_limit: 1
  )

  # How many times a single poll may reschedule itself before giving up and
  # letting the ordinary cron cadence take over.
  MAX_DEFERRALS = 5

  # Deferral backoff when Slack is unavailable and told us nothing more specific:
  # 30s, 60s, 120s, 240s, 480s — about 15 minutes across the five, capped at
  # MAX_DEFERRAL_DELAY. A rate limit that carries a `retry_after` uses that value
  # instead when it is longer.
  DEFERRAL_BASE_DELAY = 30
  MAX_DEFERRAL_DELAY = 10.minutes.to_i

  # How many aged-out tracked threads to re-check per channel per POLL. Each one
  # costs at least one conversations.replies call — a synthesized parent has no
  # latest_reply, so the cheap skip cannot fire for it — and Slack rate-limits that
  # method hard enough to have taken the whole poller down before (#509, #522).
  # This is what keeps a channel's fan-out flat no matter how many threads it
  # tracks.
  #
  # It bounds THREADS, not calls, and the two come apart when a thread has more
  # than one page of unfetched replies: SlackService.get_thread_replies paginates
  # at 100 until the thread is drained. At the ordinary cadence a thread accrues
  # far under a page between visits, so the two are the same number in practice —
  # but a thread first re-checked across a long gap can cost several calls.
  #
  # It is a per-poll BUDGET, not a cap on how many threads are covered. Threads
  # that do not fit are carried to the next poll by #rotating_recheck_slice, so
  # everything inside RECHECK_HORIZON is still visited — later rather than never.
  MAX_TRACKED_THREAD_RECHECKS = 20

  # How much of that budget is reserved for the most-recently-active tracked
  # threads, which are re-checked on EVERY poll instead of in rotation.
  #
  # A conversation that is actually live has to be answered at the poll cadence, so
  # ranking by tracked activity governs this band. The rotation is the WAKE-UP path
  # instead: it exists to notice the first reply in a thread that had gone quiet,
  # and that reply advances the thread's tracked timestamp, which promotes it into
  # this band for as long as the back-and-forth lasts.
  HOT_TRACKED_THREAD_RECHECKS = 10

  # Only re-check tracked threads whose last seen reply is within this window;
  # older ones are treated as dead to avoid steady wasted API calls. A thread
  # that resumes within the horizon is picked back up and, once re-checked each
  # poll, keeps its tracked timestamp fresh so it stays eligible going forward.
  RECHECK_HORIZON = 45.days

  # How many recent top-level messages to pull when looking for a channel's active
  # threads (and, for passive listening, for Zimmer's own recent posts).
  RECENT_HISTORY_LIMIT = 50

  # How recently Zimmer must have posted in a channel for passive_listen_channel to
  # fire on that channel's TOP-LEVEL messages. "Recently involved in a conversation"
  # has to be bounded by something explicit, or a single message months ago would
  # make the bot a permanent listener on every message in the channel.
  #
  # Threads are deliberately NOT bounded by this: a reply to a thread Zimmer is part
  # of is addressed to that conversation however old it is. Those are bounded by
  # RECHECK_HORIZON instead, via the tracked-thread re-check.
  CHANNEL_ENGAGEMENT_WINDOW = 6.hours

  # How far back passive listening may replay a thread it is meeting from a stale
  # baseline — one it has never seen, or one whose cursor fell behind across a gap.
  #
  # Deliberately its own constant rather than CHANNEL_ENGAGEMENT_WINDOW: this bounds
  # catch-up on a thread, which has nothing to do with how long a channel stays
  # engaged. Tying them together would silently re-tune catch-up behaviour every
  # time the channel window is adjusted — and "threads have no time limit" is the
  # property the thread condition exists to preserve. See #backfill_baseline.
  THREAD_BACKFILL_HORIZON = 24.hours

  # Message subtypes that are events about a channel rather than somebody talking
  # in it. They can carry a `user` and would otherwise look like a passive-listening
  # candidate — "Sam has joined the channel" is not a conversation continuing.
  PASSIVE_IGNORED_SUBTYPES = %w[
    channel_join channel_leave group_join group_leave
    channel_topic channel_purpose channel_name
    channel_archive channel_unarchive channel_posting_permissions
    bot_message bot_add bot_remove
    huddle_thread pinned_item reminder_add
    message_changed message_deleted tombstone
  ].freeze

  # Lightweight stand-in for a thread parent synthesized from a tracked
  # thread_timestamps key: we know the thread_ts but not its latest_reply or its
  # author, so both are nil — latest_reply being nil forces a direct replies fetch
  # in the checking loop.
  RecheckThreadParent = Struct.new(:ts, :latest_reply, :user)

  # How much of a folded message's text to quote in the surviving session's
  # prompt. Enough to tell one alert from another; the link beside it is what a
  # session follows to read the whole thing.
  FOLDED_MESSAGE_EXCERPT = 200

  # How many folded messages the note lists individually. Past this it gives a
  # count: a burst of more than 25 messages inside one window is a story about the
  # burst, not about any one message in it, and 25 links is already more than
  # anyone reads. (Trigger::MAX_BURST_NOTICE_LINKS caps the burst notice for the
  # same reason.)
  MAX_FOLDED_MESSAGES_LISTED = 25

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
      rescue SlackService::TransientError
        # Slack itself is throttling us or unreachable. That is not a defect in
        # THIS condition, and every remaining condition is about to hit the same
        # wall — so don't alert once per condition and don't keep grinding through
        # the sweep. Abort it and let #perform defer the whole poll.
        raise
      rescue => e
        Rails.logger.error "[SlackTriggerPollerJob] Error processing condition #{condition.id}: #{e.message}"
        AlertService.raise_alert(
          "Slack trigger poller error",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) failed.",
          source: "SlackTriggerPollerJob",
          dedup_key: "slack_trigger_condition_#{condition.id}",
          error: e
        )
      end
    end

    defer_poll(@transient_error) if @transient_error
  rescue SlackService::TransientError => e
    defer_poll(e)
  end

  # How many times this run has already been deferred, carried across reschedules
  # in the job's own serialized params.
  #
  # Deliberately not `executions`, which counts every attempt including retries
  # this job knows nothing about — ApplicationJob retries ActiveRecord::StatementTimeout
  # five times, and GoodJob's concurrency module retries ConcurrencyExceededError.
  # Reading those as deferrals would inflate the backoff and make the give-up alert
  # claim a Slack outage that never happened.
  def serialize
    super.merge("deferrals" => deferral_count)
  end

  def deserialize(job_data)
    super
    @deferrals = job_data["deferrals"] || 0
  end

  private

  def deferral_count
    @deferrals || 0
  end

  # Remember that Slack itself failed somewhere in this sweep.
  #
  # Its callers — #note_unit_failure for the fetch-side rescues, #process_message
  # for the one past the point of no return — deliberately swallow, because each unit
  # (channel, thread, DM) owns a cursor that is only advanced for units that
  # finished — aborting the sweep outright would skip the batched cursor writes for
  # the units that already succeeded and replay them as duplicate sessions. So the
  # sweep runs to completion and does its bookkeeping, and the failure is answered
  # at the end with a deferral rather than a "success" the cron re-hammers 60
  # seconds later.
  def note_transient(error)
    @transient_error ||= error if error.is_a?(SlackService::TransientError)
  end

  # Record a failure in one unit of the sweep and log it at the severity it
  # actually deserves.
  #
  # For the rescues that own a UNIT — a channel, a thread, a DM — a
  # SlackService::TransientError means Slack threw the unit's fetch away before its
  # cursor moved, so #note_transient hands it to the deferral, the deferred poll
  # re-reads that unit, and nothing is lost. That is a recovery, not a failure, and
  # it must not log at ERROR: a single ERROR line trips the "any Zimmer ERROR →
  # critical" Grafana rule (see ApplicationJob), so a rate-limit burst pages a human
  # about an incident in which nothing broke. It happened twice; the log line was the
  # only artifact both times.
  #
  # That is a property of the CALL SITE, not of the error, so it is only true where a
  # cursor advances on success alone. #fetch_recent_history and #process_message both
  # keep their ERROR for exactly that reason — see the comments there — and this
  # method is not the right home for a rescue that resembles theirs.
  #
  # The 429 that IS worth paging for is the one that outlives its deferrals, and
  # #defer_poll logs that one at ERROR itself.
  #
  # Anything else is a real per-unit defect that the deferral cannot fix — a
  # renamed channel, a bad cursor, a bug in this file — and keeps its ERROR.
  def note_unit_failure(error, while_doing)
    note_transient(error)

    if error.is_a?(SlackService::TransientError)
      Rails.logger.warn "[SlackTriggerPollerJob] Slack unavailable while #{while_doing}: " \
                        "#{error.message} — deferring the poll rather than failing it"
    else
      Rails.logger.error "[SlackTriggerPollerJob] Error #{while_doing}: #{error.message}"
    end
  end

  # Slack is unavailable or throttling us. Give the slot back.
  #
  # Rescheduling THIS job (rather than returning, or sleeping it out) is what
  # makes the deferral honest. `retry_job` re-enqueues the same job_id, which
  # GoodJob's concurrency control lets through — and because the row stays
  # unfinished, the singleton key is still held, so the cron ticks in between are
  # still no-ops and the deferred run is the *next* poll rather than an extra one.
  # The worker thread, meanwhile, is free the whole time.
  #
  # After MAX_DEFERRALS we stop deferring and alert: at that point Slack has been
  # unavailable across roughly a quarter of an hour, which is worth a human
  # knowing about, and the ordinary once-a-minute cron takes over from a clean
  # slate.
  def defer_poll(error)
    spent = deferral_count
    if spent >= MAX_DEFERRALS
      # ERROR, and on this path it is the line that earns it. A single ERROR line
      # trips the "any Zimmer ERROR → critical" Grafana rule (see ApplicationJob),
      # which is correct here: the retry budget is spent, Slack has been unavailable
      # across roughly a quarter of an hour, and polling has genuinely stopped
      # recovering. The per-unit failures that led here logged at WARN precisely so
      # that this line still means something when it appears.
      #
      # It is louder than the alert beside it, and that is accepted rather than
      # overlooked. A give-up costs ~16 minutes (930s of backoff plus a tick) and the
      # next cron tick starts a fresh chain from zero, so a sustained outage reaches
      # here roughly four times an hour while AlertService::DEDUP_WINDOW suppresses
      # all but the first Slack message. Four ERROR lines an hour for an outage that
      # is genuinely ongoing is a fair price for not making the Grafana signal
      # conditional on the alert cache; do not demote this line back to WARN on the
      # grounds that the alert already covers it, which is the reasoning that let a
      # recovered 429 page in the first place (#509).
      Rails.logger.error "[SlackTriggerPollerJob] Slack still unavailable after #{MAX_DEFERRALS} deferrals: #{error.message}"
      AlertService.raise_alert(
        "Slack trigger poller deferred repeatedly",
        details: "Slack has been unavailable across #{MAX_DEFERRALS} deferred polls. Latest error:\n#{error.message}",
        source: "SlackTriggerPollerJob",
        dedup_key: "slack_trigger_poller_deferred"
      )
      return
    end

    wait = deferral_delay(error)
    Rails.logger.warn(
      "[SlackTriggerPollerJob] #{error.message} — deferring poll #{wait}s " \
      "(deferral #{spent + 1}/#{MAX_DEFERRALS})"
    )
    @deferrals = spent + 1
    retry_job(wait: wait)
  end

  # Exponential backoff, floored by whatever Slack itself asked for on a 429 and
  # capped so a deferral can never swallow more than MAX_DEFERRAL_DELAY of polling.
  def deferral_delay(error)
    backoff = DEFERRAL_BASE_DELAY * (2**deferral_count)
    retry_after = error.is_a?(SlackService::RateLimitedError) ? error.retry_after.to_i : 0
    [ [ backoff, retry_after ].max, MAX_DEFERRAL_DELAY ].min
  end

  def process_condition(condition)
    case condition.event_type
    when "bot_mention"
      process_bot_mention_condition(condition)
    when "dm_message"
      process_dm_message_condition(condition)
    when *TriggerCondition::PASSIVE_EVENT_TYPES
      process_passive_listen_condition(condition)
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

    # Process each message. Messages that landed within the trigger's coalescing
    # window of each other are one event and get one session — see
    # #coalesced_groups.
    process_messages(condition, messages, channel_id: channel_id)

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

  # Process a dm_message condition: every DM the bot receives from an allowed
  # user fires the trigger.
  #
  # This is the DM half of bot_mention on its own, and it exists because the two
  # were only ever available welded together. A trigger that should answer DMs and
  # nothing else had to be a bot_mention condition, which also fires on @mentions
  # in every channel the bot is in — so "let me DM Zimmer" cost you a trigger that
  # anyone could fire from any channel.
  #
  # No mention filter, deliberately: a DM to the bot is already addressed to it,
  # and requiring "@zimmer" inside a one-on-one conversation is a tax nobody
  # would pay twice. That does mean a dm_message condition and a bot_mention
  # condition watching the same conversation BOTH fire on it — pick one.
  def process_dm_message_condition(condition)
    process_dm_messages(condition, bot_id: SlackService.bot_user_id)

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
    return false unless mentions_bot?(message, bot_id)
    return false if message.user == bot_id

    condition.user_allowed?(message.user)
  end

  # The single notion of "this message @mentions Zimmer", shared by the bot_mention
  # filter and the passive-listening exclusion. They MUST agree: two different
  # notions would double-fire whatever fell between them, which is the exact bug the
  # exclusion exists to close.
  def mentions_bot?(message, bot_id)
    return false if bot_id.blank?

    message.text.to_s.include?("<@#{bot_id}>")
  end

  # Poll a single configured channel for @bot mentions from allowed users
  def process_channel_mentions(condition, bot_id:)
    all_messages = fetch_new_messages(condition.channel_id, condition.last_message_ts)

    if all_messages.any?
      # Filter to messages that mention the bot AND are from allowed users
      mentions = all_messages.select { |msg| mention_for?(condition, msg, bot_id) }

      process_messages(condition, mentions, channel_id: condition.channel_id)

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

        process_messages(condition, mentions, channel_id: channel.id, prior_ts: last_ts)

        # Collect timestamp update (written in batch below)
        updated_timestamps[channel.id] = all_messages.map { |m| m.ts }.max
      end

      # Check thread replies for @mentions (even when no new top-level messages,
      # since replies to old threads won't appear in conversations.history)
      check_thread_replies_for_mentions(condition, channel.id, all_messages, bot_id: bot_id)
    rescue => e
      note_unit_failure(e, "polling channel #{channel.id} for mentions")
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

    thread_parents.concat(aged_out_thread_parents(condition, channel_id, thread_parents))

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

      # Only process replies newer than our effective baseline.
      new_mention_replies = mention_replies.reject { |reply| reply.ts <= effective_prior_ts }

      process_messages(condition, new_mention_replies, channel_id: channel_id, prior_ts: effective_prior_ts)

      # Track the newest reply timestamp for this thread
      newest_reply_ts = replies.map { |r| r.ts }.max
      thread_ts_updates[thread_key] = newest_reply_ts
    rescue => e
      note_unit_failure(e, "checking thread #{parent.ts} in #{channel_id}")
    end

    # Batch-write thread timestamp updates
    if thread_ts_updates.any?
      new_thread_ts = condition.thread_timestamps.merge(thread_ts_updates)
      new_config = condition.configuration.merge("thread_timestamps" => new_thread_ts)
      condition.update!(configuration: new_config)
    end
  end

  # ── Passive listening ───────────────────────────────────────────────────────

  # Process a passive-listening condition: fire on messages that continue a
  # conversation Zimmer is already part of, with no @mention required.
  #
  # Which of the two signals runs is the condition's event type, so a Trigger can
  # carry one, the other, or both (its conditions are ORed):
  # - passive_listen_thread — a reply in a thread Zimmer has spoken in. Not bounded
  #   by age, beyond the RECHECK_HORIZON cap that already bounds how far back
  #   tracked threads get re-visited.
  # - passive_listen_channel — a top-level message in a channel Zimmer has POSTED in
  #   within CHANNEL_ENGAGEMENT_WINDOW. Posted at the top level, specifically: a
  #   reply Zimmer left inside a thread makes it party to that thread, not to
  #   everything else said in the channel.
  # - passive_listen — deprecated, both at once.
  #
  # Bookkeeping is bot_mention's: per-channel cursors in channel_timestamps, and —
  # for the conditions that walk threads — per-thread cursors in thread_timestamps.
  # Both advance for everything fetched whether or not it fired, so a quiet spell
  # never replays as a burst.
  def process_passive_listen_condition(condition)
    bot_id = SlackService.bot_user_id

    channel_ids = if condition.channel_id.present?
      [ condition.channel_id ]
    else
      SlackService.list_member_channels.map(&:id)
    end

    channel_ts_updates = {}
    bot_activity_updates = {}

    channel_ids.each do |channel_id|
      result = process_channel_passively(condition, channel_id, bot_id: bot_id)
      channel_ts_updates[channel_id] = result[:channel_ts] if result[:channel_ts].present?
      bot_activity_updates[channel_id] = result[:bot_activity_ts] if result[:bot_activity_ts].present?
    rescue => e
      note_unit_failure(e, "passively polling channel #{channel_id}")
    end

    # One write for both cursor hashes plus last_polled_at. condition.configuration
    # is re-read here so the thread bookkeeping written per-channel above survives.
    attrs = { last_polled_at: Time.current }
    if channel_ts_updates.any? || bot_activity_updates.any?
      attrs[:configuration] = condition.configuration.merge(
        "channel_timestamps" => condition.channel_timestamps.merge(channel_ts_updates),
        "bot_activity_timestamps" => condition.bot_activity_timestamps.merge(bot_activity_updates)
      )
    end
    condition.update!(attrs)
  end

  # Poll one channel passively.
  #
  # Returns { channel_ts:, bot_activity_ts: } — the newest top-level message seen
  # (the channel cursor to store) and the newest moment Zimmer is known to have
  # spoken in this channel, either of which may be nil.
  #
  # Note that a passive condition keys its cursor off channel_timestamps even when
  # a single channel is configured, where bot_mention would use last_message_ts.
  # One code path covers both shapes; the cost is that last_message_ts stays nil on
  # a passive condition, so read last_polled_at, not it, to tell whether one is live.
  def process_channel_passively(condition, channel_id, bot_id:)
    last_ts = condition.channel_timestamps[channel_id]
    new_messages = fetch_new_messages(channel_id, last_ts)

    # First poll for this channel only establishes the cursor — same baseline rule
    # every other Slack path follows, so enabling a passive condition never replays
    # history.
    return { channel_ts: new_messages.map(&:ts).max, bot_activity_ts: nil } if last_ts.blank?

    history = fetch_recent_history(channel_id)

    check_thread_replies_passively(condition, channel_id, history, bot_id: bot_id) if condition.passive_threads?

    # A thread-only condition is done here: it neither reads nor writes the
    # channel-engagement signal.
    return { channel_ts: new_messages.map(&:ts).max, bot_activity_ts: nil } unless condition.passive_channel?

    # Engagement is Zimmer's own TOP-LEVEL posts in the recent window, and only
    # those. A reply it left inside a thread makes it party to that thread — which
    # is what passive_listen_thread follows — not to everything else said in the
    # channel. That includes a reply broadcast back to the channel: conversations
    # .history returns those (thread_ts != ts), and they are still thread replies,
    # so they are filtered out here exactly as fetch_new_messages filters them out
    # of what may fire.
    channel_activity_ts = bot_top_level_posts(history, bot_id).map(&:ts).max if engagement_channel?(channel_id)

    # Engagement only ever moves forward. Taking the max with what is already on
    # record is what keeps a channel engaged for the full window once Zimmer's post
    # scrolls out of the recent-history window.
    bot_activity_ts = [ channel_activity_ts, condition.bot_activity_timestamps[channel_id] ].compact.max

    if channel_engaged?(bot_activity_ts)
      candidates = new_messages.select { |message| passive_candidate?(condition, message, bot_id) }

      process_messages(condition, candidates, channel_id: channel_id, prior_ts: last_ts)
    end

    { channel_ts: new_messages.map(&:ts).max, bot_activity_ts: bot_activity_ts }
  end

  # Zimmer's own top-level messages in a channel history slice — thread replies,
  # including ones broadcast back to the channel, excluded.
  def bot_top_level_posts(history, bot_id)
    history.select do |msg|
      msg.user == bot_id && (msg.thread_ts.blank? || msg.thread_ts == msg.ts)
    end
  end

  # Whether Zimmer has posted in a channel recently enough for that channel's
  # top-level messages to count as continuing a conversation it is part of.
  def channel_engaged?(bot_activity_ts)
    return false if bot_activity_ts.blank?

    bot_activity_ts.to_f >= CHANNEL_ENGAGEMENT_WINDOW.ago.to_f
  end

  # Whether Zimmer's own posts in this channel count as being in a conversation.
  #
  # They don't in the alert channel. AlertService posts there with the same token
  # and therefore the same user ID, so a single automated alert would otherwise mark
  # the channel engaged and turn the whole engagement window of it into a session
  # per message — in the one channel guaranteed to be noisy when things are going
  # wrong. Threads are unaffected: if Zimmer actually replied in a thread there,
  # that IS a conversation and passive_listen_thread still follows it.
  def engagement_channel?(channel_id)
    channel_id != alert_channel_id
  end

  def alert_channel_id
    return @alert_channel_id if defined?(@alert_channel_id)

    @alert_channel_id = AlertService.channel_id
  end

  # The oldest a reply may be and still fire, given the baseline passive listening
  # has for a thread.
  #
  # Two baselines reach here and both can be arbitrarily stale. First sight of a
  # thread falls back to the CHANNEL cursor, which tracks top-level messages — in a
  # channel whose conversation lives in threads that is weeks old. And a thread's
  # OWN cursor is only as fresh as its last re-check, which the recheck rotation
  # bounds per sweep but nothing bounds across a gap: a deploy, a long outage, or a
  # thread that was starved by the truncation #rotating_recheck_slice replaces can
  # all leave a cursor months behind. Firing on the whole gap would spawn a session
  # per accumulated reply, on messages nobody is waiting for an answer to any more.
  #
  # Clamping to THREAD_BACKFILL_HORIZON means meeting a thread late costs at most a
  # day of catch-up instead of the whole backlog, whichever way it was met. It
  # bounds the backfill only: a thread re-checked at the ordinary cadence sits far
  # inside the clamp, so replies in it fire however old the THREAD is.
  def backfill_baseline(baseline_ts)
    [ baseline_ts, format("%.6f", THREAD_BACKFILL_HORIZON.ago.to_f) ].max_by(&:to_f)
  end

  # Check this channel's threads for replies that continue a conversation Zimmer is
  # already in, and fire on them.
  #
  # Same thread selection, same cursors, same fetch shape (`oldest:` the thread's
  # cursor) and same recheck caps as check_thread_replies_for_mentions. What differs
  # is the filter: a reply fires when Zimmer participated in the thread rather than
  # when it was @mentioned.
  #
  # Participation is answered without ever re-reading a thread's history. First
  # sight of a thread has no cursor, so `oldest: nil` already returns the whole
  # thread — that read decides participation. From then on every reply Zimmer has
  # not already inspected is in the tail, and a thread it has spoken in is
  # remembered in participating_threads, so the tail alone is enough forever after.
  def check_thread_replies_passively(condition, channel_id, history, bot_id:)
    channel_baseline_ts = condition.channel_timestamps[channel_id]
    return if channel_baseline_ts.blank?

    thread_parents = history.select { |msg| msg.reply_count.to_i > 0 }
    thread_parents.concat(aged_out_thread_parents(condition, channel_id, thread_parents))

    known_participating = condition.participating_threads
    thread_ts_updates = {}
    participating_updates = []

    thread_parents.each do |parent|
      thread_key = "#{channel_id}:#{parent.ts}"
      last_reply_ts = condition.thread_timestamps[thread_key]

      # Skip threads with nothing new since the last check.
      latest_reply = parent.latest_reply
      next if latest_reply.present? && last_reply_ts.present? && latest_reply <= last_reply_ts

      replies = SlackService.get_thread_replies(channel_id, parent.ts, oldest: last_reply_ts)
      # Slack's oldest parameter is inclusive, so drop the already-seen reply.
      replies.reject! { |reply| reply.ts == last_reply_ts } if last_reply_ts.present?
      next if replies.empty?

      # Track the newest reply for this thread whether or not Zimmer is in it — the
      # same thing the @mention scan does. A thread it joins later then starts from
      # a real cursor instead of replaying everything said before it arrived.
      #
      # Unlike every other unit in this sweep, the cursor is recorded BEFORE the work
      # below it rather than after. What keeps the rescue's WARN honest is that
      # nothing between here and the end of this iteration can raise a Slack failure:
      # #process_message swallows its own. A new Slack call added below this line
      # would break that, and would lose the thread's replies under a WARN.
      thread_ts_updates[thread_key] = replies.map { |reply| reply.ts }.max

      participation_ts = replies.select { |reply| reply.user == bot_id }.map(&:ts).max
      participation_ts ||= parent.ts if parent.user == bot_id

      participating = participation_ts.present? || known_participating.include?(thread_key)
      participating_updates << thread_key if participation_ts.present?
      next unless participating

      # A thread with no cursor of its own falls back to the channel's. Either way
      # the baseline is clamped, because either way it can be arbitrarily stale —
      # see backfill_baseline.
      effective_prior_ts = backfill_baseline(last_reply_ts || channel_baseline_ts)

      candidates = replies.select do |reply|
        reply.ts > effective_prior_ts && passive_candidate?(condition, reply, bot_id)
      end

      process_messages(condition, candidates, channel_id: channel_id, prior_ts: effective_prior_ts)
    rescue => e
      note_unit_failure(e, "passively checking thread #{parent.ts} in #{channel_id}")
    end

    # Only threads that actually moved produce updates, so a channel of dormant
    # tracked threads costs no writes here. (A channel tracking more threads than
    # one poll's re-check budget still writes its rotation cursor — see
    # #advance_recheck_cursor! — which is one row update, not a per-thread one.)
    if thread_ts_updates.any?
      condition.update!(configuration: condition.configuration.merge(
        "thread_timestamps" => condition.thread_timestamps.merge(thread_ts_updates),
        "participating_threads" => known_participating | participating_updates
      ))
    end
  end

  # Whether a message may fire a passive_listen condition, given that the
  # conversation it belongs to already qualifies.
  #
  # No bot fires passively — not Zimmer, not anyone else's app. bot_mention accepts
  # other apps because an @mention is an explicit request; a passive listener firing
  # on every CI notification that lands in a thread it once replied to is precisely
  # the noise passive listening must not make. Messages with no user (legacy
  # webhooks) have no identity to check the allow-list against, and message
  # subtypes that aren't somebody talking — joins, topic changes, edits — never
  # count as a conversation continuing.
  #
  # An @mention never fires passively either, on EITHER passive event type. A
  # mention posted inside a thread Zimmer is in is both a mention and a reply in a
  # participated thread, and a mention in an engaged channel is both a mention and a
  # top-level message there — so without this, one Slack message spawned two
  # concurrent sessions on identical text, one per matching trigger. Mentions belong
  # to bot_mention, which exists to catch being addressed directly; the passive
  # types own everything else.
  #
  # The exclusion is unconditional, and does NOT check that some bot_mention
  # condition would in fact pick the message up — conditions are polled
  # independently, and one cannot see the others. So a deployment hears nothing when
  # @mentioned if it has no bot_mention condition, if its bot_mention condition is
  # disabled or scoped to a different channel, or if its allow-lists diverge (they
  # are per-condition). That is the intended division of labour rather than an
  # oversight — being addressed directly is what bot_mention is for — but it is a
  # silent drop, so it is logged.
  def passive_candidate?(condition, message, bot_id)
    return false if message.user.blank?
    return false if message.user == bot_id
    return false if message.bot_id.present?
    return false if PASSIVE_IGNORED_SUBTYPES.include?(message.subtype)

    if mentions_bot?(message, bot_id)
      Rails.logger.info "[SlackTriggerPollerJob] Message #{message.ts} mentions the bot — left to " \
                        "bot_mention rather than fired passively by condition #{condition.id}"
      return false
    end

    condition.user_allowed?(message.user)
  end

  # Tracked threads in this channel whose parent has aged out of the recent-history
  # window, as RecheckThreadParent stand-ins.
  #
  # fetch_recent_thread_parents only surfaces threads whose parent is among the last
  # RECENT_HISTORY_LIMIT top-level messages, so a long-lived thread — e.g. a
  # months-old digest thread that still receives daily replies — stops being visited
  # once its parent scrolls past that window, even though it remains tracked in
  # thread_timestamps. Without this, replies to such a thread are silently missed.
  #
  # Fan-out is one conversations.replies call per re-checked thread, so eligibility
  # is bounded first (the recent-window parents are already limited by
  # fetch_recent_thread_parents): drop threads with no tracked activity within
  # RECHECK_HORIZON, treated as dead, and drop threads the recent window already
  # covers, to avoid duplicate fetches. What survives is then spread across polls
  # by #rotating_recheck_slice rather than truncated — see there for why.
  def aged_out_thread_parents(condition, channel_id, covered_parents)
    already_covered = covered_parents.map(&:ts).to_set
    horizon_ts = RECHECK_HORIZON.ago.to_f

    eligible = condition.thread_timestamps.select do |key, last_reply_ts|
      key.start_with?("#{channel_id}:") &&
        !already_covered.include?(key.split(":", 2).last) &&
        last_reply_ts.to_f >= horizon_ts
    end

    rotating_recheck_slice(condition, channel_id, eligible)
      .map { |key| RecheckThreadParent.new(key.split(":", 2).last, nil, nil) }
  end

  # This poll's slice of the channel's eligible tracked threads, at most
  # MAX_TRACKED_THREAD_RECHECKS of them.
  #
  # Truncating the budget — keep the 20 most-recently-active and drop the rest,
  # every poll — is not available, however natural it looks. A live condition tracks
  # hundreds of threads across its channels, so truncation silently voids
  # RECHECK_HORIZON's promise for most of them, and self-reinforcingly: the ranking
  # is by tracked activity, and a reply nobody fetched never advances a tracked
  # timestamp, so a thread below the line has no way back above it (#518).
  #
  # Raising the budget is not available either: each of these threads costs a
  # conversations.replies call precisely because its synthesized parent has no
  # latest_reply to skip on, and no Slack call answers "did any of these 172 threads
  # move?" in one request. So the budget stays flat and the coverage rotates:
  #
  #   * HOT_TRACKED_THREAD_RECHECKS slots go to the most-recently-active threads,
  #     every poll, so a conversation that is live answers at the poll cadence;
  #   * the remaining slots walk the rest in a stable order, resuming where the
  #     last poll stopped and wrapping around.
  #
  # Every eligible thread is therefore visited within ceil(rest / rotating_slots)
  # polls — 17 minutes for 172 threads at the one-minute cadence — for the same
  # number of re-checked threads per poll. The wait is latency, not loss: a thread's
  # cursor is untouched while it waits its turn, so when its slot comes up `oldest:`
  # still points at the last reply Zimmer saw and every reply since is fetched.
  #
  # Ordering the rotation band by thread key rather than by activity is deliberate.
  # The cursor is a position in that order, so an order that reshuffles under it as
  # cursors advance could step over the same thread repeatedly. Resuming by VALUE
  # rather than by stored index is deliberate for the same reason: threads enter and
  # leave the band between polls, and a stored index would slide against them.
  def rotating_recheck_slice(condition, channel_id, eligible)
    return eligible.keys if eligible.size <= MAX_TRACKED_THREAD_RECHECKS

    # Tie-broken by key so that equal tracked timestamps cannot flip the hot/rest
    # split between polls and strand a thread on the seam.
    by_recency = eligible.sort_by { |key, last_reply_ts| [ -last_reply_ts.to_f, key ] }.map(&:first)
    # At least one rotating slot always survives the split. A hot band tuned up to
    # the whole budget is the truncation above under a new name.
    hot = by_recency.first([ HOT_TRACKED_THREAD_RECHECKS, MAX_TRACKED_THREAD_RECHECKS - 1 ].min)
    rest = by_recency.drop(hot.size).sort
    slots = MAX_TRACKED_THREAD_RECHECKS - hot.size

    cursor = condition.thread_recheck_cursors[channel_id]
    # rest is sorted, so the resume point is a binary search. A cursor at or past
    # the last key finds nothing and wraps to the start — one full sweep done.
    resume_at = (cursor.present? && rest.bsearch_index { |key| key > cursor }) || 0
    rotating = rest.rotate(resume_at).first(slots)

    advance_recheck_cursor!(condition, channel_id, rotating.last)

    if resume_at.zero?
      Rails.logger.info(
        "[SlackTriggerPollerJob] Condition #{condition.id} starts a re-check sweep of " \
        "#{eligible.size} aged-out threads in #{channel_id}, #{hot.size} most-recent + " \
        "#{rotating.size} rotating per poll (#{(rest.size.to_f / slots).ceil} polls per sweep)"
      )
    end

    hot + rotating
  end

  # Remember where the rotation stopped, so the next poll resumes after it.
  #
  # Written BEFORE the threads are actually re-checked, unlike every per-thread
  # cursor in this job. A failure part-way through the slice therefore costs those
  # threads their turn — but only their turn: their thread_timestamps entries are
  # untouched, so the next pass round the ring fetches from the same `oldest:` and
  # nothing is lost.
  #
  # update_column, not update!, and rescued: this runs OUTSIDE the callers' per-thread
  # rescue, so anything it raises would skip thread checking for the whole channel and
  # — on the single-channel bot_mention path, which has no unit rescue — alert. What is
  # at stake does not justify that. A cursor that fails to advance costs the rotation
  # one step, which the next poll simply repeats.
  def advance_recheck_cursor!(condition, channel_id, last_key)
    return if last_key.blank?

    condition.update_column(:configuration, condition.configuration.merge(
      "thread_recheck_cursors" => condition.thread_recheck_cursors.merge(channel_id => last_key)
    ))
  rescue => e
    note_unit_failure(e, "advancing the tracked-thread re-check cursor for #{channel_id}")
  end

  # Fetch recent thread parents from a channel to catch old threads with new replies.
  # Uses a small limit since we only need to find active threads.
  # Returns messages that have replies (reply_count > 0).
  def fetch_recent_thread_parents(channel_id)
    fetch_recent_history(channel_id).select { |msg| msg.reply_count.to_i > 0 }
  end

  # The channel's last RECENT_HISTORY_LIMIT top-level messages. Passive listening
  # needs the raw history (not just the thread parents) to see whether Zimmer has
  # posted in the channel recently.
  #
  # Deliberately NOT #note_unit_failure, even for a transient failure: this is not a
  # unit boundary. It degrades to [] and its callers carry on in the SAME sweep with
  # a history slice they believe is complete, then advance their cursors past
  # messages the empty slice made invisible — a passive channel that looks unengaged
  # because Zimmer's own post was in the lost slice, or a mention in a thread whose
  # parent was only discoverable there. Those messages are gone, not deferred, so
  # this keeps its ERROR.
  def fetch_recent_history(channel_id)
    SlackService.get_channel_history(channel_id, limit: RECENT_HISTORY_LIMIT)
  rescue => e
    note_transient(e)
    Rails.logger.error "[SlackTriggerPollerJob] Error fetching recent history for #{channel_id}: #{e.message}"
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
    dm_channels = dm_channels_for(user_ids)

    # Never poll a DM with ourselves (the unrestricted path lists every IM there is).
    dm_channels = dm_channels.reject { |dm_channel| dm_channel.user == bot_id }

    dm_channels.each do |dm_channel|
      user_id = dm_channel.user
      last_ts = condition.dm_timestamps[user_id]

      messages = fetch_new_messages(dm_channel.id, last_ts)
      next if messages.empty?

      # Filter to only messages from the allowed user (not the bot's own messages)
      user_messages = messages.select { |msg| msg.user == user_id }

      process_messages(condition, user_messages, channel_id: dm_channel.id, dm: true)

      # Advance DM timestamp for this user
      newest_ts = messages.map { |m| m.ts }.max
      condition.update_dm_timestamp!(user_id, newest_ts)
    rescue => e
      note_unit_failure(e, "polling DMs for user #{user_id}")
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

  # Hand a channel's (or thread's, or DM's) new messages to #process_message,
  # one call per EVENT rather than one per message.
  #
  # Every caller in this job has the same shape — take the messages this pass
  # found in one conversation, filter them to the ones this condition may fire
  # on, spawn a session for each — and every one of them used to fan out: seven
  # `#alerts` messages from a single `bulk_archive` on 2026-08-29 became seven
  # router sessions in nine seconds, six of which archived within three minutes
  # having worked out they were duplicates (tadasant/tadasant-internal#1857).
  #
  # The messages fed to one call are already scoped to a single conversation by
  # the caller, which is what makes the group's identity meaningful: a burst is
  # "several messages, one channel, close together", and messages in two channels
  # are never each other's duplicates however close together they land.
  def process_messages(condition, messages, channel_id:, dm: false, prior_ts: nil)
    coalesced_groups(condition.trigger, messages).each do |group|
      process_message(
        condition, group.first,
        channel_id: channel_id, dm: dm, prior_ts: prior_ts, folded: group.drop(1)
      )
    end
  end

  # Partition messages into groups that each count as ONE event.
  #
  # Two messages are the same event when they share a conversation (the caller's
  # doing), an AUTHOR, and a window. All three narrow the key deliberately, since
  # the failure that does not announce itself is a genuinely distinct alert
  # swallowed by a group.
  #
  # Author, because a burst is one producer repeating itself. Seven alerts from
  # one app are one event; two people @mentioning Zimmer twenty seconds apart are
  # two requests, and folding the second into the first would render the prompt
  # from the first person's words and leave the second as a quoted excerpt in a
  # note their trigger's template never anticipated.
  #
  # A group is anchored on its first message and spans at most the window: each
  # message joins its author's open group when it landed within `window` seconds
  # of the message that OPENED that group, and opens a new one otherwise.
  # Anchoring rather than chaining off the previous message is what bounds a
  # group — a channel posting steadily just inside the window would otherwise
  # chain into one unbounded group that swallows an hour of unrelated alerts.
  #
  # With a window of 0 (Trigger#coalesce_window_seconds set to 0) every message
  # is its own group, which is the behaviour before coalescing existed.
  #
  # Ordered oldest-first, so the message that opens a group is the FIRST of the
  # burst — the one the router should treat as the head of the thread, and the
  # one whose author and link the prompt is built from.
  def coalesced_groups(trigger, messages)
    ordered = messages.sort_by { |message| message.ts.to_s.to_f }
    window = trigger.effective_coalesce_window_seconds
    return ordered.map { |message| [ message ] } unless window.positive?

    open_groups = {}

    ordered.each_with_object([]) do |message, groups|
      author = coalescing_author_key(message)
      open_group = open_groups[author] if author.present?

      if open_group && (message.ts.to_s.to_f - open_group.first.ts.to_s.to_f) <= window
        open_group << message
      else
        group = [ message ]
        open_groups[author] = group if author.present?
        groups << group
      end
    end
  end

  # Who Slack says posted a message, for the purpose of deciding whether two
  # messages are the same producer repeating itself.
  #
  # `user` for a human and for an app posting with a bot token; `bot_id` for an
  # app that posts without one (a webhook integration), which is what makes an
  # alerting app's own burst coalesce; `username` last, for a message carrying
  # nothing else.
  #
  # A message with none of the three is never coalesced — it opens a group and
  # nothing joins it. No identity is no evidence that two messages share a
  # producer, and the safe direction is a session too many rather than an alert
  # nothing answers.
  def coalescing_author_key(message)
    message.user.presence || message.bot_id.presence || message.username.presence
  end

  # The block appended to a coalesced session's prompt, naming the messages that
  # were folded into it.
  #
  # Folding is not dropping, and this is the whole difference. The session that
  # survives a burst is told about the messages it stands in for, with their
  # links, so an operator reading it sees the same set of events N sessions would
  # have seen between them — no message is silently swallowed by the window.
  #
  # `permalinks` is passed in rather than resolved here: the caller needs the same
  # links for the human-message records, and each one costs a Slack API call.
  def folded_messages_note(folded, permalinks:, channel_name:, window:)
    listed = folded.first(MAX_FOLDED_MESSAGES_LISTED)

    lines = listed.map do |message|
      link = permalinks[message]
      author = get_author_name(message)
      excerpt = message.text.to_s.gsub(/\s+/, " ").strip.truncate(FOLDED_MESSAGE_EXCERPT)
      at = slack_ts_to_time(message.ts).utc.strftime("%H:%M:%S UTC")

      "- #{at} — #{author}: #{excerpt.presence || '(no text)'}#{link.present? ? " — #{link}" : ''}"
    end

    # A burst bigger than the cap is itself the news, so say the number rather
    # than quietly listing the first few. The unlisted ones are still recorded
    # against this session as human messages.
    if folded.length > listed.length
      lines << "- ...and #{folded.length - listed.length} more, not listed individually — read the channel."
    end

    <<~NOTE.strip
      ---

      #{folded.length} more message#{'s' if folded.length != 1} landed in #{channel_name} within #{window}s of the one above, so
      Zimmer folded them into this session rather than starting one session each. Treat them as part
      of the same event and read all of them before deciding what to do — the first message is not
      necessarily the whole story:

      #{lines.join("\n")}
    NOTE
  end

  def process_message(condition, message, channel_id:, dm: false, prior_ts: nil, folded: [])
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
    permalink = get_message_permalink(channel_id, message.ts)
    author_name = get_author_name(message)
    message_text = message.text || ""

    channel_name = dm ? "DM" : (condition.channel_name.presence || resolve_channel_name(channel_id))

    prompt = trigger.interpolate_prompt(
      link: permalink,
      text: message_text,
      author: author_name,
      channel: channel_name
    )

    # The messages this one is standing in for. Appended AFTER interpolation, not
    # through a template variable: a trigger's template is written by whoever
    # configured it and cannot be expected to mention a burst, and the one thing
    # that must never happen is a folded message going unmentioned.
    # Resolved once, here, because the same links are wanted twice: in the note
    # below and on the human-message records further down. Only the ones the note
    # will list are resolved — past that cap the note gives a count instead, and a
    # link per message would be a Slack API call per message for text nobody
    # reads.
    folded_permalinks = folded.first(MAX_FOLDED_MESSAGES_LISTED).index_with do |folded_message|
      get_message_permalink(channel_id, folded_message.ts)
    end

    if folded.any?
      prompt = [
        prompt,
        folded_messages_note(
          folded,
          permalinks: folded_permalinks,
          channel_name: dm ? "this DM" : "##{channel_name}",
          window: trigger.effective_coalesce_window_seconds
        )
      ].join("\n\n")
    end

    session = nil

    # The spawn and the record commit together.
    #
    # Trigger#create_session! enqueues the agent job itself, and GoodJob's queue
    # is this same database — so without the transaction a worker could claim
    # the job and build the session's first prompt before the human's message
    # existed to be injected into it. That would drop the human's own words from
    # the one channel where a genuinely named human is the author. Every web-UI
    # path already records before it enqueues; this makes Slack agree.
    #
    # HumanMessageCapture takes its own savepoint and swallows its own errors,
    # so a capture failure still cannot take the spawn down with it.
    ActiveRecord::Base.transaction do
      session = trigger.create_session!(prompt: prompt)

      if session
        # We record the human's OWN words (message_text), never the rendered
        # prompt: `prompt` is the trigger's prompt_template with the message
        # interpolated into it, and the template is written by whoever
        # configured the trigger, not by the person who just spoke. Recording
        # the rendered text would attribute machine-written instructions to a
        # human.
        #
        # Resolution goes through the Slack user ID map, so a message from an
        # allow-listed account that maps to no configured human records nothing
        # — `user_allowed?` says "may fire this trigger", which is not the same
        # claim as "is Tadas or Julie".
        #
        # A folded message gets its own record against the same session, for the
        # same reason its link is in the prompt: coalescing decides how many
        # SESSIONS a burst produces, and it must not decide whose words are on
        # the record. Without this, the second and later messages of a burst
        # would lose their human author entirely.
        ([ message ] + folded).each do |captured|
          HumanMessageCapture.record_slack_message(
            session: session,
            slack_user_id: captured.user,
            content: captured.text.to_s,
            entry_point: dm ? "slack.dm" : "slack.channel_message",
            slack_channel: channel_name,
            slack_permalink: captured.equal?(message) ? permalink : folded_permalinks[captured],
            occurred_at: slack_ts_to_time(captured.ts)
          )
        end
      end
    end

    # Burst control can suppress the spawn (see Trigger::BURST_WINDOW). The
    # message is then DROPPED, not retried: the caller advances the condition's
    # cursor to the newest message it fetched regardless of what each message
    # produced, which is exactly what we want here — replaying a burst once it
    # subsides would spawn the very sessions the cap exists to prevent.
    #
    # `skip_if_pending_session` drops the message the same way and for the same
    # reason: a session this trigger already spawned is still queued, so the
    # message it would have spawned a second session for is covered by that one.
    if session.nil?
      reason = trigger.last_fire_skipped_for_pending_session? ? "session #{trigger.last_fire_pending_session.id} is still pending" : "burst-suppressed"
      Rails.logger.info "[SlackTriggerPollerJob] Trigger #{trigger.id} spawned nothing for message #{message.ts}#{" (+#{folded.length} coalesced)" if folded.any?} (#{reason}) — dropping it"
      return
    end

    # Update condition's last_triggered_at
    condition.update!(last_triggered_at: Time.current)

    coalesced = folded.any? ? " (coalescing #{folded.length} further message(s) that landed within #{trigger.effective_coalesce_window_seconds}s)" : ""
    Rails.logger.info "[SlackTriggerPollerJob] Created session #{session.id} for trigger #{trigger.id} from #{dm ? 'DM' : 'channel'} message #{message.ts}#{coalesced}"
  # Deliberately NOT #note_unit_failure: this rescue keeps its ERROR even for a
  # transient Slack failure, because unlike the fetch-side rescues it is past the
  # point of no return. Every caller advances its cursor to the newest message it
  # fetched whether or not a session came out of each one, so a failure here loses
  # THIS message — and, on a coalesced fire, every message folded into it, since
  # the group is one call. The deferral re-polls from a cursor already sitting
  # past them. A dropped human message is exactly what the pager is for.
  rescue => e
    note_transient(e)
    Rails.logger.error "[SlackTriggerPollerJob] Failed to create session for message #{message.ts}: #{e.message}"
  end

  # A Slack `ts` is an epoch-seconds string with a microsecond suffix
  # ("1717171717.123456"). Falls back to now when it is missing or unparseable —
  # a slightly-off timestamp on a real human message beats dropping the event.
  def slack_ts_to_time(ts)
    seconds = ts.to_s.to_f
    return Time.current if seconds <= 0

    Time.zone.at(seconds)
  end

  # The message's Slack link, or nil when Slack won't give us one.
  #
  # Degrading rather than raising, for the same reason #get_author_name and
  # #resolve_channel_name do: every caller of #process_message advances its cursor
  # past this message whether or not a session came out of it, so an exception
  # escaping here does not defer the message — it deletes it. A prompt missing its
  # link is a worse prompt; a trigger that silently never fires is a lost message.
  def get_message_permalink(channel_id, message_ts)
    SlackService.get_message_permalink(channel_id, message_ts)
  rescue SlackService::SlackError => e
    Rails.logger.warn "[SlackTriggerPollerJob] No permalink for #{message_ts} in #{channel_id}: #{e.message}"
    nil
  end

  # The DM conversation list for one allow-list, memoized for this poll.
  #
  # `list_dm_channels` paginates every IM the bot has and filters client-side, so
  # it is the most expensive call on the DM path — and now two condition types
  # reach it (bot_mention and dm_message). A deployment that keeps its
  # bot_mention condition and adds a dm_message one would otherwise walk the same
  # pages twice a minute, on a singleton poller where one 429 defers polling for
  # every trigger in the instance.
  #
  # Keyed on the allow-list, since that is what the result depends on. nil (every
  # DM) and an explicit list are different queries and must not share an entry —
  # hence the array key rather than a `.to_a` that would collapse nil into [].
  def dm_channels_for(user_ids)
    @dm_channel_cache ||= {}
    key = user_ids.nil? ? :all : user_ids.sort
    @dm_channel_cache[key] ||= SlackService.list_dm_channels(user_ids: user_ids)
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

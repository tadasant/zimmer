# frozen_string_literal: true

# Fires Slack triggers from one Events API delivery.
#
# Webhooks::SlackController verifies the delivery, records it under its `event_id` and enqueues
# this with the event. From here on it is the poller's job with detection swapped out: the same
# conditions, the same predicates (SlackTriggerFiring), the same Trigger#create_session!.
#
# Which conditions it serves. Every enabled `slack` condition whose event type is in
# SERVED_EVENT_TYPES — new_message (channel or thread), bot_mention (one channel, every channel
# the bot is in, one thread, and DMs) and dm_message. Passive listening is not served: whether a
# reply continues a conversation Zimmer is in depends on participation state
# (participating_threads, bot_activity_timestamps) that only the poller learns, so those
# conditions stay on the poller however Slack is configured.
#
# What it does not do is move a condition's cursor. In webhook_with_poll_fallback mode the
# poller owns the cursors; advancing one past a message the webhook saw would hide from the
# poller any earlier message the webhook missed, and catching those is what the fallback is for.
#
# Coalescing. The poller folds a burst it finds in one pass into one session. The webhook sees
# the same burst one message per delivery, so the first message spawns at once and each later
# one — same conversation, same author, inside the trigger's window of the first — is folded
# into that session as a queued message (see #fold_into_session). One session per burst either
# way, and every message reaches it.
class SlackEventJob < ApplicationJob
  include SlackTriggerFiring

  # Latency-sensitive trigger firing, which is what the `triggers` lane is for: AoEventTriggerJob
  # and ScheduleTriggerJob live there too, isolated from `default`'s periodic backlog and from the
  # singleton poller on `pollers`.
  queue_as :triggers

  # `message` only. Slack also sends `app_mention` for an @mention, but it carries no
  # channel_type, so a mention in a group DM — which the poller never reads — would look like one
  # in a channel. Every mention also arrives as a `message` event, which does carry it, so an
  # app_mention delivery is acknowledged and ignored.
  EVENT_TYPES = %w[message].freeze

  SERVED_EVENT_TYPES = %w[new_message bot_mention dm_message].freeze

  # Subtypes that are events ABOUT an existing message rather than a new one. conversations.history
  # never returns them as new messages, so the poller never fires on them, and neither does this.
  IGNORED_SUBTYPES = %w[message_changed message_deleted message_replied].freeze

  # What is kept of a delivery's event when it is handed to this job: the fields a Slack message
  # needs to be matched and rendered, and nothing else (blocks, attachments and files can run to
  # kilobytes and nothing here reads them).
  EVENT_FIELDS = %w[type subtype channel channel_type user bot_id username text ts thread_ts hidden].freeze

  Message = Struct.new(
    :ts, :text, :user, :bot_id, :username, :thread_ts, :subtype, :bot_profile, :channel, :channel_type,
    keyword_init: true
  )
  BotProfile = Struct.new(:name)

  def self.event_arguments(event)
    slim = event.slice(*EVENT_FIELDS)
    bot_name = event["bot_profile"].is_a?(Hash) ? event["bot_profile"]["name"] : nil
    slim["bot_profile"] = { "name" => bot_name.to_s } if bot_name.present?
    slim
  end

  def perform(event_id, event)
    # Switched back to `poll` between accepting this and running it: the poller owns every
    # message again and has not claimed any of them, so firing here could double-fire.
    return unless Webhooks::Source.slack.webhook_enabled?
    return unless SlackService.configured?

    message = slack_message(event)
    return if message.nil?

    bot_id = SlackService.bot_user_id

    served_conditions.each do |condition|
      next unless webhook_match?(condition, message, bot_id)

      deliver(condition, message)
    rescue => e
      # WARN, not ERROR: the transaction rolled the claim back with the failed fire, so the poller
      # still owns this message and fires it on its next pass. Nothing is lost that paging a human
      # would recover. GlitchTip still gets the exception.
      Rails.logger.warn "[SlackEventJob] Could not fire condition #{condition.id} for Slack event #{event_id} " \
                        "(message #{message.ts} in #{message.channel}): #{e.class}: #{e.message} — leaving it to the poller"
      ErrorReporter.report_exception(
        e,
        level: :warning,
        context: {
          title: "Slack webhook trigger fire failed",
          source: "SlackEventJob",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) " \
                   "failed on Slack event #{event_id}. The poller is the backstop for this message.",
          condition_id: condition.id,
          trigger_id: condition.trigger_id
        }
      )
    end
  end

  private

  # A message event, or nil for anything this job does not fire on. A message with no
  # channel_type is not guessed at: which condition shapes it could match depends on it.
  def slack_message(event)
    return nil unless event.is_a?(Hash)
    return nil unless EVENT_TYPES.include?(event["type"])
    return nil if event["hidden"] || IGNORED_SUBTYPES.include?(event["subtype"])
    return nil if event["channel"].blank? || event["ts"].blank? || event["channel_type"].blank?

    bot_name = event.dig("bot_profile", "name")

    Message.new(
      ts: event["ts"].to_s,
      text: event["text"],
      user: event["user"].presence,
      bot_id: event["bot_id"].presence,
      username: event["username"].presence,
      thread_ts: event["thread_ts"].presence&.to_s,
      subtype: event["subtype"].presence,
      bot_profile: (BotProfile.new(bot_name) if bot_name.present?),
      channel: event["channel"].to_s,
      channel_type: event["channel_type"].to_s
    )
  end

  def served_conditions
    TriggerCondition.slack
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger)
      .select { |condition| SERVED_EVENT_TYPES.include?(condition.event_type) }
  end

  # Whether +condition+ would fire on +message+ if the poller had found it. Each branch is the
  # poller's filter for the same condition shape — see the SlackTriggerPollerJob method named
  # beside it.
  def webhook_match?(condition, message, bot_id)
    case condition.event_type
    when "new_message"
      # #process_new_message_condition: top-level messages in the channel, or every reply in the
      # one thread a thread-scoped condition names. Bots included, as the poller includes them.
      return false unless message.channel == condition.channel_id

      condition.thread_scoped? ? in_thread?(message, condition.thread_ts) : !slack_reply?(message)
    when "bot_mention"
      if condition.thread_scoped?
        # #process_thread_mentions: mentions in that one thread, nothing else.
        message.channel == condition.channel_id &&
          in_thread?(message, condition.thread_ts) &&
          mention_for?(condition, message, bot_id)
      elsif direct_message?(message)
        # #process_dm_messages: any DM from an allowed user, no mention required.
        dm_from_allowed_user?(condition, message, bot_id)
      else
        # #process_channel_mentions / #process_all_channel_mentions and their thread-reply
        # checks: a mention in the configured channel, or in any channel the bot is in (which is
        # every channel Slack delivers from) when none is configured.
        channel_message?(message) &&
          (condition.channel_id.blank? || message.channel == condition.channel_id) &&
          mention_for?(condition, message, bot_id)
      end
    when "dm_message"
      # #process_dm_message_condition.
      direct_message?(message) && dm_from_allowed_user?(condition, message, bot_id)
    else
      false
    end
  end

  def in_thread?(message, thread_ts)
    slack_reply?(message) && message.thread_ts == thread_ts
  end

  def direct_message?(message)
    message.channel_type == "im"
  end

  # Public and private channels — what SlackService.list_member_channels enumerates for the
  # poller. Group DMs (mpim) are neither, and the poller never reads them.
  def channel_message?(message)
    %w[channel group].include?(message.channel_type)
  end

  # The poller reads a DM's top-level history and keeps the messages the other party wrote.
  def dm_from_allowed_user?(condition, message, bot_id)
    !slack_reply?(message) &&
      message.user.present? &&
      message.user != bot_id &&
      condition.user_allowed?(message.user)
  end

  # Fire +condition+ for +message+, or fold it into the session its burst already started.
  #
  # Every Slack API call this needs — the permalink, the author's name, the channel's — is made
  # here, before the transaction, so a rate-limited Slack holds no transaction, no pooled
  # connection and no lock while it retries.
  #
  # Inside, the trigger's spawn lock comes first (Trigger.lock_spawn_for_transaction!). The
  # `triggers` queue runs several of these at once, and the lock makes each fire of one trigger
  # see what the previous one committed: a burst's second message finds the first one's session
  # to fold into, and skip_if_pending_session sees a session another delivery just spawned.
  def deliver(condition, message)
    trigger = condition.trigger
    window = trigger.effective_coalesce_window_seconds
    group_key = coalescing_group_key(message, message.channel) if window.positive?
    dm = direct_message?(message)

    rendered = render_slack_fire(condition, [ message ], channel_id: message.channel, dm: dm)
    fold_note = if group_key
      folded_messages_note(
        [ message ],
        trigger: trigger,
        permalinks: { message => rendered.head_permalink },
        channel_name: dm ? "this DM" : "##{rendered.channel_name}",
        window: window,
        follow_up: true
      )
    end

    ActiveRecord::Base.transaction do
      Trigger.lock_spawn_for_transaction!(trigger.id)

      if group_key
        group = TriggerEventClaim.open_group(condition, group_key, message.ts, window)
        target = Session.find_by(id: group.session_id) if group

        if target && foldable?(target)
          fold_into_session(condition, message, group: group, session: target, dm: dm, rendered: rendered, note: fold_note)
          next
        end
      end

      fire_slack_event(condition, message, channel_id: message.channel, dm: dm, via: "webhook", rendered: rendered)
    end
  end

  # A session that has ended cannot take the message, so the message opens a group of its own
  # instead of vanishing into a queue nothing will drain.
  def foldable?(session)
    !session.archived? && !session.failed?
  end

  # Queue +message+ into +session+ as a note naming it, the way the poller names a folded message
  # in the first prompt.
  #
  # A queued message rather than an edit to the prompt: the session may already be running, and
  # the queue is the one sanctioned way to hand it something new. It drains at the next turn
  # boundary, or at once if the session is idle, and Sessions::ArchiveGuard refuses to archive a
  # session over a message still in it — so the session cannot finish without reading this.
  def fold_into_session(condition, message, group:, session:, dm:, rendered:, note:)
    won = TriggerEventClaim.claim!(
      condition, [ TriggerEventClaim.slack_event_key(message.channel, message.ts) ],
      via: "webhook", group_key: group.group_key, anchor_ts: group.anchor_ts, session_id: session.id
    )
    # A redelivery, or a message the poller already fired.
    return if won.empty?

    session.lock!
    session.enqueued_messages.create!(
      content: note,
      position: (session.enqueued_messages.maximum(:position) || 0) + 1,
      status: "pending"
    )

    HumanMessageCapture.record_slack_message(
      session: session,
      slack_user_id: message.user,
      content: message.text.to_s,
      entry_point: dm ? "slack.dm" : "slack.channel_message",
      slack_channel: rendered.channel_name,
      slack_permalink: rendered.head_permalink,
      occurred_at: slack_ts_to_time(message.ts)
    )

    Rails.logger.info "[SlackEventJob] Folded message #{message.ts} into session #{session.id} for trigger " \
                      "#{condition.trigger_id}: same author as the message that opened the group at #{group.anchor_ts}, " \
                      "within #{rendered_window(condition)}s"
  end

  def rendered_window(condition)
    condition.trigger.effective_coalesce_window_seconds
  end
end

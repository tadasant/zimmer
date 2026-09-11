# frozen_string_literal: true

# How a Slack message becomes a session, shared by the two paths that can find one:
# SlackTriggerPollerJob, which polls for it, and SlackEventJob, which runs when Slack's Events API
# delivers it (see Webhooks::SlackController).
#
# Detection differs between them. Firing must not. Both use one notion of "this message
# @mentions Zimmer", one coalescing rule, one prompt and one call into Trigger#create_session!,
# so a session a webhook fired is indistinguishable from one the poller fired — including
# whatever Trigger#interpolate_prompt and #create_session! do to the untrusted text on the way.
#
# Log lines are tagged with the including class's name.
module SlackTriggerFiring
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

  # One fire, rendered: the prompt, and the permalinks the human-message records reuse.
  RenderedFire = Struct.new(:prompt, :head, :folded, :head_permalink, :folded_permalinks, :channel_name, keyword_init: true) do
    def messages
      [ head ] + folded
    end

    def permalink_for(message)
      message.equal?(head) ? head_permalink : folded_permalinks[message]
    end
  end

  private

  def slack_log_tag
    "[#{self.class.name}]"
  end

  # Whether a message is an @mention of the bot that this condition may fire on.
  #
  # The bot's OWN messages never qualify, whatever the allow-list says. Zimmer posts
  # to Slack with this same token, and a bot_mention condition with no
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

  # Whether a message is a reply inside a thread rather than a top-level message. A reply
  # broadcast back to the channel is still a reply: its thread_ts names the parent.
  def slack_reply?(message)
    message.thread_ts.present? && message.thread_ts != message.ts
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

  # The key a coalescing group is filed under in TriggerEventClaim: conversation plus author,
  # the same two things #coalesced_groups groups by (the window is the third, and it is
  # measured from the stored anchor). A conversation is the channel for a top-level message and
  # the thread for a reply, because the poller hands those to the grouper separately. nil for a
  # message with no author, which is never coalesced.
  def coalescing_group_key(message, channel_id)
    author = coalescing_author_key(message)
    return nil if author.blank?

    conversation = slack_reply?(message) ? "#{channel_id}:#{message.thread_ts}" : channel_id
    "slack:#{conversation}:#{author}"
  end

  # The block naming the messages folded into a coalesced session.
  #
  # Folding is not dropping, and this is the whole difference. The session that
  # survives a burst is told about the messages it stands in for, with their
  # links, so an operator reading it sees the same set of events N sessions would
  # have seen between them — no message is silently swallowed by the window.
  #
  # Appended to the first prompt when the poller finds a burst in one pass. With
  # `follow_up: true` it is instead a message of its own, queued into a session the
  # burst already started — how the webhook folds a burst that arrives one message
  # per delivery (see SlackEventJob#fold_into_session).
  #
  # `permalinks` is passed in rather than resolved here: the caller needs the same
  # links for the human-message records, and each one costs a Slack API call.
  def folded_messages_note(folded, permalinks:, channel_name:, window:, follow_up: false)
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

    if follow_up
      return <<~NOTE.strip
        Another message landed in #{channel_name} within #{window}s of the one this session was started for, from the
        same author, so Zimmer folded it into this session rather than starting another. Treat it as part of the same
        event — the first message is not necessarily the whole story:

        #{lines.join("\n")}
      NOTE
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

  # Fire +condition+'s trigger for +message+ and the messages folded into it, and return the
  # session, or nil when nothing was spawned.
  #
  # +via+ is "poll" or "webhook". A webhook fire always claims its messages in
  # TriggerEventClaim; a poll fire claims them only while the webhook path is switched on,
  # so with Slack on `poll` the poller claims nothing and takes no lock. The claim happens in
  # the same transaction as the spawn, so a message the other path already fired is not fired
  # again, and a fire that raises releases its claim with its rollback.
  #
  # +rendered+ is a fire the caller already rendered (SlackEventJob does, before opening its own
  # transaction). Without one it is rendered here, still before the transaction.
  #
  # Raises whatever the spawn raises; the caller decides what a failure costs.
  def fire_slack_event(condition, message, channel_id:, dm:, via:, folded: [], rendered: nil)
    trigger = condition.trigger
    candidates = [ message ] + folded
    claiming = via == "webhook" || Webhooks::Source.slack.webhook_enabled?

    # Rendered before the transaction: it makes Slack API calls (permalinks, author names), and
    # those should not hold a transaction open.
    rendered ||= render_slack_fire(condition, candidates, channel_id: channel_id, dm: dm)
    session = nil
    fired = candidates

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
      if claiming
        # With both paths live, fires of one trigger can run at once: SlackEventJob runs several,
        # and the poller runs beside them. A fire inside a transaction gets no lock from
        # Trigger.with_spawn_lock, so it takes the transaction-scoped one — see
        # Trigger.lock_spawn_for_transaction!. Re-taking it inside a caller that already holds it
        # is a no-op.
        Trigger.lock_spawn_for_transaction!(trigger.id)

        keys = candidates.index_with { |candidate| TriggerEventClaim.slack_event_key(channel_id, candidate.ts) }
        won = TriggerEventClaim.claim!(
          condition, keys.values,
          via: via, group_key: coalescing_group_key(message, channel_id), anchor_ts: message.ts
        )
        fired = candidates.select { |candidate| won.include?(keys[candidate]) }

        # Lost part of the group to the other path mid-flight: fire for what this path owns, so
        # nothing the other path already answered is announced twice. Every link and name it
        # needs was resolved by the first render and is memoized, so this makes no Slack call.
        if fired.any? && fired.size != candidates.size
          rendered = render_slack_fire(condition, fired, channel_id: channel_id, dm: dm)
        end
      end

      if fired.any?
        session = trigger.create_session!(prompt: rendered.prompt)

        if session
          # We record the human's OWN words, never the rendered prompt: `prompt`
          # is the trigger's prompt_template with the message interpolated into
          # it, and the template is written by whoever configured the trigger,
          # not by the person who just spoke. Recording the rendered text would
          # attribute machine-written instructions to a human.
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
          rendered.messages.each do |captured|
            HumanMessageCapture.record_slack_message(
              session: session,
              slack_user_id: captured.user,
              content: captured.text.to_s,
              entry_point: dm ? "slack.dm" : "slack.channel_message",
              slack_channel: rendered.channel_name,
              slack_permalink: rendered.permalink_for(captured),
              occurred_at: slack_ts_to_time(captured.ts)
            )
          end

          if claiming
            TriggerEventClaim.attach_session!(
              condition, fired.map { |fired_message| TriggerEventClaim.slack_event_key(channel_id, fired_message.ts) }, session
            )
          end
        end
      end
    end

    if fired.empty?
      Rails.logger.info "#{slack_log_tag} Condition #{condition.id} already fired for message #{message.ts}" \
                        "#{" (+#{folded.length} coalesced)" if folded.any?} — the other delivery path claimed it first; skipping"
      return nil
    end

    head = rendered.head
    folded_count = rendered.folded.length

    # Burst control can suppress the spawn (see Trigger::BURST_WINDOW). The
    # message is then DROPPED, not retried: the poller advances the condition's
    # cursor to the newest message it fetched regardless of what each message
    # produced, which is exactly what we want here — replaying a burst once it
    # subsides would spawn the very sessions the cap exists to prevent.
    #
    # `skip_if_pending_session` drops the message the same way and for the same
    # reason: a session this trigger already spawned is still queued, so the
    # message it would have spawned a second session for is covered by that one.
    if session.nil?
      reason = trigger.last_fire_skipped_for_pending_session? ? "session #{trigger.last_fire_pending_session.id} is still pending" : "burst-suppressed"
      Rails.logger.info "#{slack_log_tag} Trigger #{trigger.id} spawned nothing for message #{head.ts}#{" (+#{folded_count} coalesced)" if folded_count.positive?} (#{reason}) — dropping it"
      return nil
    end

    condition.update!(last_triggered_at: Time.current)

    coalesced = folded_count.positive? ? " (coalescing #{folded_count} further message(s) that landed within #{trigger.effective_coalesce_window_seconds}s)" : ""
    Rails.logger.info "#{slack_log_tag} Created session #{session.id} for trigger #{trigger.id} from #{dm ? 'DM' : 'channel'} message #{head.ts}#{coalesced}"
    session
  end

  # The prompt for one fire: the trigger's template rendered from the first message, plus — for
  # a coalesced group — the note naming every message folded into it.
  def render_slack_fire(condition, messages, channel_id:, dm:)
    trigger = condition.trigger
    head, *folded = messages

    permalink = get_message_permalink(channel_id, head.ts)
    channel_name = dm ? "DM" : (condition.channel_name.presence || resolve_channel_name(channel_id))

    prompt = trigger.interpolate_prompt(
      link: permalink,
      text: head.text || "",
      author: get_author_name(head),
      channel: channel_name
    )

    # The messages this one is standing in for. Appended AFTER interpolation, not
    # through a template variable: a trigger's template is written by whoever
    # configured it and cannot be expected to mention a burst, and the one thing
    # that must never happen is a folded message going unmentioned.
    # Resolved once, here, because the same links are wanted twice: in the note
    # below and on the human-message records. Only the ones the note will list
    # are resolved — past that cap the note gives a count instead, and a link per
    # message would be a Slack API call per message for text nobody reads.
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

    RenderedFire.new(
      prompt: prompt, head: head, folded: folded,
      head_permalink: permalink, folded_permalinks: folded_permalinks, channel_name: channel_name
    )
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
  #
  # Memoized per message for the life of the job, so a fire re-rendered after losing part of
  # its group to the other path asks Slack for nothing it already asked for.
  def get_message_permalink(channel_id, message_ts)
    @permalink_cache ||= {}
    key = [ channel_id, message_ts ]
    return @permalink_cache[key] if @permalink_cache.key?(key)

    @permalink_cache[key] = begin
      SlackService.get_message_permalink(channel_id, message_ts)
    rescue SlackService::SlackError => e
      Rails.logger.warn "#{slack_log_tag} No permalink for #{message_ts} in #{channel_id}: #{e.message}"
      nil
    end
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

    # Memoized per user for the life of the job, for the same reason as #get_message_permalink.
    @author_name_cache ||= {}
    @author_name_cache[message.user] ||= SlackService.get_user_name(message.user)
  rescue SlackService::SlackError
    message.user
  end
end

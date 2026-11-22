# frozen_string_literal: true

# Polls the WhatsApp bridge for new messages in each watched chat and fires `whatsapp` triggers.
#
# Every minute, for every `whatsapp` condition on an enabled trigger:
#
#   1. read the chat's messages from LOOKBACK before the condition's cursor (last_message_ts,
#      whole UNIX seconds) and drop the ids already read (`seen_messages`);
#   2. drop what must never fire: anything this bridge sent (Zimmer's own posts — the self-loop),
#      anything the linked account sent from its phone unless the condition opts in, and
#      reactions;
#   3. decide: a `listen` condition fires on any message left; an `addressed` one only when one
#      of them @mentions the linked account, replies to one of its messages, or contains a
#      keyword;
#   4. fire ONCE for the whole batch, the way SlackTriggerFiring coalesces a burst. A group chat
#      is a conversation, and five messages that arrived inside one minute are one turn of it,
#      not five sessions. With `reuse_session` on the trigger — the intended setup — the batch
#      lands as one follow-up in the session that owns the chat.
#
# The spawn and the cursor commit together, so a fire that raises is retried on the next tick and
# a fire that succeeded is never repeated. A batch that did not REACH its session — the reused
# session still holds an undelivered earlier batch, or is mid-turn with `enqueue_messages` off, or
# `skip_if_pending_session` held the fire — leaves the cursor where it was, so the next tick reads
# the batch again together with anything newer and delivers it then. Only a burst-suppressed fire
# is dropped, as on Slack: replaying a burst is what the cap exists to prevent.
#
# A batch that reached its session also records each of its messages as a
# `whatsapp:<chat_jid>:<message_id>` TriggerEventClaim, in the same transaction, for
# compare_trigger_fires. Nothing reads it to decide anything — the seen-set does that (#record_fire!).
#
# A condition the poller has never visited is baselined, not fired: its cursor is set to the
# newest message in the chat, so turning a trigger on never replays the chat's history.
#
# A condition whose chat_id is `*` watches EVERY chat the linked account is in. Each tick lists the
# chats and reads each one that has activity, under a cursor of its own, and fires once per chat:
# one person's DM is one conversation, and a batch never carries two chats. Baselining such a
# condition records only the time. A chat first seen after that is read from that time, so the
# first message from someone new fires.
#
# Message text and author names are what people typed. They go into the prompt through
# Trigger#interpolate_prompt, which fences them as untrusted wherever the template asks, and they
# never go into a log line.
class WhatsappTriggerPollerJob < ApplicationJob
  queue_as :pollers

  # At most one poll unfinished at a time, like every other poller: a slow bridge must not stack
  # polls against itself.
  include SingletonSweep

  PAGE_SIZE = WhatsappService::MAX_PAGE

  # How far behind the cursor each poll re-reads. A WhatsApp message carries the SENDER's clock,
  # so one sent from a phone that was offline for a few minutes arrives stamped earlier than
  # messages already read. Reading only forward from the cursor would skip it for good; re-reading
  # this window and dropping ids already seen catches it. The seen-set is kept for exactly this
  # window, so it stays the size of ten minutes of chat.
  LOOKBACK = 10.minutes

  # Pages read per condition per tick. 1,000 messages in a minute is not a chat anyone is
  # listening to; the rest is read on the next tick, since the cursor only moves over what was read.
  # (A look-back window holding more than this many messages would re-read only messages it had
  # already seen and never move the cursor. That is a chat far busier than the one this is for.)
  MAX_PAGES = 5

  # How many messages a prompt quotes. Past this it quotes the newest and says how many it left
  # out: the session can read them with whatsapp_get_messages.
  MAX_MESSAGES_IN_PROMPT = 50

  # A message's text, cut to this in the prompt. A pasted contract is not what the prompt is for.
  MAX_TEXT_CHARS = 2_000

  # Chats an all-chats condition lists per tick, newest activity first. A chat with activity this
  # tick is near the top of the list.
  MAX_CHATS = 100

  def perform
    return unless configured?

    conditions = TriggerCondition.whatsapp
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger)

    # Nothing to poll is still liveness — see SlackTriggerPollerJob#perform for why.
    unless conditions.exists?
      PollerHeartbeat.stamp(:whatsapp)
      return
    end

    service = WhatsappService.new

    begin
      service.ensure_ready!
    rescue WhatsappService::Error => e
      # WARN, not ERROR: this is the state the liveness check pages on, once, with the fix in
      # the page. Logging ERROR every minute would page every minute.
      Rails.logger.warn "[WhatsappTriggerPollerJob] Not polling: #{e.message}"
      return
    end

    any_polled = false

    conditions.find_each do |condition|
      process_condition(service, condition)
      any_polled = true
    rescue => e
      Rails.logger.error "[WhatsappTriggerPollerJob] Error processing condition #{condition.id}: #{e.class}: #{e.message}"
      ErrorReporter.report_exception(
        e,
        context: {
          title: "WhatsApp trigger poller error",
          source: "WhatsappTriggerPollerJob",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) failed.",
          condition_id: condition.id,
          trigger_id: condition.trigger_id
        }
      )
    end

    PollerHeartbeat.stamp(:whatsapp) if any_polled
  end

  private

  def configured?
    WhatsappService.configured?
  rescue => e
    # The secret store being unreachable is its own alert; here it just means "not this tick".
    Rails.logger.warn "[WhatsappTriggerPollerJob] Could not read WhatsApp settings: #{e.class}: #{e.message}"
    false
  end

  def process_condition(service, condition)
    return process_all_chats(service, condition) if condition.whatsapp_all_chats?

    chat_id = condition.whatsapp_chat_id
    cursor = condition.last_message_ts.presence&.to_i

    return baseline!(service, condition, chat_id) if cursor.nil?

    seen = condition.whatsapp_seen_messages
    fetched, chat_name = read_since(service, chat_id, cursor - LOOKBACK.to_i, seen)
    return condition.mark_polled! if fetched.empty?

    new_cursor, seen = advance(cursor, seen, fetched)
    candidates = fetched.select { |message| fires?(condition, message) }
    addressed = candidates.select { |message| addresses_zimmer?(condition, message) }
    fire = candidates.any? && (!condition.whatsapp_addressed_only? || addressed.any?)

    outcome = nil
    ActiveRecord::Base.transaction do
      # Re-read the row under a lock: an edit that landed while this tick was reading the bridge
      # must not be written over with the configuration loaded at the start of the sweep. An edit
      # that moved the condition to another chat makes this batch moot — the next tick baselines
      # the new chat.
      condition.lock!
      raise ActiveRecord::Rollback if condition.whatsapp_chat_id != chat_id || condition.last_message_ts.to_i != cursor

      outcome = fire ? fire!(condition, candidates, addressed, chat_id: chat_id, chat_name: chat_name) : :nothing_to_fire

      if outcome == :held
        condition.update!(last_polled_at: Time.current)
      else
        condition.update!(
          last_message_ts: new_cursor.to_s,
          last_polled_at: Time.current,
          last_triggered_at: outcome.is_a?(Session) ? Time.current : condition.last_triggered_at,
          configuration: condition.configuration.merge("seen_messages" => seen)
        )
      end
    end

    log_outcome(condition, candidates.size, outcome) if fire
  end

  def process_all_chats(service, condition)
    baseline = condition.last_message_ts.presence&.to_i
    if baseline.nil?
      condition.with_lock do
        next unless condition.whatsapp_all_chats? && condition.last_message_ts.blank?

        condition.update!(last_message_ts: Time.current.to_i.to_s, last_polled_at: Time.current,
                          configuration: condition.configuration.merge("chats" => {}))
      end
      Rails.logger.info "[WhatsappTriggerPollerJob] Condition #{condition.id} baselined for all chats"
      return
    end

    read = Set.new
    service.list_chats(limit: MAX_CHATS).each do |chat|
      listed_id = chat["id"].to_s
      next if listed_id.blank?

      key, state = chat_state_for(condition, listed_id)
      next if read.include?(key)

      cursor = state ? state["last_message_ts"].to_i : baseline
      last_at = epoch_seconds(chat["last_message_at"])
      next if last_at && last_at < cursor - LOOKBACK.to_i

      begin
        process_chat(service, condition, listed_id, state, baseline, read)
      rescue => e
        # One chat failing must not starve the others; it reports every tick it fails.
        Rails.logger.error "[WhatsappTriggerPollerJob] Error reading a chat for condition #{condition.id}: #{e.class}: #{e.message}"
        ErrorReporter.report_exception(
          e,
          context: {
            title: "WhatsApp trigger poller error",
            source: "WhatsappTriggerPollerJob",
            details: "A chat on all-chats condition #{condition.id} (trigger '#{condition.trigger&.name}', ID: #{condition.trigger_id}) failed.",
            condition_id: condition.id,
            trigger_id: condition.trigger_id
          }
        )
      end
    end

    condition.mark_polled!
  end

  # The bridge's `last_message_at`, as UNIX seconds: it is documented as seconds, and an ISO string
  # is read too rather than as the year it starts with. Nil when absent or unreadable, in which case
  # the chat is read.
  def epoch_seconds(value)
    case value
    when Integer then value
    when /\A\d+\z/ then value.to_i
    when String then Time.iso8601(value).to_i
    end
  rescue ArgumentError
    nil
  end

  # The chat's key in `chats` and its state, looking through aliases. A chat not seen yet has no
  # state and is keyed by the id it was listed under, until a read names it.
  def chat_state_for(condition, listed_id)
    states = condition.whatsapp_chat_states
    return [ listed_id, states[listed_id] ] if states.key?(listed_id)

    key, state = states.find { |_key, candidate| Array(candidate["aliases"]).include?(listed_id) }
    key ? [ key, state ] : [ listed_id, nil ]
  end

  def process_chat(service, condition, listed_id, state, baseline, read)
    from = state ? state["last_message_ts"].to_i - LOOKBACK.to_i : baseline
    seen = state ? state["seen_messages"].to_h.transform_values(&:to_i) : {}
    fetched, chat_name, chat_id = read_since(service, listed_id, from, seen)
    chat_id = chat_id.presence || listed_id
    # The id goes into the prompt as {{chat_id}} and the session posts to it, so it must be a chat
    # id, whatever the bridge answered.
    raise WhatsappService::Error, "the bridge named a chat #{chat_id.inspect}, which is not a WhatsApp chat id" unless chat_id.match?(TriggerCondition::WHATSAPP_CHAT_ID_FORMAT)

    # Nothing from before the condition was baselined is new, look-back window or not.
    fetched = fetched.select { |message| message.timestamp >= baseline }

    # The bridge reads an alias (a person's `@lid`) as the chat it stands for. When that chat
    # already has a cursor, this read is judged against it instead, and the alias remembered.
    if chat_id != listed_id && read.include?(chat_id)
      remember_alias(condition, chat_id, listed_id, baseline)
      return
    elsif chat_id != listed_id && (canonical = condition.whatsapp_chat_states[chat_id])
      state = canonical
      cursor_floor = state["last_message_ts"].to_i - LOOKBACK.to_i
      seen = state["seen_messages"].to_h.transform_values(&:to_i)
      fetched = fetched.select { |message| message.timestamp >= cursor_floor && !seen.key?(message.id) }
    end
    read << chat_id

    cursor = state ? state["last_message_ts"].to_i : baseline
    aliases = Array(state&.dig("aliases")) | (chat_id == listed_id ? [] : [ listed_id ])
    if fetched.empty?
      # Record a chat seen for the first time, or an alias learned, so the next tick reads it under
      # its own cursor.
      if state.nil?
        update_chat_state(condition, chat_id, baseline) { |current| current || { "last_message_ts" => cursor, "seen_messages" => seen, "aliases" => aliases } }
      elsif aliases != Array(state["aliases"])
        remember_alias(condition, chat_id, listed_id, baseline)
      end
      return
    end

    new_cursor, new_seen = advance(cursor, seen, fetched)
    candidates = fetched.select { |message| fires?(condition, message) }
    addressed = candidates.select { |message| addresses_zimmer?(condition, message) }
    fire = candidates.any? && (!condition.whatsapp_addressed_only? || addressed.any?)

    outcome = nil
    ActiveRecord::Base.transaction do
      # The same re-read under lock as a single-chat poll: an edit that took the condition off all
      # chats, or re-baselined it, makes this batch moot.
      condition.lock!
      raise ActiveRecord::Rollback unless condition.whatsapp_all_chats? && condition.last_message_ts.to_i == baseline
      raise ActiveRecord::Rollback if condition.whatsapp_chat_states[chat_id]&.dig("last_message_ts").to_i != (state ? cursor : 0)

      # Unlike a single chat, a fire during a burst is held, not dropped: the cap is shared by every
      # chat, so a busy tick in one chat would otherwise drop another's messages. It is held WITHOUT
      # firing, because each attempt takes a burst slot, and held chats retrying every tick would
      # keep the burst open for good. Once it closes they drain, up to the cap per window.
      outcome = if !fire then :nothing_to_fire
      elsif condition.trigger.reload.bursting? then :burst_suppressed
      else fire!(condition, candidates, addressed, chat_id: chat_id, chat_name: chat_name)
      end
      next if outcome == :held || outcome == :burst_suppressed

      chats = condition.whatsapp_chat_states.merge(
        chat_id => { "last_message_ts" => new_cursor, "seen_messages" => new_seen, "aliases" => aliases }
      )
      condition.update!(
        last_triggered_at: outcome.is_a?(Session) ? Time.current : condition.last_triggered_at,
        configuration: condition.configuration.merge("chats" => chats)
      )
    end

    log_outcome(condition, candidates.size, outcome) if fire
  end

  # Rewrites one chat's state under the row lock, from the state as it is now — not as it was when
  # this tick read it.
  def update_chat_state(condition, chat_id, baseline)
    condition.with_lock do
      next unless condition.whatsapp_all_chats? && condition.last_message_ts.to_i == baseline

      states = condition.whatsapp_chat_states
      updated = yield(states[chat_id])
      next if updated.nil? || updated == states[chat_id]

      condition.update!(configuration: condition.configuration.merge("chats" => states.merge(chat_id => updated)))
    end
  end

  def remember_alias(condition, chat_id, alias_id, baseline)
    update_chat_state(condition, chat_id, baseline) do |current|
      current&.merge("aliases" => Array(current["aliases"]) | [ alias_id ])
    end
  end

  def log_outcome(condition, count, outcome)
    said = case outcome
    when Session then "delivered to session #{outcome.id}"
    when :held then "not delivered yet (the session is busy or a session is still pending); held for the next tick"
    when :burst_suppressed then condition.whatsapp_all_chats? ? "burst-suppressed; held for the next tick" : "burst-suppressed, dropped"
    else "rolled back (the condition was edited mid-poll)"
    end
    Rails.logger.info "[WhatsappTriggerPollerJob] Condition #{condition.id}: #{count} new message(s), #{said}"
  end

  # The first poll of a condition: remember where the chat is now, fire nothing. The whole
  # look-back window behind the newest message goes into the seen-set, since the next tick re-reads
  # that window and would otherwise fire on ten minutes of history.
  def baseline!(service, condition, chat_id)
    newest = service.get_messages(chat_id, limit: 1).messages.last
    timestamp = newest&.timestamp || Time.current.to_i
    window = newest ? read_since(service, chat_id, timestamp - LOOKBACK.to_i, {}).first : []
    condition.update!(
      last_message_ts: timestamp.to_s,
      last_polled_at: Time.current,
      configuration: condition.configuration.merge("seen_messages" => window.to_h { |message| [ message.id, message.timestamp ] })
    )
    Rails.logger.info "[WhatsappTriggerPollerJob] Condition #{condition.id} baselined at #{timestamp}"
  end

  # Every message at or after +from+ not already seen, oldest first, walking forward a page at a
  # time, with the chat's name and the id the bridge read it under. The bridge returns the OLDEST page when more match, so the walk never skips one.
  def read_since(service, chat_id, from, seen_messages)
    seen = seen_messages.keys.to_set
    fetched = []
    chat_name = nil
    chat_id_read = nil
    after = from

    MAX_PAGES.times do
      page = service.get_messages(chat_id, after: after, limit: PAGE_SIZE)
      chat_name ||= page.chat_name
      chat_id_read ||= page.chat_id
      page.messages.each do |message|
        next if seen.include?(message.id)

        seen << message.id
        fetched << message
      end

      break unless page.has_more

      newest = page.messages.last&.timestamp
      # A full page inside one second would re-read itself forever; take what we have.
      break if newest.nil? || newest <= after

      after = newest
    end

    [ fetched.sort_by(&:timestamp), chat_name, chat_id_read ]
  end

  # The cursor after this batch — the newest timestamp read — and the seen-set, trimmed to what
  # the next poll's look-back window will read again.
  def advance(cursor, seen_messages, fetched)
    newest = [ cursor, fetched.map(&:timestamp).max ].max
    horizon = newest - LOOKBACK.to_i
    seen = seen_messages.merge(fetched.to_h { |message| [ message.id, message.timestamp ] })
    [ newest, seen.select { |_id, timestamp| timestamp >= horizon } ]
  end

  def fires?(condition, message)
    return false if message.sent_by_bridge
    return false if message.from_me && !condition.whatsapp_include_from_me?
    return false if message.type == "reaction"

    true
  end

  def addresses_zimmer?(condition, message)
    return true if message.mentions_self || message.reply_to_self

    text = message.text.to_s.downcase
    condition.whatsapp_keywords.any? { |word| text.match?(/(?<![[:alnum:]])#{Regexp.escape(word)}(?![[:alnum:]])/) }
  end

  def fire!(condition, messages, addressed, chat_id:, chat_name:)
    trigger = condition.trigger
    newest = messages.last
    prompt = trigger.interpolate_prompt(
      text: transcript(messages, addressed),
      author: messages.filter_map { |message| author_label(message) }.uniq.join(", "),
      channel: chat_name.presence || (condition.whatsapp_all_chats? ? nil : condition.whatsapp_chat_name.presence) || chat_id,
      event: addressed.any? ? "addressed" : "message",
      chat_id: chat_id,
      message_id: newest.id
    )

    # The transaction-scoped spawn lock SlackTriggerFiring takes for the same reason: a manual
    # invoke, or a second condition on this trigger, must not race this fire's skip/burst checks.
    Trigger.lock_spawn_for_transaction!(trigger.id)
    session = trigger.create_session!(
      prompt: prompt,
      session_metadata: { "whatsapp_chat_id" => chat_id, "whatsapp_message_id" => newest.id }
    )

    return :held if session.nil? && trigger.last_fire_skipped_for_pending_session?
    return :burst_suppressed if session.nil?
    return :held if %i[skipped_pending_exists dropped].include?(trigger.last_follow_up_status)

    record_fire!(condition, messages, session, chat_id: chat_id)
    session
  end

  # Records each message the batch delivered as a TriggerEventClaim (`whatsapp:<chat>:<id>`,
  # `whatsapp_record`) with its session on it. Nothing reads it to decide anything; it is what
  # compare_trigger_fires lines up against an `mcp_event` trigger on strad's WhatsApp
  # `message_received` event, whose eventId has the same shape.
  #
  # Every message of the batch is recorded, not only the newest: the session got all of them, and
  # the event source fires once per message. The chat is the one the bridge stored each message
  # under, which is the chat strad's eventId names; the condition's own chat id is only the fallback,
  # since a condition saved with a chat's LID reads a chat the bridge keys by its phone JID. A burst
  # notice is not a fire for the batch that opened the burst, so it records nothing.
  def record_fire!(condition, messages, session, chat_id:)
    return if session.metadata["burst_notice"]

    keys = messages.map { |message| TriggerEventClaim.whatsapp_event_key(message.chat_id.presence || chat_id, message.id) }
    TriggerEventClaim.claim!(condition, keys, via: "whatsapp_record", session_id: session.id)
  end

  # The batch as a chat log, oldest first: one line per message, time, author, text. A message
  # that addresses Zimmer is marked, so a `listen` session can tell a question put to it from
  # conversation it is overhearing.
  def transcript(messages, addressed)
    shown = messages.last(MAX_MESSAGES_IN_PROMPT)
    marked = addressed.map(&:id).to_set

    lines = shown.map do |message|
      at = Time.zone.at(message.timestamp).utc.strftime("%Y-%m-%d %H:%M UTC")
      body = one_line(message.text.to_s.strip.truncate(MAX_TEXT_CHARS)).presence
      body = [ "(#{message.type})", body ].compact.join(" ") unless message.type == "text"
      flag = marked.include?(message.id) ? " [addresses Zimmer]" : ""
      "[#{at}] #{author_label(message) || 'unknown'}#{flag}: #{body || '(no text)'}"
    end

    omitted = messages.size - shown.size
    lines.unshift("(#{omitted} earlier message(s) not shown — read them with whatsapp_get_messages)") if omitted.positive?
    lines.join("\n")
  end

  # A message's line breaks become " / ". Each message is exactly one line of the log, so nobody
  # in the chat can type a line that looks like another person's message, or like one Zimmer
  # marked as addressing it.
  def one_line(text)
    text.gsub(/\s*\R\s*/, " / ")
  end

  # "Name (+15551234567)". The number is shown only for a phone-number JID: a `@lid` id is an
  # opaque account id, and printing it with a + would dress it up as a phone number. The name is
  # whatever the person set as their WhatsApp name, so it loses line breaks and brackets.
  def author_label(message)
    user, server = message.sender_jid.to_s.split("@", 2)
    number = user.to_s.split(":").first if server == "s.whatsapp.net"
    phone = "+#{number}" if number.to_s.match?(/\A\d+\z/)
    name = message.sender_name.to_s.gsub(/[\[\]\r\n]+/, " ").squish.presence

    return "#{name} (#{phone})" if name && phone

    name || phone
  end
end

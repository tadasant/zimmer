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
# a fire that succeeded is never repeated.
#
# A condition the poller has never visited is baselined, not fired: its cursor is set to the
# newest message in the chat, so turning a trigger on never replays the chat's history.
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
  MAX_PAGES = 5

  # How many messages a prompt quotes. Past this it quotes the newest and says how many it left
  # out: the session can read them with whatsapp_get_messages.
  MAX_MESSAGES_IN_PROMPT = 50

  # A message's text, cut to this in the prompt. A pasted contract is not what the prompt is for.
  MAX_TEXT_CHARS = 2_000

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

    session = nil
    ActiveRecord::Base.transaction do
      session = fire!(condition, candidates, addressed, chat_id: chat_id, chat_name: chat_name) if fire
      condition.update!(
        last_message_ts: new_cursor.to_s,
        last_polled_at: Time.current,
        last_triggered_at: session ? Time.current : condition.last_triggered_at,
        configuration: condition.configuration.merge("seen_messages" => seen)
      )
    end

    if fire
      outcome = session ? "fired session #{session.id}" : "spawned nothing (burst-suppressed or a session is still pending)"
      Rails.logger.info "[WhatsappTriggerPollerJob] Condition #{condition.id}: #{candidates.size} new message(s), #{outcome}"
    end
  end

  # The first poll of a condition: remember where the chat is now, fire nothing.
  def baseline!(service, condition, chat_id)
    newest = service.get_messages(chat_id, limit: 1).messages.last
    timestamp = newest&.timestamp || Time.current.to_i
    condition.update!(
      last_message_ts: timestamp.to_s,
      last_polled_at: Time.current,
      configuration: condition.configuration.merge("seen_messages" => newest ? { newest.id => newest.timestamp } : {})
    )
    Rails.logger.info "[WhatsappTriggerPollerJob] Condition #{condition.id} baselined at #{timestamp}"
  end

  # Every message at or after +from+ not already seen, oldest first, walking forward a page at a
  # time. The bridge returns the OLDEST page when more match, so the walk never skips one.
  def read_since(service, chat_id, from, seen_messages)
    seen = seen_messages.keys.to_set
    fetched = []
    chat_name = nil
    after = from

    MAX_PAGES.times do
      page = service.get_messages(chat_id, after: after, limit: PAGE_SIZE)
      chat_name ||= page.chat_name
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

    [ fetched.sort_by(&:timestamp), chat_name ]
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
      channel: chat_name.presence || condition.whatsapp_chat_name.presence || chat_id,
      event: addressed.any? ? "addressed" : "message",
      chat_id: chat_id,
      message_id: newest.id
    )

    trigger.create_session!(
      prompt: prompt,
      session_metadata: { "whatsapp_chat_id" => chat_id, "whatsapp_message_id" => newest.id }
    )
  end

  # The batch as a chat log, oldest first: one line per message, time, author, text. A message
  # that addresses Zimmer is marked, so a `listen` session can tell a question put to it from
  # conversation it is overhearing.
  def transcript(messages, addressed)
    shown = messages.last(MAX_MESSAGES_IN_PROMPT)
    marked = addressed.map(&:id).to_set

    lines = shown.map do |message|
      at = Time.zone.at(message.timestamp).utc.strftime("%Y-%m-%d %H:%M UTC")
      body = message.text.to_s.strip.truncate(MAX_TEXT_CHARS).presence
      body = [ "(#{message.type})", body ].compact.join(" ") unless message.type == "text"
      flag = marked.include?(message.id) ? " [addresses Zimmer]" : ""
      "[#{at}] #{author_label(message) || 'unknown'}#{flag}: #{body || '(no text)'}"
    end

    omitted = messages.size - shown.size
    lines.unshift("(#{omitted} earlier message(s) not shown — read them with whatsapp_get_messages)") if omitted.positive?
    lines.join("\n")
  end

  # "Name (+15551234567)". The number is shown only for a phone-number JID: a `@lid` id is an
  # opaque account id, and printing it with a + would dress it up as a phone number.
  def author_label(message)
    user, server = message.sender_jid.to_s.split("@", 2)
    number = user.to_s.split(":").first if server == "s.whatsapp.net"
    phone = "+#{number}" if number.to_s.match?(/\A\d+\z/)
    name = message.sender_name.presence

    return "#{name} (#{phone})" if name && phone

    name || phone
  end
end

# frozen_string_literal: true

# Polls a mailbox for new mail and fires `email` triggers.
#
# Every minute, for every `email` condition on an enabled trigger:
#
#   1. search the mailbox for the condition's query, minus the mailbox's own mail (`-from:me`, the
#      self-loop) and, unless the condition opts in, Gmail's promotions/social/forums/updates
#      categories — received after LOOKBACK before the condition's cursor — and drop the ids
#      already read (`seen_messages`);
#   2. read each new message in full and drop what must never fire: anything Gmail filed as SENT,
#      DRAFT, SPAM or TRASH, and, unless the condition opts in, automated mail — a category label,
#      a bounce or no-reply sender, an auto-reply subject (#automated?);
#   3. fire ONCE PER THREAD: the new messages of one thread are one fire, with the newest as
#      {{message_id}}; two threads are two fires.
#
# Per thread rather than one batch per tick, unlike WhatsApp. A chat is one conversation and a burst
# of it is one turn; an inbox is many conversations with many strangers. Batching them would put
# one sender's words in the prompt that decides how to answer another — a prompt injection in one
# mail would steer the reply to the next. One session per thread keeps each untrusted sender in a
# session of its own. (With `reuse_session` on the trigger, every fire lands in one session anyway;
# that is the trigger's choice.)
#
# Each thread's spawn commits with its messages' place in the seen-set, so a fire that raises is
# retried on the next tick and one that succeeded is never repeated. The cursor moves only when
# every thread found was settled; a thread that raised, was held (`skip_if_pending_session`, or a
# reused session that would not take it) or is past MAX_FIRES_PER_TICK keeps the cursor where it
# was, and the next tick re-reads it. A burst-suppressed fire is dropped, as on Slack. A message the
# mailbox server cannot return (MAX_READ_ATTEMPTS ticks running) is given up on with one report, so
# one unreadable mail cannot hold the cursor for good.
#
# A condition the poller has never visited is baselined, not fired: what is already in the window
# goes into the seen-set, so turning a trigger on never answers old mail.
#
# Everything a message says — subject, From, body — is what its sender wrote. It goes into the
# prompt only through Trigger#interpolate_prompt, and a trigger with an email condition must fence
# it (Trigger#validate_email_template_fences_sender_content). It never goes into a log line.
class EmailTriggerPollerJob < ApplicationJob
  queue_as :pollers

  # At most one poll unfinished at a time, like every other poller.
  include SingletonSweep

  # How far behind the cursor each poll re-reads. Gmail's search index can trail delivery, so a
  # message delivered just before a poll may only become searchable after it; re-reading this
  # window and dropping ids already seen catches it.
  LOOKBACK = 10.minutes

  # How much longer than the window a seen id is kept. An id is stamped with the time Zimmer first
  # read it, which is after Gmail received it on Gmail's clock; the margin absorbs the skew between
  # the two clocks, so an id is never forgotten while a search could still return it.
  SEEN_MARGIN = 5.minutes

  # Ticks in a row a message may fail to read before it is given up on (marked seen, reported once).
  MAX_READ_ATTEMPTS = 5

  # Fires per condition per tick. A mailbox receiving more than this in a minute is being flooded;
  # the rest stay unread and are taken on the next ticks, and the trigger's own burst cap
  # (max_sessions_per_minute) still applies on top.
  MAX_FIRES_PER_TICK = 10

  # Messages of one thread quoted in one prompt — the newest. The session can read the rest with
  # get_email_conversation.
  MAX_MESSAGES_PER_FIRE = 5

  # A message body, cut to this in the prompt.
  MAX_BODY_CHARS = 10_000

  # Gmail categories that are, by Gmail's own classification, mail nobody wrote to this mailbox by
  # hand: marketing, social-network notices, mailing lists, automated updates. Gmail derives them
  # from exactly the signals the mailbox server does not expose (`List-*`, `Precedence: bulk`,
  # `Auto-Submitted`, the sender's history), which is why they stand in for those headers here.
  AUTOMATED_CATEGORIES = %w[promotions social forums updates].freeze
  AUTOMATED_LABELS = AUTOMATED_CATEGORIES.map { |category| "CATEGORY_#{category.upcase}" }.freeze

  # Labels that mean the message is not inbound mail for anyone to answer.
  NEVER_FIRE_LABELS = %w[SENT DRAFT SPAM TRASH].freeze

  # A sender that is a mail system or says outright that it reads nothing.
  AUTOMATED_SENDER = /\A(mailer-daemon|postmaster|no[-_.]?reply|do[-_.]?not[-_.]?reply|bounces?)([+@])/i

  # An auto-reply or a bounce, by the subjects the common mail systems give them.
  AUTOMATED_SUBJECT = /\A\s*(auto(matic)?[- ]?(reply|response)\b|auto:|out of (the )?office\b|undeliverable\b|undelivered mail\b|delivery status notification\b|mail delivery (failed|subsystem)\b|returned mail\b|failure notice\b)/i

  def perform
    return unless configured?

    conditions = TriggerCondition.email
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger)

    # Nothing to poll is still liveness — see SlackTriggerPollerJob#perform for why.
    unless conditions.exists?
      PollerHeartbeat.stamp(:email)
      return
    end

    service = EmailService.new
    any_polled = false

    conditions.find_each do |condition|
      process_condition(service, condition)
      any_polled = true
    rescue EmailService::Error => e
      # The mailbox refused this condition's search — an unconsented or revoked Google token, the
      # server down. That is the state the liveness check pages on, once, with the fix in the page:
      # when every condition fails this way nothing stamps the heartbeat. WARN, not ERROR, so this
      # does not page every minute on its own.
      Rails.logger.warn "[EmailTriggerPollerJob] Condition #{condition.id} not polled: #{e.message}"
    rescue => e
      report(condition, e)
    end

    PollerHeartbeat.stamp(:email) if any_polled
  end

  private

  def configured?
    EmailService.configured?
  rescue => e
    # The secret store being unreachable is its own alert; here it just means "not this tick".
    Rails.logger.warn "[EmailTriggerPollerJob] Could not read email settings: #{e.class}: #{e.message}"
    false
  end

  def report(condition, error, thread_id: nil)
    Rails.logger.error "[EmailTriggerPollerJob] Error processing condition #{condition.id}#{" thread #{thread_id}" if thread_id}: #{error.class}: #{error.message}"
    ErrorReporter.report_exception(
      error,
      context: {
        title: "Email trigger poller error",
        source: "EmailTriggerPollerJob",
        details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) failed.",
        condition_id: condition.id,
        trigger_id: condition.trigger_id
      }
    )
  end

  # A trigger the poller must not fire for, whatever its conditions say. The form, the API and MCP
  # refuse to save an email trigger with an unfenced template, but /supervisor edits conditions on
  # their own, so the poller checks again rather than trust the row.
  class UnfireableTrigger < StandardError; end

  def ensure_fireable!(trigger)
    raise UnfireableTrigger, "trigger #{trigger.id} runs a workflow; an email condition fires only templates" if trigger.workflow_backed?

    bare = trigger.unfenced_email_sender_variables
    raise UnfireableTrigger, "trigger #{trigger.id} writes #{bare.join(', ')} unfenced; an email trigger must write them |untrusted" if bare.any?
  end

  def process_condition(service, condition)
    ensure_fireable!(condition.trigger)

    search = search_signature(condition)
    cursor = condition.last_message_ts.presence&.to_i
    started = Time.current.to_i

    return baseline!(service, condition, search, started) if cursor.nil?

    seen = condition.email_seen_messages
    found = service.search(search_query(condition, cursor - LOOKBACK.to_i), count: EmailService::MAX_RESULTS)
    read_at = Time.current.to_i
    fresh = found.reject { |summary| seen.key?(summary.id) }

    # Oldest thread first: Gmail lists newest first, so the thread whose newest new message is
    # furthest down the list is the one that has waited longest.
    threads = fresh.group_by(&:thread_id).to_a.reverse
    settled = true

    threads.each_with_index do |(thread_id, summaries), index|
      if index >= MAX_FIRES_PER_TICK
        settled = false
        break
      end

      outcome = settle_thread(service, condition, search, cursor, thread_id, summaries, read_at)
      settled = false if %i[held rolled_back failed].include?(outcome)
    end

    advance!(condition, search, cursor, settled ? started : cursor)
  end

  # What the condition searches for. An edit that changes it mid-poll makes the poll moot.
  def search_signature(condition)
    [ condition.email_query, condition.email_include_automated? ]
  end

  # Gmail's search for "this condition's mail, received after +after+, that is not the mailbox's
  # own". The condition's query is parenthesised so an OR in it cannot swallow the terms after it.
  def search_query(condition, after)
    terms = [ "(#{condition.email_query})", "-from:me", "after:#{after}" ]
    terms.concat(AUTOMATED_CATEGORIES.map { |category| "-category:#{category}" }) unless condition.email_include_automated?
    terms.join(" ")
  end

  # The first poll of a condition: remember what is already in the window, fire nothing.
  def baseline!(service, condition, search, started)
    found = service.search(search_query(condition, started - LOOKBACK.to_i), count: EmailService::MAX_RESULTS)
    read_at = Time.current.to_i
    ActiveRecord::Base.transaction do
      condition.lock!
      raise ActiveRecord::Rollback unless search_signature(condition) == search && condition.last_message_ts.blank?

      condition.update!(
        last_message_ts: started.to_s,
        last_polled_at: Time.current,
        configuration: condition.configuration.merge("seen_messages" => found.to_h { |summary| [ summary.id, read_at ] })
      )
    end
    Rails.logger.info "[EmailTriggerPollerJob] Condition #{condition.id} baselined at #{started}"
  end

  # Read one thread's new messages, fire for it if any of them should, and record them as seen in
  # the same transaction. Returns what happened: a Session, :burst_suppressed, :held, :skipped (no
  # message in it may fire), :rolled_back (the condition was edited mid-poll) or :failed.
  def settle_thread(service, condition, search, cursor, thread_id, summaries, read_at)
    messages = []
    summaries.each do |summary|
      messages << service.get_message(summary.id)
    rescue EmailService::Error => e
      return :failed unless give_up_reading?(condition, summary.id, thread_id, e)
    end
    firing = messages.select { |message| fires?(condition, message) }

    outcome = :rolled_back
    ActiveRecord::Base.transaction do
      # Re-read the row under a lock: an edit that landed while this tick was reading the mailbox
      # must not be written over, and one that changed the search makes this read moot — the next
      # tick baselines the new one.
      condition.lock!
      raise ActiveRecord::Rollback if search_signature(condition) != search || condition.last_message_ts.to_i != cursor

      outcome = firing.any? ? fire!(condition, thread_id, firing.reverse) : :skipped

      # A held fire commits, without the seen-set: what the trigger recorded about the fire it
      # missed (Trigger#record_missed_fire!, which is what pages for a session that never takes its
      # follow-ups) must survive, and the mail stays unseen for the next tick.
      if outcome == :held
        condition.update!(last_polled_at: Time.current)
      else
        ids = summaries.map(&:id)
        condition.update!(
          last_polled_at: Time.current,
          last_triggered_at: outcome.is_a?(Session) ? Time.current : condition.last_triggered_at,
          configuration: condition.configuration.merge(
            "seen_messages" => condition.email_seen_messages.merge(ids.index_with(read_at)),
            "failed_reads" => condition.email_failed_reads.except(*ids)
          )
        )
      end
    end

    log_outcome(condition, thread_id, firing.size, outcome) if firing.any?
    outcome
  rescue => e
    # One thread's failure — a message deleted between the search and the read, a spawn that
    # raised — is that thread's, and is retried next tick. A mailbox that refuses every call fails
    # the search first, in #process_condition.
    report(condition, e, thread_id: thread_id)
    :failed
  end

  # Counts one more failed read of +message_id+. Returns true once it has failed MAX_READ_ATTEMPTS
  # ticks running — the caller then treats it as read and moves on, and it is reported once. Until
  # then it is a WARN: a timeout or a 5xx on one read is retried next tick, not paged.
  def give_up_reading?(condition, message_id, thread_id, error)
    attempts = nil
    ActiveRecord::Base.transaction do
      condition.lock!
      attempts = condition.email_failed_reads.fetch(message_id, 0) + 1
      condition.update!(configuration: condition.configuration.merge("failed_reads" => condition.email_failed_reads.merge(message_id => attempts)))
    end

    if attempts >= MAX_READ_ATTEMPTS
      report(condition, error, thread_id: thread_id)
      true
    else
      Rails.logger.warn "[EmailTriggerPollerJob] Condition #{condition.id}: could not read message #{message_id} (attempt #{attempts} of #{MAX_READ_ATTEMPTS}): #{error.message}"
      false
    end
  end

  # The cursor after this tick, and the seen-set trimmed to what the next tick's window reads again.
  # An id is stamped with when Zimmer first read it, which is no earlier than Gmail received it
  # (give or take SEEN_MARGIN of clock skew), so one stamped before the horizon names a message the
  # next search, `after:` the horizon, cannot return.
  def advance!(condition, search, cursor, new_cursor)
    ActiveRecord::Base.transaction do
      condition.lock!
      raise ActiveRecord::Rollback if search_signature(condition) != search || condition.last_message_ts.to_i != cursor

      horizon = new_cursor - LOOKBACK.to_i - SEEN_MARGIN.to_i
      condition.update!(
        last_message_ts: new_cursor.to_s,
        last_polled_at: Time.current,
        configuration: condition.configuration.merge(
          "seen_messages" => condition.email_seen_messages.select { |_id, first_read| first_read >= horizon }
        )
      )
    end
  end

  def fires?(condition, message)
    return false if NEVER_FIRE_LABELS.intersect?(message.labels)
    return true if condition.email_include_automated?

    !automated?(message)
  end

  # Bulk, list and auto-reply mail, as far as the mailbox server lets Zimmer see it: Gmail's
  # category labels, a mail-system or no-reply sender, an auto-reply or bounce subject.
  def automated?(message)
    AUTOMATED_LABELS.intersect?(message.labels) ||
      message.from_address.to_s.match?(AUTOMATED_SENDER) ||
      message.subject.to_s.match?(AUTOMATED_SUBJECT)
  end

  # +messages+ are one thread's new mail, oldest first.
  def fire!(condition, thread_id, messages)
    trigger = condition.trigger
    newest = messages.last
    prompt = trigger.interpolate_prompt(
      text: render(messages),
      author: messages.filter_map(&:from).uniq.join(", "),
      title: newest.subject,
      link: newest.url,
      event: "email",
      message_id: newest.id,
      thread_id: thread_id
    )

    # The transaction-scoped spawn lock SlackTriggerFiring takes for the same reason: a manual
    # invoke, or a second condition on this trigger, must not race this fire's skip/burst checks.
    Trigger.lock_spawn_for_transaction!(trigger.id)
    session = trigger.create_session!(
      prompt: prompt,
      session_metadata: { "email_message_id" => newest.id, "email_thread_id" => thread_id }
    )

    return :held if session.nil? && trigger.last_fire_skipped_for_pending_session?
    return :burst_suppressed if session.nil?
    return :held if %i[skipped_pending_exists dropped].include?(trigger.last_follow_up_status)

    session
  end

  def log_outcome(condition, thread_id, count, outcome)
    said = case outcome
    when Session then "delivered to session #{outcome.id}"
    when :held then "not delivered yet (the session is busy or a session is still pending); held for the next tick"
    when :burst_suppressed then "burst-suppressed, dropped"
    when :rolled_back then "rolled back (the condition was edited mid-poll)"
    else outcome.to_s
    end
    Rails.logger.info "[EmailTriggerPollerJob] Condition #{condition.id}: #{count} new message(s) in thread #{thread_id}, #{said}"
  end

  # One thread's new messages as the session reads them: headers, then body, per message, oldest
  # first. Every line of it is the sender's, which is why the template must fence it.
  def render(messages)
    shown = messages.last(MAX_MESSAGES_PER_FIRE)
    parts = shown.map do |message|
      headers = {
        "From" => message.from, "To" => message.to, "Cc" => message.cc,
        "Date" => message.date, "Subject" => message.subject, "Message ID" => message.id
      }.filter_map { |name, value| "#{name}: #{value}" if value.present? }
      if message.attachments.any?
        headers << "Attachments: #{message.attachments.join('; ')} (download_email_attachments reads them)"
      end

      body = message.body.presence || "(no body)"
      if body.length > MAX_BODY_CHARS
        body = "#{body.first(MAX_BODY_CHARS)}\n(body cut at #{MAX_BODY_CHARS} characters — read the rest with get_email_conversation)"
      end
      [ *headers, "", body ].join("\n")
    end

    omitted = messages.size - shown.size
    parts.unshift("(#{omitted} earlier new message(s) in this thread not shown — read them with get_email_conversation)") if omitted.positive?
    parts.join("\n\n-----\n\n")
  end
end

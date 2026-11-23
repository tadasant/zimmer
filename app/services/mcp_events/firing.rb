# frozen_string_literal: true

module McpEvents
  # Claims one event for one `mcp_event` condition and fires its trigger. Both delivery paths come
  # through here: McpEventTriggerPollerJob for each event a poll returns, and McpEventWebhookJob
  # for each one the server POSTs. The claim is TriggerEventClaim's `mcp:<server>:<eventId>` per
  # condition, taken in the same transaction as the spawn, so an event that arrives both ways fires
  # one session and the second path finds the claim and fires nothing. A condition with a
  # `coalesce_key` groups a burst into one session (#coalesced_groups, #settle).
  module Firing
    # A trigger the poller must not fire for, whatever its conditions say: the form, the API and MCP
    # refuse to save a template that writes a payload field bare, but /supervisor edits conditions
    # on their own, so firing checks again rather than trust the row.
    class UnfireableTrigger < StandardError; end

    # Pass as +cursor+ to skip the cursor check: a webhook delivery is not read from a cursor.
    ANY_CURSOR = Object.new.freeze

    module_function

    def ensure_fireable!(trigger)
      raise UnfireableTrigger, "trigger #{trigger.id} runs a workflow; an mcp_event condition fires only templates" if trigger.workflow_backed?

      bare = trigger.unfenced_mcp_event_fields
      raise UnfireableTrigger, "trigger #{trigger.id} writes event field(s) #{bare.join(', ')} unfenced; write them |untrusted or |id" if bare.any?
    end

    # Split events, in the order the server sent them, into the groups that fire one session each.
    #
    # Without a coalesce key (TriggerCondition#mcp_event_coalesce_key), or with a coalesce window of
    # 0, every event is its own group: one session per event. With one, an event joins the open
    # group of earlier events carrying the same value for the key when it is stamped within the
    # trigger's coalesce window of the event that OPENED that group — anchored, never chained, so a
    # chat posting steadily just inside the window cannot grow one group without bound
    # (SlackTriggerFiring#coalesced_groups follows the same rule). An event with no value for the
    # key, or one the payload filters refuse, is never grouped.
    def coalesced_groups(condition, occurrences)
      window = condition.trigger.effective_coalesce_window_seconds
      return occurrences.map { |occurrence| [ occurrence ] } unless condition.mcp_event_coalesce_key && window.positive?

      open_groups = {}
      occurrences.each_with_object([]) do |occurrence, groups|
        value = condition.mcp_event_coalesce_value(occurrence.data) if condition.mcp_event_payload_allowed?(occurrence.data)
        group = open_groups[value] if value

        # Either side of the anchor: a server may hand over a burst's events out of order.
        if group && (anchor_ts(occurrence) - anchor_ts(group.first)).abs <= window
          group << occurrence
        else
          group = [ occurrence ]
          open_groups[value] = group if value
          groups << group
        end
      end
    end

    # Claim and fire one event, or one group of events (#coalesced_groups). Returns a Session,
    # :folded (queued into the session an earlier event of the same group started), :filtered,
    # :duplicate, :held, :rolled_back (the condition was edited while the event was in hand) or
    # :failed.
    #
    # A group fires ONE session: its first unclaimed event is the head the template renders, and the
    # rest are listed in a note appended to the prompt (#folded_events_note). Every event in it is
    # still claimed under its own `mcp:<server>:<eventId>` key, so dedup and compare_trigger_fires
    # see each one, and a group that arrives again — a re-polled page, or the webhook and the poll
    # both delivering it — fires nothing twice.
    #
    # With a coalesce key, an event whose group already started a session that can still take a
    # follow-up is folded into it instead, as a queued message: the way a burst arriving one event
    # per webhook delivery, or across two polls, still ends up in one session. The claim group
    # (#open_group) is what finds that session, under the trigger's spawn lock.
    #
    # +subscription+ is the condition's mcp_event_subscription when the event was read; +cursor+ the
    # poll cursor it was read from, or ANY_CURSOR. Either having moved under the lock rolls back.
    def settle(condition, subscription, occurrences, via:, cursor: ANY_CURSOR, log_tag: "McpEvents::Firing")
      occurrences = [ occurrences ] unless occurrences.is_a?(Array)
      occurrences = occurrences.select { |occurrence| condition.mcp_event_payload_allowed?(occurrence.data) }
      return :filtered if occurrences.empty?

      keyed = occurrences.index_by { |occurrence| TriggerEventClaim.mcp_event_key(condition.mcp_event_server, occurrence.event_id) }
      trigger = condition.trigger
      window = trigger.effective_coalesce_window_seconds
      group_key = coalescing_group_key(condition, occurrences.first) if window.positive?
      won = []
      outcome = :rolled_back
      # Before the transaction: it makes Slack API calls.
      slack_messages = read_slack_messages(condition, keyed)
      ActiveRecord::Base.transaction do
        # Re-read the row under a lock: an edit that landed while the event was in hand must not be
        # written over, and one that changed the subscription makes the event moot.
        condition.lock!
        raise ActiveRecord::Rollback if condition.mcp_event_subscription != subscription
        raise ActiveRecord::Rollback if !cursor.equal?(ANY_CURSOR) && condition.mcp_event_cursor != cursor

        # The transaction-scoped spawn lock the other pollers take: a manual invoke, a second
        # condition on this trigger, or another delivery of the same burst must not race this fire's
        # group lookup, skip and burst checks. The second delivery of a burst waits here for the
        # first to commit its session, then finds it to fold into.
        Trigger.lock_spawn_for_transaction!(trigger.id)

        won = TriggerEventClaim.claim!(condition, keyed.keys, via: via, group_key: group_key)
        if won.empty?
          outcome = :duplicate
          next
        end
        fresh = keyed.values_at(*keyed.keys.select { |key| won.include?(key) })

        if group_key
          group = open_group(condition, group_key, anchor_ts(fresh.first), window)
          target = Session.find_by(id: group.session_id) if group
          # A session that cannot take a follow-up cannot take the event, so the event opens a group
          # of its own instead of vanishing into a queue nothing will drain. Checked under the
          # session's row lock, so a session archived a moment ago is not folded into.
          if target&.lock! && target.accepts_follow_up?
            # The fold spawns nothing, so it does not stamp last_triggered_at: that records fires.
            fold_into_session!(condition, target, fresh, window: window, slack_messages: slack_messages)
            TriggerEventClaim.where(trigger_condition_id: condition.id, event_key: won)
              .update_all(session_id: target.id, anchor_ts: group.anchor_ts)
            outcome = :folded
            next
          end
        end

        outcome = fire!(condition, fresh.first, folded: fresh.drop(1), slack_messages: slack_messages)
        if outcome.is_a?(Session)
          TriggerEventClaim.where(trigger_condition_id: condition.id, event_key: won)
            .update_all(session_id: outcome.id, anchor_ts: group_key ? anchor_ts(fresh.first) : nil)
          condition.update!(last_triggered_at: Time.current)
        else
          # Nothing was spawned, so the events are not fired: give the claims back, and the poll
          # tries again from its cursor. What the trigger recorded about the fire it missed
          # (Trigger#record_missed_fire!) still commits.
          TriggerEventClaim.where(trigger_condition_id: condition.id, event_key: won).delete_all
          outcome = :held
        end
      end

      unless outcome == :duplicate
        extra = won.length > 1 ? " (+#{won.length - 1} coalesced)" : ""
        Rails.logger.info "[#{log_tag}] Condition #{condition.id}: event #{won.first}#{extra} #{describe(outcome)}"
      end
      outcome
    rescue => e
      # One event's failure — a spawn that raised — is that event's, and the poll retries it.
      report(condition, e, source: log_tag)
      :failed
    end

    # What Slack says of each event not already claimed, by event id (SlackMessage.read). Only a
    # server the deployment named is asked about; for every other event this is nil.
    def read_slack_messages(condition, keyed)
      return {} unless SlackMessage.source?(condition.mcp_event_server, condition.mcp_event_name)

      claimed = TriggerEventClaim.where(trigger_condition_id: condition.id, event_key: keyed.keys).pluck(:event_key)
      SlackMessage.read_all(condition, keyed.except(*claimed).values)
    end

    def fire!(condition, occurrence, folded: [], slack_messages: {})
      trigger = condition.trigger
      prompt = trigger.interpolate_prompt(event: "mcp_event", event_id: occurrence.event_id, event_data: occurrence.data)
      if folded.any?
        prompt = [ prompt, folded_events_note(condition, folded, window: trigger.effective_coalesce_window_seconds) ].join("\n\n")
      end

      metadata = {
        "mcp_event_server" => condition.mcp_event_server,
        "mcp_event_name" => condition.mcp_event_name,
        "mcp_event_id" => occurrence.event_id
      }
      metadata["mcp_event_folded_ids"] = folded.map(&:event_id) if folded.any?
      if (message = slack_messages[occurrence.event_id])
        # What lets Zimmer itself answer on the message when the session cannot reach the model
        # (SlackOutageMarker, SlackErrorReply), as a native Slack fire does.
        metadata.merge!(SlackOutageMarker.source_metadata(
          channel_id: message.channel_id, message_ts: message.ts, event_type: message.event_type, thread_ts: message.thread_ts
        ))
      end

      # Held already by #settle; taking it again is a no-op that keeps this safe to call alone.
      Trigger.lock_spawn_for_transaction!(trigger.id)
      session = trigger.create_session!(
        prompt: prompt, session_metadata: metadata, turn_source: (TurnSource.for_genesis(SessionGenesis::SLACK) if message)
      )

      return :held if session.nil?
      return :held if %i[skipped_pending_exists dropped].include?(trigger.last_follow_up_status)
      # The fire that opened a burst spawns the notice about it, not a session for this event. The
      # notice still quotes the event, so it is marked as one whose author was not established.
      if session.metadata.to_h["burst_notice"]
        HumanCapture.mark_incomplete!(session)
        return :held
      end

      HumanCapture.record!(session, condition, [ occurrence, *folded ], slack_messages: slack_messages,
        started: trigger.last_fire_created_session == session)
      session
    end

    # The claim group a coalescing condition files +occurrence+ under, or nil when it does not
    # coalesce it. Claims are per condition, so the key need only name the field and its value.
    def coalescing_group_key(condition, occurrence)
      value = condition.mcp_event_coalesce_value(occurrence.data)
      return nil if value.nil?

      key = "mcp:#{condition.mcp_event_coalesce_key}:#{value}"
      # group_key is a string column; a long value is hashed rather than cut, so two values that
      # share a prefix never share a group.
      key.length > 200 ? "mcp:#{condition.mcp_event_coalesce_key}:sha256:#{Digest::SHA256.hexdigest(value)}" : key
    end

    # The claim group a burst's earlier (or later) event already opened for +group_key+, holding a
    # session to fold into: the nearest one anchored within +window+ seconds of +ts+, on EITHER side.
    #
    # TriggerEventClaim.open_group, which Slack's webhook uses, looks only backwards. Here that
    # would split a burst whenever its events are settled out of order — McpEventWebhookJob runs
    # deliveries on parallel threads, and a group held by skip_if_pending_session or burst control is
    # retried after later events may have fired — and two sessions in one chat is the harm this
    # exists to prevent. Every group still spans at most twice the window around its anchor.
    def open_group(condition, group_key, ts, window)
      TriggerEventClaim
        .where(trigger_condition_id: condition.id, group_key: group_key)
        .where(anchor_ts: (ts - window)..(ts + window))
        .where.not(session_id: nil)
        .order(Arel.sql(TriggerEventClaim.sanitize_sql_array([ "ABS(anchor_ts - ?) ASC", ts ])))
        .first
    end

    # Where an event sits on the coalescing clock: the server's `timestamp`, in epoch seconds, or
    # now for an event that carries none.
    def anchor_ts(occurrence)
      (occurrence.timestamp || Time.current).strftime("%s.%6N").to_d
    end

    # Queue +occurrences+ into +session+ as one note naming them, the way SlackEventJob folds a
    # burst that arrives one message per delivery. A queued message rather than an edit to the
    # prompt: the session may already be running, and the queue is the one sanctioned way to hand
    # it something new. Sessions::ArchiveGuard refuses to archive a session over a message still in
    # it, so the session cannot finish without reading this.
    # The caller holds +session+'s row lock.
    def fold_into_session!(condition, session, occurrences, window:, slack_messages: {})
      from_slack = occurrences.all? { |occurrence| slack_messages[occurrence.event_id] }
      source = from_slack ? TurnSource.for_genesis(SessionGenesis::SLACK) : condition.trigger.turn_source || TurnSource.for_genesis(nil)
      session.enqueued_messages.create!(
        content: folded_events_note(condition, occurrences, window: window, follow_up: true),
        position: Sessions::QueueTail.next_position!(session),
        status: "pending",
        source_context: source.to_h
      )
      HumanCapture.record!(session, condition, occurrences, slack_messages: slack_messages, started: false)
    end

    # How many folded events the note lists one by one, and how much of each.
    MAX_FOLDED_EVENTS_LISTED = 25
    FOLDED_EVENT_EXCERPT = 1_000

    # The block naming the events folded into a coalesced session. Folding is not dropping: the
    # session that survives a burst is told about every event it stands in for.
    #
    # Each event is listed with its time and the payload fields the trigger's template names
    # (`{{event.<field>|...}}`) — the fields whoever configured the trigger decided the session
    # needs — or its whole payload when the template names none. Every payload value is the
    # sender's, so all of them go in ONE `events` fence: a 25-message burst must not repeat the
    # provenance note 25 times. Zimmer's own words — the count, the field name, the window — stay
    # outside it.
    def folded_events_note(condition, occurrences, window:, follow_up: false)
      trigger = condition.trigger
      fields = trigger.prompt_template.to_s.scan(Trigger::EVENT_FIELD_PATTERN).map(&:first).uniq
      listed = occurrences.first(MAX_FOLDED_EVENTS_LISTED)

      lines = listed.map do |occurrence|
        data = occurrence.data.is_a?(Hash) ? occurrence.data.to_h { |field, value| [ field.to_s, value ] } : {}
        shown = fields.any? ? data.slice(*fields) : data
        at = occurrence.timestamp&.utc&.strftime("%H:%M:%S UTC") || "(no time)"
        "- #{at} #{occurrence.event_id}: #{JSON.generate(shown).truncate(FOLDED_EVENT_EXCERPT)}"
      end
      body = [ trigger.render_appended_untrusted(lines.join("\n"), variable: "events_folded", name: "events") ]
      body << "- ...and #{occurrences.length - listed.length} more, not listed individually." if occurrences.length > listed.length

      key = condition.mcp_event_coalesce_key
      name = condition.mcp_event_name
      intro = if follow_up
        "#{occurrences.length == 1 ? 'Another event' : "#{occurrences.length} more events"} of #{name} with the same " \
          "#{key} arrived within #{window}s of the one this session was started for, so Zimmer folded " \
          "#{occurrences.length == 1 ? 'it' : 'them'} into this session rather than starting another. Treat " \
          "#{occurrences.length == 1 ? 'it' : 'them'} as part of the same burst — the first event is not necessarily the whole story."
      else
        "#{occurrences.length} more #{occurrences.length == 1 ? 'event' : 'events'} of #{name} with the same #{key} " \
          "arrived within #{window}s of the one above, so Zimmer folded #{occurrences.length == 1 ? 'it' : 'them'} into " \
          "this session rather than starting one each. Treat them as one burst, in the order the server sent them:"
      end

      [ intro, *body ].join("\n\n")
    end

    def report(condition, error, source:)
      Rails.logger.error "[#{source}] Error processing condition #{condition.id}: #{error.class}: #{error.message}"
      ErrorReporter.report_exception(
        error,
        context: {
          title: "MCP event trigger error",
          source: source,
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) " \
                   "handling #{condition.mcp_event_name} from #{condition.mcp_event_server} failed.",
          condition_id: condition.id,
          trigger_id: condition.trigger_id
        }
      )
    end

    def describe(outcome)
      case outcome
      when Session then "fired session #{outcome.id}"
      when :folded then "folded into the session its burst already started"
      when :held then "not fired yet (burst control, a pending session, or a busy reused session); the poll retries it"
      when :rolled_back then "rolled back (the condition was edited while the event was in hand)"
      when :filtered then "filtered out by payload_filters"
      else outcome.to_s
      end
    end
  end
end

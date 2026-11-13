# frozen_string_literal: true

module McpEvents
  # Claims one event for one `mcp_event` condition and fires its trigger. Both delivery paths come
  # through here: McpEventTriggerPollerJob for each event a poll returns, and McpEventWebhookJob
  # for each one the server POSTs. The claim is TriggerEventClaim's `mcp:<server>:<eventId>` per
  # condition, taken in the same transaction as the spawn, so an event that arrives both ways fires
  # one session and the second path finds the claim and fires nothing.
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

    # Claim and fire one event. Returns a Session, :filtered, :duplicate, :held, :rolled_back (the
    # condition was edited while the event was in hand) or :failed.
    #
    # +subscription+ is the condition's mcp_event_subscription when the event was read; +cursor+ the
    # poll cursor it was read from, or ANY_CURSOR. Either having moved under the lock rolls back.
    def settle(condition, subscription, occurrence, via:, cursor: ANY_CURSOR, log_tag: "McpEvents::Firing")
      return :filtered unless condition.mcp_event_payload_allowed?(occurrence.data)

      key = TriggerEventClaim.mcp_event_key(condition.mcp_event_server, occurrence.event_id)
      outcome = :rolled_back
      ActiveRecord::Base.transaction do
        # Re-read the row under a lock: an edit that landed while the event was in hand must not be
        # written over, and one that changed the subscription makes the event moot.
        condition.lock!
        raise ActiveRecord::Rollback if condition.mcp_event_subscription != subscription
        raise ActiveRecord::Rollback if !cursor.equal?(ANY_CURSOR) && condition.mcp_event_cursor != cursor

        if TriggerEventClaim.claim!(condition, [ key ], via: via).empty?
          outcome = :duplicate
          next
        end

        outcome = fire!(condition, occurrence)
        if outcome.is_a?(Session)
          TriggerEventClaim.attach_session!(condition, [ key ], outcome)
          condition.update!(last_triggered_at: Time.current)
        else
          # Nothing was spawned, so the event is not fired: give the claim back, and the poll
          # tries again from its cursor. What the trigger recorded about the fire it missed
          # (Trigger#record_missed_fire!) still commits.
          TriggerEventClaim.where(trigger_condition_id: condition.id, event_key: key).delete_all
          outcome = :held
        end
      end

      Rails.logger.info "[#{log_tag}] Condition #{condition.id}: event #{key} #{describe(outcome)}" unless outcome == :duplicate
      outcome
    rescue => e
      # One event's failure — a spawn that raised — is that event's, and the poll retries it.
      report(condition, e, source: log_tag)
      :failed
    end

    def fire!(condition, occurrence)
      trigger = condition.trigger
      prompt = trigger.interpolate_prompt(event: "mcp_event", event_id: occurrence.event_id, event_data: occurrence.data)

      # The transaction-scoped spawn lock the other pollers take: a manual invoke, or a second
      # condition on this trigger, must not race this fire's skip and burst checks.
      Trigger.lock_spawn_for_transaction!(trigger.id)
      session = trigger.create_session!(
        prompt: prompt,
        session_metadata: {
          "mcp_event_server" => condition.mcp_event_server,
          "mcp_event_name" => condition.mcp_event_name,
          "mcp_event_id" => occurrence.event_id
        }
      )

      return :held if session.nil?
      return :held if %i[skipped_pending_exists dropped].include?(trigger.last_follow_up_status)
      # The fire that opened a burst spawns the notice about it, not a session for this event.
      return :held if session.metadata.to_h["burst_notice"]

      session
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
      when :held then "not fired yet (burst control, a pending session, or a busy reused session); the poll retries it"
      when :rolled_back then "rolled back (the condition was edited while the event was in hand)"
      when :filtered then "filtered out by payload_filters"
      else outcome.to_s
      end
    end
  end
end

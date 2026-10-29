# frozen_string_literal: true

# Polls catalog MCP servers for events and fires `mcp_event` triggers — the client half of the MCP
# Events extension's poll mode (McpEvents). No agent session is involved: the poll is a plain HTTP
# request from Rails, with the credentials a session would get for the server (McpServerEndpoint).
#
# Every minute, for every `mcp_event` condition on an enabled trigger whose server has not asked
# to be polled later (`nextPollMs`):
#
#   1. a condition with no cursor is BASELINED: one `events/poll` with a null cursor, which by the
#      SEP returns no events and a cursor to poll from. Nothing fires, so turning a trigger on
#      never replays history, as with every other poller;
#   2. otherwise `events/poll` from the stored cursor, following `hasMore` for up to MAX_PAGES;
#   3. each event whose payload passes the condition's `payload_filters` is claimed in
#      TriggerEventClaim under `mcp:<server>:<eventId>` and fires the trigger, in one transaction —
#      ONE SESSION PER EVENT. A claim the condition already holds fires nothing, so a page polled
#      twice fires each event once;
#   4. the cursor moves to the page's cursor only when every event on the page was settled. An event
#      whose fire raised, was held (`skip_if_pending_session`, a reused session that would not take
#      it, burst control) or fell past MAX_FIRES_PER_TICK keeps the cursor where it was; the next
#      tick polls the same page again and the claims skip what already fired. Unlike Slack, burst
#      control DEFERS an event rather than dropping it: the server holds it, so nothing is lost by
#      waiting.
#
# `truncated: true` — the server saying events were skipped (a cursor older than its retention,
# say) — is reported once an hour per condition and stamped on the condition. A server that cannot
# be polled is logged at WARN and counted; MAX_FAILURES_BEFORE_REPORT polls in a row raise a
# report, and when no condition polls cleanly for TriggerPollerLivenessCheckJob's threshold, it
# pages.
#
# Everything in an event's payload is the server's — and on a gateway like strad, ultimately
# whoever wrote the Slack message it relays. It reaches a prompt only through
# Trigger#interpolate_prompt, which fences it or shape-checks it, and never reaches a log line.
class McpEventTriggerPollerJob < ApplicationJob
  queue_as :pollers

  # At most one poll unfinished at a time, like every other poller.
  include SingletonSweep

  # Pages followed per condition per tick while the server says `hasMore`.
  MAX_PAGES = 5

  # Fires per condition per tick. The rest wait on the server for the next ticks, and the trigger's
  # own burst cap (max_sessions_per_minute) still applies on top.
  MAX_FIRES_PER_TICK = 10

  # The soonest a server may ask to be polled again, and the latest. Below the floor is a server
  # asking for more than a once-a-minute cron can give anyway; above the ceiling a misbehaving
  # server could park a condition for hours.
  MIN_NEXT_POLL = 15.seconds
  MAX_NEXT_POLL = 15.minutes

  MAX_FAILURES_BEFORE_REPORT = 5

  TRUNCATION_REPORT_INTERVAL = 1.hour

  # A trigger the poller must not fire for, whatever its conditions say: the form, the API and MCP
  # refuse to save a template that writes a payload field bare, but /supervisor edits conditions on
  # their own, so the poller checks again rather than trust the row.
  class UnfireableTrigger < StandardError; end

  def perform
    conditions = TriggerCondition.mcp_event
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger)

    # Nothing to poll is still liveness — see SlackTriggerPollerJob#perform for why.
    unless conditions.exists?
      PollerHeartbeat.stamp(:mcp_event)
      return
    end

    any_due = false
    any_polled = false
    conditions.find_each do |condition|
      next unless due?(condition)

      any_due = true
      any_polled = true if process_condition(condition)
    rescue McpEvents::Sources::Unavailable, McpApps::Client::Error => e
      record_failure(condition, e)
    rescue => e
      report(condition, e)
    end

    # A tick on which every server asked to be left alone a while longer (`nextPollMs`) is a
    # healthy one too.
    PollerHeartbeat.stamp(:mcp_event) if any_polled || !any_due
  end

  private

  def due?(condition)
    next_at = condition.configuration["next_poll_at"].presence
    next_at.nil? || Time.zone.parse(next_at.to_s).nil? || Time.zone.parse(next_at.to_s) <= Time.current
  end

  def ensure_fireable!(trigger)
    raise UnfireableTrigger, "trigger #{trigger.id} runs a workflow; an mcp_event condition fires only templates" if trigger.workflow_backed?

    bare = trigger.unfenced_mcp_event_fields
    raise UnfireableTrigger, "trigger #{trigger.id} writes event field(s) #{bare.join(', ')} unfenced; write them |untrusted or |id" if bare.any?
  end

  # Returns true when the server answered.
  def process_condition(condition)
    ensure_fireable!(condition.trigger)

    subscription = condition.mcp_event_subscription
    client = McpEvents::Sources.client_for(condition.mcp_event_server)
    cursor = condition.mcp_event_cursor

    if cursor.nil?
      baseline!(condition, client, subscription)
      return true
    end

    MAX_PAGES.times do
      result = client.poll(name: condition.mcp_event_name, arguments: condition.mcp_event_arguments, cursor: cursor)
      note_truncation(condition, subscription, cursor) if result.truncated

      fires = 0
      settled = true
      result.events.each do |occurrence|
        if fires >= MAX_FIRES_PER_TICK
          settled = false
          break
        end

        outcome = settle(condition, subscription, cursor, occurrence)
        fires += 1 if outcome.is_a?(Session) || outcome == :held
        settled = false if %i[held rolled_back failed].include?(outcome)
      end

      moved = advance!(condition, subscription, cursor, settled ? result.cursor : cursor, result.next_poll_ms)
      break unless moved && settled && result.has_more

      cursor = result.cursor
    end

    true
  end

  # The first poll of a condition: take the server's "from now" cursor, fire nothing.
  def baseline!(condition, client, subscription)
    result = client.poll(name: condition.mcp_event_name, arguments: condition.mcp_event_arguments, cursor: nil)
    ActiveRecord::Base.transaction do
      condition.lock!
      raise ActiveRecord::Rollback unless condition.mcp_event_subscription == subscription && condition.mcp_event_cursor.nil?

      condition.update!(
        last_polled_at: Time.current,
        configuration: condition.configuration.merge("cursor" => result.cursor, "failures" => 0)
      )
    end
    Rails.logger.info "[McpEventTriggerPollerJob] Condition #{condition.id} baselined"
  end

  # Claim and fire one event. Returns a Session, :filtered, :duplicate, :held, :rolled_back (the
  # condition was edited mid-poll) or :failed.
  def settle(condition, subscription, cursor, occurrence)
    return :filtered unless condition.mcp_event_payload_allowed?(occurrence.data)

    key = TriggerEventClaim.mcp_event_key(condition.mcp_event_server, occurrence.event_id)
    outcome = :rolled_back
    ActiveRecord::Base.transaction do
      # Re-read the row under a lock: an edit that landed while this tick was polling must not be
      # written over, and one that changed the subscription makes this page moot.
      condition.lock!
      raise ActiveRecord::Rollback if condition.mcp_event_subscription != subscription || condition.mcp_event_cursor != cursor

      if TriggerEventClaim.claim!(condition, [ key ], via: "mcp_event").empty?
        outcome = :duplicate
        next
      end

      outcome = fire!(condition, occurrence)
      if outcome.is_a?(Session)
        TriggerEventClaim.attach_session!(condition, [ key ], outcome)
        condition.update!(last_triggered_at: Time.current)
      else
        # Nothing was spawned, so the event is not fired: give the claim back, and the next tick
        # tries again from the same cursor. What the trigger recorded about the fire it missed
        # (Trigger#record_missed_fire!) still commits.
        TriggerEventClaim.where(trigger_condition_id: condition.id, event_key: key).delete_all
        outcome = :held
      end
    end

    Rails.logger.info "[McpEventTriggerPollerJob] Condition #{condition.id}: event #{key} #{describe(outcome)}" unless outcome == :duplicate
    outcome
  rescue => e
    # One event's failure — a spawn that raised — is that event's, and is retried next tick.
    report(condition, e)
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

    session
  end

  # Moves the cursor (or leaves it, when +new_cursor+ is the old one) and records the poll. Returns
  # false when the condition was edited mid-poll, in which case nothing is written.
  def advance!(condition, subscription, cursor, new_cursor, next_poll_ms)
    moved = false
    ActiveRecord::Base.transaction do
      condition.lock!
      raise ActiveRecord::Rollback if condition.mcp_event_subscription != subscription || condition.mcp_event_cursor != cursor

      condition.update!(
        last_polled_at: Time.current,
        configuration: condition.configuration.merge(
          "cursor" => new_cursor,
          "failures" => 0,
          "next_poll_at" => next_poll_at(next_poll_ms)&.iso8601
        )
      )
      moved = true
    end
    moved
  end

  def next_poll_at(next_poll_ms)
    return nil if next_poll_ms.nil?

    delay = (next_poll_ms / 1000.0).seconds.clamp(MIN_NEXT_POLL, MAX_NEXT_POLL)
    Time.current + delay
  end

  def note_truncation(condition, subscription, cursor)
    last = condition.configuration["last_truncated_at"].presence
    report_due = last.nil? || Time.zone.parse(last.to_s).nil? || Time.zone.parse(last.to_s) < TRUNCATION_REPORT_INTERVAL.ago

    ActiveRecord::Base.transaction do
      condition.lock!
      raise ActiveRecord::Rollback if condition.mcp_event_subscription != subscription || condition.mcp_event_cursor != cursor

      condition.update!(configuration: condition.configuration.merge("last_truncated_at" => Time.current.iso8601))
    end
    return unless report_due

    ErrorReporter.report_message(
      "MCP event trigger missed events",
      context: {
        source: "McpEventTriggerPollerJob",
        details: "#{condition.mcp_event_server} said events of #{condition.mcp_event_name} were skipped " \
                 "(truncated) for condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}). " \
                 "The cursor was older than the server keeps, or the server lost its buffer; those events never fire.",
        condition_id: condition.id,
        trigger_id: condition.trigger_id
      }
    )
  end

  # A server that refused or could not be reached. WARN, so this does not page every minute on its
  # own; the liveness check pages when nothing polls cleanly, and a single condition failing
  # MAX_FAILURES_BEFORE_REPORT times running is reported.
  def record_failure(condition, error)
    failures = condition.configuration["failures"].to_i + 1
    condition.update_columns(configuration: condition.configuration.merge("failures" => failures))
    Rails.logger.warn "[McpEventTriggerPollerJob] Condition #{condition.id} not polled (#{failures} in a row): #{error.class}: #{error.message}"
    report(condition, error) if failures == MAX_FAILURES_BEFORE_REPORT
  end

  def report(condition, error)
    Rails.logger.error "[McpEventTriggerPollerJob] Error processing condition #{condition.id}: #{error.class}: #{error.message}"
    ErrorReporter.report_exception(
      error,
      context: {
        title: "MCP event trigger poller error",
        source: "McpEventTriggerPollerJob",
        details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) " \
                 "polling #{condition.mcp_event_name} from #{condition.mcp_event_server} failed.",
        condition_id: condition.id,
        trigger_id: condition.trigger_id
      }
    )
  end

  def describe(outcome)
    case outcome
    when Session then "fired session #{outcome.id}"
    when :held then "not fired yet (burst control, a pending session, or a busy reused session); retried next tick"
    when :rolled_back then "rolled back (the condition was edited mid-poll)"
    when :filtered then "filtered out by payload_filters"
    else outcome.to_s
    end
  end
end

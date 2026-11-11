# frozen_string_literal: true

# Polls catalog MCP servers for events and fires `mcp_event` triggers — the client half of the MCP
# Events extension's poll mode (McpEvents). No agent session is involved: the poll is a plain HTTP
# request from Rails, with the credentials a session would get for the server (McpServerEndpoint).
#
# Every minute, for every `mcp_event` condition on an enabled trigger whose server has not asked
# to be polled later (`nextPollMs`), and — once a verified webhook subscription carries the
# condition's events — every PUSH_CATCH_UP_INTERVAL instead:
#
#   1. a condition with no cursor is BASELINED: one `events/poll` with a null cursor, which by the
#      SEP returns no events and a cursor to poll from. Nothing fires, so turning a trigger on
#      never replays history, as with every other poller;
#   2. otherwise `events/poll` from the stored cursor, following `hasMore` for up to MAX_PAGES;
#   3. each event whose payload passes the condition's `payload_filters` is claimed in
#      TriggerEventClaim under `mcp:<server>:<eventId>` and fires the trigger, in one transaction —
#      ONE SESSION PER EVENT (McpEvents::Firing, shared with the webhook receiver). A claim the
#      condition already holds fires nothing, so a page polled twice fires each event once, and an
#      event the server also POSTed to Zimmer's webhook receiver fires once;
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

  # How often a condition is polled while a verified webhook subscription carries its events
  # (McpEventWebhookSubscription#healthy?). The poll is then only the catch-up path — for a
  # delivery the server gave up on, one held by burst control, or a subscription that lapsed
  # without Zimmer noticing — so it can afford to be slow. Fifteen minutes is the same ceiling a
  # server's own `nextPollMs` is clamped to. It assumes the server keeps at least this much poll
  # history; one that keeps less answers the catch-up poll with `truncated`, which this job reports
  # as missed events even when push already fired them.
  PUSH_CATCH_UP_INTERVAL = 15.minutes

  def perform
    conditions = TriggerCondition.mcp_event
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger, :mcp_event_webhook_subscriptions)

    # Nothing to poll is still liveness — see SlackTriggerPollerJob#perform for why.
    unless conditions.exists?
      PollerHeartbeat.stamp(:mcp_event)
      return
    end

    any_due = false
    any_polled = false
    conditions.find_each do |condition|
      unless due?(condition)
        # Backing off after failures is not health: it still counts as a condition that did not
        # poll cleanly, so a server that keeps failing still stops the heartbeat.
        any_due = true if condition.configuration["failures"].to_i.positive?
        next
      end

      any_due = true
      any_polled = true if process_condition(condition)
    rescue McpEvents::Sources::Unavailable, McpApps::Client::Error => e
      record_failure(condition, e)
    rescue => e
      report(condition, e)
    end

    # A tick on which every healthy server asked to be left alone a while longer (`nextPollMs`) is
    # a healthy one too.
    PollerHeartbeat.stamp(:mcp_event) if any_polled || !any_due
  end

  private

  def due?(condition)
    next_at = Time.zone.parse(condition.configuration["next_poll_at"].to_s)
    return false unless next_at.nil? || next_at <= Time.current

    # A verified webhook subscription is carrying the events; poll only to catch up.
    if condition.mcp_event_cursor && condition.last_polled_at && condition.mcp_event_push_healthy?
      return condition.last_polled_at <= PUSH_CATCH_UP_INTERVAL.ago
    end

    true
  end

  # Returns true when the server answered.
  def process_condition(condition)
    McpEvents::Firing.ensure_fireable!(condition.trigger)

    subscription = condition.mcp_event_subscription
    client = McpEvents::Sources.client_for(condition.mcp_event_server)
    cursor = condition.mcp_event_cursor

    if cursor.nil?
      baseline!(condition, client, subscription)
      return true
    end

    # While the trigger's burst is open every fire is refused, and each refusal counts toward the
    # window that keeps it open — so a backlog retried into an open burst would hold it open for
    # good. The events wait on the server until the burst closes.
    return true if condition.trigger.reload.bursting?

    fires = 0
    MAX_PAGES.times do
      result = client.poll(name: condition.mcp_event_name, arguments: condition.mcp_event_arguments, cursor: cursor)
      note_truncation(condition, subscription, cursor) if result.truncated

      settled = true
      result.events.each do |occurrence|
        if fires >= MAX_FIRES_PER_TICK
          settled = false
          break
        end

        outcome = McpEvents::Firing.settle(condition, subscription, occurrence,
          via: "mcp_event", cursor: cursor, log_tag: "McpEventTriggerPollerJob")
        fires += 1 if outcome.is_a?(Session)
        next unless %i[held rolled_back failed].include?(outcome)

        # Stop at the first event that did not settle: the ones after it would fire ahead of it,
        # and a cause that holds or breaks one usually holds or breaks the next.
        settled = false
        break
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
  #
  # A failing server is backed off — one minute after the first failure, doubling to
  # MAX_NEXT_POLL — so one unreachable server does not hold the single `pollers` thread every tick.
  def record_failure(condition, error)
    failures = nil
    condition.with_lock do
      failures = condition.configuration["failures"].to_i + 1
      backoff = [ (2**(failures - 1)).minutes, MAX_NEXT_POLL ].min
      condition.update_columns(configuration: condition.configuration.merge(
        "failures" => failures, "next_poll_at" => (Time.current + backoff).iso8601
      ))
    end
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
end

# frozen_string_literal: true

# Holds the MCP Events webhook subscriptions behind `mcp_event` conditions (SEP-3415 @ b08e4f9,
# "Webhook-Based Delivery"). Every minute it does two passes.
#
#   1. RETIRE. A row whose condition was deleted, whose trigger is no longer enabled, whose
#      condition now listens for a different (server, event, arguments), or whose callback URL is
#      not on Zimmer's current public base URL is unsubscribed (`events/unsubscribe`) and deleted.
#      A row that never subscribed, or whose grant has already run out, is deleted with no call,
#      because the server has nothing left to reclaim. An unsubscribe that fails is retried with
#      backoff until it succeeds or the grant runs out.
#   2. SUBSCRIBE. For each `mcp_event` condition on an enabled trigger whose event type lists
#      `webhook` in the server's `events/list` (read through McpEvents::Sources.probe, cached ten
#      minutes), a row is minted with a fresh `whsec_` secret and URL and `events/subscribe` is
#      called with the condition's poll cursor. After that the row is refreshed (the same call, with
#      the row's own cursor) before the server's `refreshBefore`. The server answers only after
#      Webhooks::McpEventsController has echoed its verification challenge. A failure is retried
#      with backoff, and the condition polls as it always did in the meantime.
#
# Nothing happens without a public `https` base URL (McpEvents.webhook_base_url). A local or
# placeholder host could never be reached, and with no base URL every row is retired.
class McpEventSubscriptionsJob < ApplicationJob
  queue_as :default

  include SingletonSweep

  # The lifetime Zimmer asks for. The SEP's guidance is minutes to a day; six hours is four
  # refreshes a day, and a subscription Zimmer stops refreshing (a deleted deployment) lapses in
  # hours rather than days.
  REQUESTED_TTL = 6.hours

  # Refresh this long before `refreshBefore` — or at half the grant, if the server granted less.
  REFRESH_MARGIN = 30.minutes

  # How often a no-expiry grant (which Zimmer never asks for) is refreshed anyway, so the cursor and
  # `deliveryStatus` stay current.
  NO_EXPIRY_REFRESH = REQUESTED_TTL

  # The longest a live subscription goes without a refresh, whatever its grant. A server that
  # suspended delivery after a run of failures (Zimmer down, the Access policy refusing it) resumes
  # only on a refresh, and the refresh is also the one place `deliveryStatus` is read. So an hourly
  # refresh bounds both how long a recovered endpoint waits for its backlog and how long a failing
  # route goes unnoticed. The server caches verification per URL, so this costs one call, not a
  # challenge.
  HEALTH_REFRESH = 1.hour

  # Backoff after a failed subscribe or unsubscribe: a minute, doubling, to this.
  MAX_BACKOFF = 6.hours

  # How the receiver marks a row the server terminated (Webhooks::McpEventsController).
  TERMINATED_PREFIX = "terminated by the server"

  def perform
    base_url = McpEvents.webhook_base_url
    retire_stale(base_url)
    ensure_subscriptions(base_url) if base_url
  end

  private

  def retire_stale(base_url)
    McpEventWebhookSubscription.includes(trigger_condition: :trigger).find_each do |row|
      # A secret that no longer decrypts (a rotated secret_key_base) can verify nothing: retire the
      # row, and the next pass subscribes again with a fresh one.
      next if base_url && row.live? && row.matches?(row.trigger_condition, base_url: base_url) && row.secret

      retire(row)
    rescue => e
      report(row, e, "retiring")
    end
  end

  def ensure_subscriptions(base_url)
    TriggerCondition.mcp_event
      .joins(:trigger).where(triggers: { status: "enabled" })
      .includes(:trigger, :mcp_event_webhook_subscriptions)
      .find_each do |condition|
        row = condition.mcp_event_webhook_subscription
        next if row && !due?(row)

        offered = webhook_offered?(condition)
        next if offered.nil?

        unless offered
          # The server stopped offering webhook delivery for this event: back to polling alone.
          retire(row) if row
          next
        end

        row ||= McpEventWebhookSubscription.build_for(condition, base_url: base_url).tap(&:save!)
        subscribe(row, condition)
      rescue => e
        report(row || condition, e, "subscribing")
      end
  end

  # true / false, or nil when the server could not be asked (decide nothing this tick).
  def webhook_offered?(condition)
    source = McpEvents::Sources.probe(condition.mcp_event_server)
    descriptor = source&.find_event(condition.mcp_event_name)
    descriptor.present? && descriptor.webhook?
  rescue McpEvents::Sources::Unavailable => e
    Rails.logger.info "[McpEventSubscriptionsJob] Condition #{condition.id}: #{e.message}"
    nil
  end

  def due?(row, now = Time.current)
    return false if row.next_attempt_at && row.next_attempt_at > now
    return true if %w[pending failed].include?(row.state)
    return true if row.subscribed_at && now >= row.subscribed_at + HEALTH_REFRESH
    return now >= row.subscribed_at + NO_EXPIRY_REFRESH if row.refresh_before.nil?

    granted = row.subscribed_at ? row.refresh_before - row.subscribed_at : REQUESTED_TTL
    margin = [ REFRESH_MARGIN, granted / 2 ].min
    now >= row.refresh_before - margin
  end

  def subscribe(row, condition)
    client = McpEvents::Sources.client_for(row.server)
    # A first subscribe starts from where the condition's poll is; a refresh hands back the last
    # cursor the server gave this row, as the SEP has every refresh do.
    cursor = row.subscribed_at ? row.cursor : condition.mcp_event_cursor
    error_before = row.last_error
    result = client.subscribe(
      name: row.event_name, arguments: row.arguments, url: row.callback_url, secret: row.secret,
      cursor: cursor, ttl_ms: REQUESTED_TTL.in_milliseconds.to_i
    )
    if result.truncated
      Rails.logger.warn "[McpEventSubscriptionsJob] #{row.server} started subscription #{row.id} (#{row.event_name}) later than its cursor " \
                        "(truncated); the condition's poll catches up on what the server still holds"
    end

    status = result.delivery_status || {}
    # `active: false` is a suspension the refresh has just lifted; `lastError` with `failedSince` is
    # a server still failing to deliver. Either way push is not proven, so the poller keeps its
    # minute cadence until a signed request arrives again. A `lastError` without `failedSince` is a
    # past failure the server merely still reports, which is not one.
    failing = status["active"] == false || (status["lastError"].present? && status["failedSince"].present?)
    row.with_lock do
      # A `terminated` envelope that landed while the call was in flight wins: the server has
      # dropped what this answer describes, so writing it would make a dead subscription look live.
      if row.state == "pending" && row.last_error.to_s.start_with?(TERMINATED_PREFIX) && row.last_error != error_before
        Rails.logger.info "[McpEventSubscriptionsJob] Subscription #{row.id} was terminated during its subscribe; leaving it to the next sweep"
        next
      end

      state = if failing then "suspended"
      elsif row.recently_verified? then "verified"
      else "subscribed"
      end
      row.update!(
        state: state, remote_id: result.id.truncate(255), subscribed_at: Time.current, refresh_before: result.refresh_before,
        cursor: result.cursor || row.cursor, delivery_status: result.delivery_status, failures: 0, next_attempt_at: nil,
        last_error: failing ? "server reports failing delivery (#{delivery_error_category(status['lastError'])})" : nil
      )
      Rails.logger.info "[McpEventSubscriptionsJob] Subscription #{row.id} (condition #{condition.id}) #{state} until #{result.refresh_before&.iso8601 || 'no expiry'}"
    end
  rescue McpEvents::Sources::Unavailable, McpApps::Client::Error => e
    back_off(row, "subscribe failed: #{describe_error(e)}", state: row.subscribed_at && row.refresh_before&.future? ? row.state : "failed")
  end

  def retire(row, now = Time.current)
    if row.subscribed_at.nil? || (row.refresh_before && row.refresh_before <= now)
      row.destroy!
      return
    end
    return if row.next_attempt_at && row.next_attempt_at > now

    McpEvents::Sources.client_for(row.server).unsubscribe(name: row.event_name, arguments: row.arguments, url: row.callback_url)
    row.destroy!
    Rails.logger.info "[McpEventSubscriptionsJob] Unsubscribed and deleted subscription #{row.id} (#{row.server} #{row.event_name})"
  rescue McpApps::Client::RpcError => e
    if McpEvents.error_name(e.code) == :not_found
      row.destroy!
    else
      back_off(row, "unsubscribe failed: #{describe_error(e)}")
    end
  rescue McpEvents::Sources::Unavailable, McpApps::Client::Error => e
    back_off(row, "unsubscribe failed: #{describe_error(e)}")
  end

  def back_off(row, message, state: row.state)
    failures = row.failures + 1
    delay = [ (2**(failures - 1)).minutes, MAX_BACKOFF ].min
    row.update_columns(state: state, failures: failures, next_attempt_at: Time.current + delay, last_error: message.truncate(255), updated_at: Time.current)
    Rails.logger.warn "[McpEventSubscriptionsJob] Subscription #{row.id} (#{row.server} #{row.event_name}): #{message}; retrying in #{delay.inspect}"
  end

  # What the trigger UI may show: the extension's error name and, for a callback failure, one of
  # the SEP's fixed categories. Never the server's free-text message, which could carry anything;
  # a transport failure's message is Zimmer's own.
  def describe_error(error)
    return error.message.truncate(150) unless error.is_a?(McpApps::Client::RpcError)

    name = McpEvents.error_name(error.code) || "error #{error.code.to_i}"
    reason = error.data.is_a?(Hash) ? delivery_error_category(error.data["reason"]) : nil
    reason && name == :callback_endpoint_error ? "#{name} (#{reason})" : name.to_s
  end

  def delivery_error_category(value)
    McpEvents::DELIVERY_ERROR_CATEGORIES.include?(value) ? value : "unspecified"
  end

  def report(record, error, doing)
    Rails.logger.error "[McpEventSubscriptionsJob] Error #{doing} #{record.class.name} #{record.id}: #{error.class}: #{error.message}"
    ErrorReporter.report_exception(error, context: { title: "MCP event webhook subscription error", source: self.class.name,
                                                     details: "#{doing} #{record.class.name} #{record.id} failed." })
  end
end

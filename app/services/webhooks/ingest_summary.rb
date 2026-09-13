# frozen_string_literal: true

module Webhooks
  # Whether each webhook source is delivering, and which path has been firing its triggers.
  #
  # Read from the two tables the ingress writes: WebhookDelivery (every delivery that verified) and
  # TriggerEventClaim (every event a trigger condition fired on, and whether the webhook or the
  # poller claimed it). Both are listed row by row in /supervisor; this is the summary an operator
  # or an agent reads at a glance, carried on /health, `GET /api/v1/health` and `get_system_health`
  # through HealthMonitorService#inbound_event_health.
  #
  # The number it exists for is the poll claim count. A poller claims an event only while its
  # source's webhook is switched on (SlackTriggerFiring#fire_slack_event), so every `poll` claim is
  # an event the poller reached before the webhook did — a delivery the provider dropped, or one
  # that arrived after the next poll. While `webhook_with_poll_fallback` is on, that count staying at
  # zero is the evidence that the poller can go.
  class IngestSummary
    WINDOW = 24.hours

    def self.report(now: Time.current)
      new(now: now).report
    end

    def initialize(now: Time.current)
      @now = now
      @since = now - WINDOW
    end

    def report
      claims = claim_counts
      sources = Source.all.map { |source| source_reading(source, claims.fetch(source.name, {})) }

      {
        window_seconds: WINDOW.to_i,
        sources: sources,
        status: status(sources)
      }
    end

    private

    # Both queries ride the `created_at` indexes: the newest delivery is one backward index step,
    # and the window is a range scan over a day of rows.
    def source_reading(source, claims)
      deliveries = WebhookDelivery.where(source: source.name)
      webhook = claims.fetch("webhook", 0)
      poll = claims.fetch("poll", 0)

      {
        name: source.name,
        mode: source.mode,
        webhook_enabled: source.webhook_enabled?,
        accepting: source.accepting?,
        last_delivery_at: deliveries.order(created_at: :desc).limit(1).pick(:created_at),
        deliveries_in_window: deliveries.where(created_at: @since..).count,
        webhook_claims_in_window: webhook,
        poll_claims_in_window: poll
      }
    end

    # { "slack" => { "webhook" => 3, "poll" => 1 } }. An event key starts with its source's name
    # (TriggerEventClaim.slack_event_key), which is how a claim is attributed without a join.
    def claim_counts
      TriggerEventClaim
        .where(created_at: @since..)
        .group(Arel.sql("split_part(event_key, ':', 1)"), :claimed_via)
        .count
        .each_with_object({}) { |((source, via), count), out| (out[source] ||= {})[via] = count }
    end

    # Warning for a source whose webhook is switched on but cannot verify anything, and for one the
    # poller has had to back up. Healthy otherwise, including a source that polls: that is the
    # default and changes nothing.
    def status(sources)
      unverifiable = sources.select { |s| s[:webhook_enabled] && !s[:accepting] }
      missed = sources.select { |s| s[:webhook_enabled] && s[:poll_claims_in_window].positive? }

      if unverifiable.any? || missed.any?
        messages = unverifiable.map { |s| "#{s[:name]}: webhook is switched on but has no signing secret, so its endpoint answers 404" }
        messages += missed.map { |s| missed_message(s) }
        return HealthMonitorService::HealthStatus.new(status: :warning, message: messages.join("; "))
      end

      enabled = sources.select { |s| s[:webhook_enabled] }
      return HealthMonitorService::HealthStatus.new(status: :healthy, message: "Every source polls; no webhook is switched on") if enabled.empty?

      HealthMonitorService::HealthStatus.new(status: :healthy, message: enabled.map { |s| healthy_message(s) }.join("; "))
    end

    def missed_message(source)
      total = source[:webhook_claims_in_window] + source[:poll_claims_in_window]
      "#{source[:name]}: #{source[:poll_claims_in_window]} of #{total} trigger fire(s) in the last 24h were claimed " \
        "by the poller — events the webhook did not deliver first"
    end

    def healthy_message(source)
      last = source[:last_delivery_at]
      delivered = last ? "last delivery #{HealthMonitorService.format_wait(@now - last)} ago" : "no delivery in the last 7 days"
      "#{source[:name]}: #{delivered}, #{source[:webhook_claims_in_window]} trigger fire(s) in the last 24h, none by the poller"
    end
  end
end

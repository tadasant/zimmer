# frozen_string_literal: true

module Webhooks
  # Whether each webhook source is delivering, and which path has been claiming its trigger events.
  #
  # Read from the two tables the ingress writes: WebhookDelivery (every delivery that verified) and
  # TriggerEventClaim (every event a trigger condition fired on or folded, and whether the webhook
  # or the poller claimed it). Both are listed row by row in /supervisor; this is the summary an
  # operator or an agent reads at a glance, carried on /health, `GET /api/v1/health` and
  # `get_system_health` through HealthMonitorService#inbound_event_health.
  #
  # The number it exists for is the poll claim count. A poller claims an event only while its
  # source's webhook is switched on (SlackTriggerFiring#fire_slack_event), and the webhook races it
  # only for the conditions it serves (Source#served_conditions). So a `poll` claim on one of those
  # is an event the poller reached before the webhook did — a delivery the provider dropped, or one
  # that arrived after the next poll. Claims on conditions the webhook never serves, such as Slack's
  # passive listening, are not counted: the poller claims every one of them by design. While
  # `webhook_with_poll_fallback` is on, the count staying at zero is the evidence that the poller
  # can go.
  #
  # A claim is one event for one condition, not one session: a coalesced burst is a claim per
  # message, and a message two conditions match is two claims.
  #
  # A source in `webhook_shadow` (GitHub only) claims nothing, so its claim counts stay at zero. Its
  # reading carries `shadow` instead: Webhooks::GithubShadowComparison over the same window, which
  # pairs what the webhook would have fired with what the poller fired. There the number that says
  # the webhook is ready is webhook-only plus poll-only staying at zero.
  class IngestSummary
    WINDOW = 24.hours
    SHADOW_RECENT = 10

    def self.report(now: Time.current)
      new(now: now).report
    end

    def initialize(now: Time.current)
      @now = now
      @since = now - WINDOW
    end

    def report
      readings = Source.all.to_h { |source| [ source, source_reading(source) ] }

      {
        window_seconds: WINDOW.to_i,
        sources: readings.values,
        status: status(readings)
      }
    end

    private

    # Every read is bounded by `created_at`, so each rides that index: the newest delivery is a
    # backward step from the retention horizon, and the window is a range scan over a day of rows.
    def source_reading(source)
      deliveries = WebhookDelivery.where(source: source.name)
      claims = claim_counts(source)

      {
        name: source.name,
        mode: source.mode,
        webhook_enabled: source.webhook_enabled?,
        shadow: source.shadow? ? GithubShadowComparison.report(now: @now, since: @since, recent: SHADOW_RECENT, recent_unmatched: true) : nil,
        receiving: source.receiving?,
        accepting: source.accepting?,
        last_delivery_at: deliveries.where(created_at: (@now - WebhookDelivery::RETENTION)..)
                                    .order(created_at: :desc).limit(1).pick(:created_at),
        deliveries_in_window: deliveries.where(created_at: @since..).count,
        webhook_claims_in_window: claims.fetch("webhook", 0),
        poll_claims_in_window: claims.fetch("poll", 0)
      }
    end

    # { "webhook" => 3, "poll" => 1 } for the claims on +source+'s served conditions. An event key
    # starts with its source's name (TriggerEventClaim.slack_event_key).
    def claim_counts(source)
      TriggerEventClaim
        .where(created_at: @since..)
        .where("trigger_event_claims.event_key LIKE ?", "#{TriggerEventClaim.sanitize_sql_like(source.name)}:%")
        .where(trigger_condition_id: source.served_conditions.select(:id))
        .group(:claimed_via)
        .count
    end

    # Warning for a switched-on source that cannot verify anything, one that has received nothing,
    # and one the poller has had to back up. Healthy otherwise, including a source that polls: that
    # is the default and changes nothing.
    def status(readings)
      enabled = readings.select { |_source, reading| reading[:receiving] }
      return healthy("Every source polls; no webhook is switched on") if enabled.empty?

      warnings = enabled.filter_map { |source, reading| warning_message(source, reading) }
      return HealthMonitorService::HealthStatus.new(status: :warning, message: warnings.join("; ")) if warnings.any?

      healthy(enabled.values.map { |reading| healthy_message(reading) }.join("; "))
    end

    # A silent window warns only for a source that delivers every day in normal operation (Slack,
    # which sends every message the bot can see). GitHub sends an event only when an issue changes.
    def warning_message(source, reading)
      name = reading[:name]

      if !reading[:accepting]
        "#{name}: webhook is switched on but has no signing secret, so its endpoint answers 404"
      elsif (shadow = reading[:shadow])
        # In shadow the poller claims nothing, so a poll claim in the window is left from an earlier
        # fallback spell and says nothing about the webhook now.
        totals = shadow[:totals]
        return nil unless (totals[:webhook_only] + totals[:poll_only]).positive?

        "#{name}: shadow — in the last #{window_label} the webhook would have fired #{totals[:webhook_only]} event(s) the " \
          "poller did not, and missed #{totals[:poll_only]} the poller fired (#{totals[:matched]} matched)"
      elsif reading[:poll_claims_in_window].positive?
        total = reading[:webhook_claims_in_window] + reading[:poll_claims_in_window]
        "#{name}: the poller claimed #{reading[:poll_claims_in_window]} of #{total} trigger event(s) in the last " \
          "#{window_label} — events the webhook did not deliver first"
      elsif reading[:deliveries_in_window].zero? && source.expects_daily_deliveries
        "#{name}: webhook is accepting but received no delivery in the last #{window_label} — " \
          "check that the provider can reach its endpoint"
      end
    end

    def healthy_message(reading)
      last = reading[:last_delivery_at]
      delivered = last ? "last delivery #{HealthMonitorService.format_wait(@now - last)} ago" : "no delivery in the last #{retention_label}"
      return "#{reading[:name]}: #{delivered}; #{shadow_message(reading[:shadow])}" if reading[:shadow]

      "#{reading[:name]}: #{delivered}; the webhook claimed #{reading[:webhook_claims_in_window]} trigger event(s) in the last " \
        "#{window_label}, the poller none"
    end

    def shadow_message(shadow)
      totals = shadow[:totals]
      lead = shadow[:latency][:median_seconds]
      ahead = if lead.nil? then ""
      elsif lead.negative? then ", the poller ahead by a median #{HealthMonitorService.format_wait(-lead)}"
      else ", the webhook ahead by a median #{HealthMonitorService.format_wait(lead)}"
      end
      "shadow — the webhook and the poller agreed on all #{totals[:matched]} event(s) in the last #{window_label}#{ahead}" \
        "#{"; #{totals[:pending]} still pending" if totals[:pending].positive?}"
    end

    def retention_label
      "#{(WebhookDelivery::RETENTION / 1.day).to_i} days"
    end

    def healthy(message)
      HealthMonitorService::HealthStatus.new(status: :healthy, message: message)
    end

    def window_label
      "#{(WINDOW / 1.hour).to_i}h"
    end
  end
end

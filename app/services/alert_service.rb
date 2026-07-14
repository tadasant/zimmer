# frozen_string_literal: true

# Service for raising critical operational alerts to the #eng-alerts Slack channel.
#
# Features:
# - Simple API: AlertService.raise_alert("Title", details: "...", source: "JobName")
# - Deduplication/throttling via Rails cache (Redis) to prevent alert spam
# - Well-formatted Slack Block Kit messages
# - Graceful degradation if Slack is unavailable
#
# Usage:
#   AlertService.raise_alert("Trigger firing error",
#     details: "Agent root 'pulse-directory-management' not found in catalog",
#     source: "ScheduleTriggerJob")
#
#   AlertService.raise_alert("Slack trigger poller error",
#     details: "Condition 42 on trigger 'deploy-notify' failed:\nSlack API timeout",
#     source: "SlackTriggerPollerJob",
#     dedup_key: "slack_trigger_condition_42")
class AlertService
  # How long to suppress duplicate alerts with the same dedup key
  DEDUP_WINDOW = 1.hour

  # Cache key prefix for deduplication
  CACHE_PREFIX = "alert_service:dedup:"

  # Environments whose alerts may reach the #eng-alerts Slack channel.
  #
  # The `configured?` check does NOT keep test and development quiet, because a
  # Slack token proves nothing about which environment is holding it. Zimmer runs
  # its agent sessions *inside the production container*, so every agent-session
  # shell inherits production's SLACK_BOT_TOKEN and ENG_ALERTS_SLACK_CHANNEL_ID:
  # a `RAILS_ENV=test bin/rails test` in an agent's repo clone is "configured" in
  # exactly the way production is, and any alert a test exercises then pages the
  # on-call channel with fixture data. That is not hypothetical — it happened, and
  # the fixture ids in the resulting alerts were read back as a production outage.
  #
  # Sentry's `enabled_environments` closes this same hole on the exception path
  # (config/initializers/sentry.rb, issue #176). This closes it on the alert path.
  # Only Rails.env can tell the two apart, so only Rails.env is trusted here.
  ENABLED_ENVIRONMENTS = %w[production staging].freeze

  class << self
    # Whether this process is allowed to page the alert channel at all.
    # @return [Boolean]
    def alerting_enabled?
      ENABLED_ENVIRONMENTS.include?(Rails.env)
    end

    # Raise an operational alert to #eng-alerts
    #
    # When an AlertBatcher block is open on the current thread, the alert is
    # recorded in the batch and emitted (possibly collapsed with other alerts
    # sharing the same title+source) on block exit. Otherwise it is emitted
    # immediately.
    #
    # @param title [String] Short alert title (e.g. "Trigger firing error")
    # @param details [String] Detailed error message or context
    # @param source [String] The job/service raising the alert (e.g. "ScheduleTriggerJob")
    # @param dedup_key [String, nil] Custom deduplication key. If nil, derived from title + source.
    # @return [Boolean] true if alert was sent/batched, false if suppressed or failed
    def raise_alert(title, details: nil, source: nil, dedup_key: nil)
      return false unless alerting_enabled_for?(title, source)

      key = dedup_key || default_dedup_key(title, source)

      if AlertBatcher.open?
        return AlertBatcher.record(title, details: details, source: source, dedup_key: key)
      end

      emit(title, details: details, source: source, dedup_key: key)
    rescue => e
      logger.error("Failed to raise alert", title: title, error: e.message)
      false
    end

    # Emit an alert immediately, bypassing any open AlertBatcher. Called by
    # AlertBatcher on flush to post the (possibly aggregated) Slack message.
    #
    # This is effectively the non-batching core of raise_alert, extracted so
    # the batcher can reuse the dedup + Slack-post logic on flush.
    def emit(title, details:, source:, dedup_key:)
      # AlertBatcher.flush! calls emit directly, bypassing raise_alert. Guarding
      # only raise_alert would leave that second door into Slack open.
      return false unless alerting_enabled_for?(title, source)

      if suppressed?(dedup_key)
        logger.info("Alert suppressed (duplicate within #{DEDUP_WINDOW.inspect})", title: title, source: source, dedup_key: dedup_key)
        return false
      end

      sent = post_to_slack(title, details: details, source: source)
      mark_sent(dedup_key) if sent
      sent
    end

    # Check if the service is configured and ready to send alerts
    # @return [Boolean] true if Slack is configured and channel ID is available
    def configured?
      SlackService.configured? && channel_id.present?
    end

    # Returns a list of missing configuration components, or an empty array if fully configured.
    # Used by the boot-time health check initializer to provide actionable diagnostics.
    # @return [Array<String>] list of missing components (e.g. ["Slack token missing"])
    def missing_configuration_details
      details = []
      details << "Slack token missing" unless SlackService.configured?
      details << "ENG_ALERTS_SLACK_CHANNEL_ID missing" unless channel_id.present?
      details
    end

    # Reset internal state (for testing)
    def reset!
      @logger = nil
    end

    private

    # Declines — loudly, to the local log — when this environment may not alert.
    # The alert still has somewhere to go (stdout), it just does not go to Slack,
    # and critically it does not touch the dedup cache: a dropped alert must not
    # consume the window that would otherwise silence the same alert in production.
    def alerting_enabled_for?(title, source)
      return true if alerting_enabled?

      logger.info(
        "Alert suppressed (#{Rails.env} is not an alerting environment)",
        title: title, source: source, enabled_environments: ENABLED_ENVIRONMENTS
      )
      false
    end

    def channel_id
      SecretsLoader.get("ENG_ALERTS_SLACK_CHANNEL_ID") || ENV["ENG_ALERTS_SLACK_CHANNEL_ID"]
    end

    def logger
      @logger ||= StructuredLogger.new({ service: "AlertService" })
    end

    # Check if an alert with this key was already sent within the dedup window
    def suppressed?(key)
      Rails.cache.exist?(cache_key(key))
    rescue => e
      logger.warn("Cache check failed, allowing alert through", error: e.message)
      false
    end

    # Mark an alert as sent in the cache
    def mark_sent(key)
      Rails.cache.write(cache_key(key), true, expires_in: DEDUP_WINDOW)
    rescue => e
      logger.warn("Cache write failed", error: e.message)
    end

    def cache_key(key)
      "#{CACHE_PREFIX}#{key}"
    end

    def default_dedup_key(title, source)
      Digest::SHA256.hexdigest("#{title}:#{source}")[0..15]
    end

    # Post a formatted alert message to the #eng-alerts Slack channel
    def post_to_slack(title, details: nil, source: nil)
      unless configured?
        logger.warn("AlertService not configured (missing Slack token or channel ID)")
        return false
      end

      blocks = build_slack_blocks(title, details: details, source: source)

      SlackService.client.chat_postMessage(
        channel: channel_id,
        text: build_fallback_text(title, details: details, source: source),
        blocks: blocks
      )

      logger.info("Alert sent to #eng-alerts", title: title, source: source)
      true
    rescue Slack::Web::Api::Errors::SlackError, Faraday::Error => e
      logger.error("Slack API error sending alert", title: title, error: e.message)
      false
    end

    # Build the fallback text for the Slack message. Slack uses this for push
    # notifications, accessibility tools, and any consumer that doesn't render
    # blocks (e.g., the slack-workspace MCP only exposes `text:`). It must
    # carry the diagnostic body so block-blind consumers see more than just
    # the title.
    def build_fallback_text(title, details: nil, source: nil)
      parts = [ title ]
      parts << "Source: #{source}" if source.present?
      parts << details if details.present?
      # Slack's text field has no hard size cap like blocks, but keep it
      # bounded so push notification UX stays sane.
      parts.join("\n").truncate(3500)
    end

    # Build Slack Block Kit blocks for a well-formatted alert message
    def build_slack_blocks(title, details: nil, source: nil)
      blocks = []

      # Header
      blocks << {
        type: "header",
        text: { type: "plain_text", text: title.truncate(150), emoji: true }
      }

      # Details section
      if details.present?
        # Truncate details to stay within Slack's 3000 char limit for section text
        truncated = details.truncate(2800)
        blocks << {
          type: "section",
          text: { type: "mrkdwn", text: truncated }
        }
      end

      # Context: source and timestamp
      context_elements = []
      context_elements << { type: "mrkdwn", text: "*Source:* #{source}" } if source.present?
      context_elements << { type: "mrkdwn", text: "*Time:* #{Time.current.strftime('%Y-%m-%d %H:%M:%S UTC')}" }

      blocks << { type: "context", elements: context_elements }

      blocks
    end
  end
end

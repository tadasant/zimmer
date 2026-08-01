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
#     details: "Condition 42 on trigger 'deploy-notify' failed.",
#     source: "SlackTriggerPollerJob",
#     dedup_key: "slack_trigger_condition_42",
#     error: e)
#
# Pass the rescued exception as `error:` wherever one exists. AlertSnippet turns
# it into a bounded, high-signal excerpt (class, message, the frames that
# matter) rendered as a fenced code block — `details:` is for the prose a human
# needs on top of that, not for a hand-copied `e.message`.
class AlertService
  # How long to suppress duplicate alerts with the same dedup key
  DEDUP_WINDOW = 1.hour

  # Cache key prefix for deduplication
  CACHE_PREFIX = "alert_service:dedup:"

  # Upper bound on the Slack `text:` field. Slack imposes no hard cap there, but
  # it drives push notifications, so keep it sane.
  FALLBACK_TEXT_MAX_CHARS = 3500

  # Upper bound on the details section block. Slack's section text limit is 3000.
  DETAILS_SECTION_MAX_CHARS = 2800

  # Floor for title + source + details in the `text:` field, so a large snippet
  # can never squeeze the framing down to nothing.
  MIN_FRAMING_TEXT_CHARS = 400

  class << self
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
    # @param error [Exception, String, nil] The rescued exception (preferred) or raw log output
    #   behind this alert. Rendered as a bounded excerpt; see AlertSnippet.
    # @return [Boolean] true if alert was sent/batched, false if suppressed or failed
    def raise_alert(title, details: nil, source: nil, dedup_key: nil, error: nil)
      # The dedup key is derived from title + source only, never from the
      # snippet. Snippet content varies per occurrence (timestamps, ids, object
      # addresses, line numbers), so letting it reach the key would give every
      # occurrence a distinct key and turn an hourly-throttled alert into a flood.
      key = dedup_key || default_dedup_key(title, source)
      snippet = AlertSnippet.build(error)

      if AlertBatcher.open?
        return AlertBatcher.record(title, details: details, source: source, dedup_key: key, log_snippet: snippet)
      end

      emit(title, details: details, source: source, dedup_key: key, log_snippet: snippet)
    rescue => e
      logger.error("Failed to raise alert", title: title, error: e.message)
      false
    end

    # Emit an alert immediately, bypassing any open AlertBatcher. Called by
    # AlertBatcher on flush to post the (possibly aggregated) Slack message.
    #
    # This is effectively the non-batching core of raise_alert, extracted so
    # the batcher can reuse the dedup + Slack-post logic on flush.
    def emit(title, details:, source:, dedup_key:, log_snippet: nil)
      if suppressed?(dedup_key)
        logger.info("Alert suppressed (duplicate within #{DEDUP_WINDOW.inspect})", title: title, source: source, dedup_key: dedup_key)
        return false
      end

      sent = post_to_slack(title, details: details, source: source, log_snippet: log_snippet)
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

    # The channel alerts are posted to, or nil when unconfigured.
    #
    # Public because it is also a channel other code has to recognize rather than
    # write to: SlackTriggerPollerJob excludes it from passive listening's
    # channel-engagement signal, since an alert Zimmer posted here is a feed entry,
    # not Zimmer joining a conversation.
    def channel_id
      SecretsLoader.get("ENG_ALERTS_SLACK_CHANNEL_ID") || ENV["ENG_ALERTS_SLACK_CHANNEL_ID"]
    end

    private

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
    def post_to_slack(title, details: nil, source: nil, log_snippet: nil)
      unless configured?
        logger.warn("AlertService not configured (missing Slack token or channel ID)")
        return false
      end

      blocks = build_slack_blocks(title, details: details, source: source, log_snippet: log_snippet)

      SlackService.client.chat_postMessage(
        channel: channel_id,
        text: build_fallback_text(title, details: details, source: source, log_snippet: log_snippet),
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
    def build_fallback_text(title, details: nil, source: nil, log_snippet: nil)
      snippet = bounded_snippet(log_snippet)
      snippet_block = snippet ? "\n#{AlertSnippet.fenced(snippet)}" : ""

      parts = [ title ]
      parts << "Source: #{source}" if source.present?
      parts << details if details.present?

      # The snippet is the highest-signal part of the message and must not be
      # what gets cut: bound the framing text against whatever budget the
      # snippet leaves, then append the snippet whole. Floored so the title
      # always survives.
      budget = [ FALLBACK_TEXT_MAX_CHARS - snippet_block.length, MIN_FRAMING_TEXT_CHARS ].max
      "#{parts.join("\n").truncate(budget)}#{snippet_block}"
    end

    # `emit` is public, so a caller can reach the Slack payload with a snippet
    # AlertSnippet never bounded. Enforce the cap here rather than trusting it.
    def bounded_snippet(log_snippet)
      return nil if log_snippet.blank?

      AlertSnippet.clamp(log_snippet.to_s, AlertSnippet::MAX_CHARS)
    end

    # Build Slack Block Kit blocks for a well-formatted alert message
    def build_slack_blocks(title, details: nil, source: nil, log_snippet: nil)
      blocks = []

      # Header
      blocks << {
        type: "header",
        text: { type: "plain_text", text: title.truncate(150), emoji: true }
      }

      # Details section
      if details.present?
        # Truncate details to stay within Slack's 3000 char limit for section text
        truncated = details.truncate(DETAILS_SECTION_MAX_CHARS)
        blocks << {
          type: "section",
          text: { type: "mrkdwn", text: truncated }
        }
      end

      # Log snippet, in a section of its own so a fenced code block renders as
      # one — monospaced and un-wrapped — rather than smeared into the prose.
      # Capped at AlertSnippet::MAX_CHARS, well inside Slack's 3000.
      snippet = bounded_snippet(log_snippet)
      if snippet
        blocks << {
          type: "section",
          text: { type: "mrkdwn", text: AlertSnippet.fenced(snippet) }
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

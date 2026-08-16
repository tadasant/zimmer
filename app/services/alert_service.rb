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

  # How long to suppress a repeat operator DM about the same subject.
  #
  # Much longer than DEDUP_WINDOW on purpose. The conditions worth a DM stay
  # broken until a human acts on them, and the background sweeps that discover
  # them run every minute or two — an hourly re-nag would be 24 DMs a day about
  # one dead account. The suppression is dropped when a human resolves the
  # condition (see {clear_dm_suppression}, called from the login drivers'
  # `capture!`), so in the ordinary case this window only bounds an unfixed
  # problem. It is deliberately NOT dropped when the status merely changes —
  # ClaudeAccount#latch_needs_reauth_transition explains why that would flood.
  OPERATOR_DM_DEDUP_WINDOW = 12.hours

  # Read through SecretsLoader like the other Slack settings, unlike
  # ALERTS_ENABLED_ENV_VAR. That var is ENV-only because it is the authorization
  # to page, and a secret-store value travels into every agent clone's `.env`.
  # This one is only an address. That is a smaller escalation, not none: the same
  # bundle already carries SLACK_BOT_TOKEN, so what a clone gains is *which human*
  # to DM rather than the ability to DM at all. Weighed against keeping the
  # recipient configurable per deployment, and recorded in
  # docs/limitations.md alongside the token itself.
  OPERATOR_USER_ID_KEY = "OPERATOR_SLACK_USER_ID"

  # Upper bound on the Slack `text:` field. Slack imposes no hard cap there, but
  # it drives push notifications, so keep it sane.
  FALLBACK_TEXT_MAX_CHARS = 3500

  # Upper bound on the details section block. Slack's section text limit is 3000.
  DETAILS_SECTION_MAX_CHARS = 2800

  # Floor for title + source + details in the `text:` field, so a large snippet
  # can never squeeze the framing down to nothing.
  MIN_FRAMING_TEXT_CHARS = 400

  # The environments that own the alert channel. Zimmer's two deployed
  # environments page; a process running as anything else does not, however
  # completely it is credentialed. This is the same boundary
  # `config/initializers/sentry.rb` draws for the production error DSN, for the
  # same reason (issue #176).
  #
  # Holding the secret is not authorization to page, and every agent-session
  # clone holds it: `AgentSessionJob` writes `SecretsLoader.all` into the clone's
  # `.env`, and that bundle carries `SLACK_BOT_TOKEN` and
  # `ENG_ALERTS_SLACK_CHANNEL_ID`. An agent's shell has no `RAILS_ENV` (see
  # `CliSpawnEnv#clear_inherited_env_vars`), so a clone that boots Zimmer boots it
  # as `development`. In #272 one did: it registered development's cron table,
  # probed the elicitation endpoint at `http://localhost:3000` where nothing was
  # listening, and paged the production channel every 5 minutes while production's
  # own approval gate was healthy.
  #
  # The gate reads the environment and nothing else. In particular it does not
  # lean on the dedup cache, which is best-effort by construction: `suppressed?`
  # and `mark_sent` swallow their own failures, as does
  # `ElicitationEndpoint.record`. When the cache is unreachable — which is the
  # ordinary case for a clone, whose `REDIS_URL` points somewhere it cannot use —
  # every suppressor falls open at once, and one incident becomes a message per
  # tick. A throttle that fails open is not a containment boundary.
  ALERTING_ENVIRONMENTS = %w[production staging].freeze

  # Declares the gate explicitly, overriding the environment default in both
  # directions: true on an instance that should page anyway, false to mute one
  # that otherwise would. Set it as deploy environment configuration only, never
  # in `mcp_secrets` — secret-store values are copied into every clone's `.env`,
  # so an opt-in stored there would travel with the clones and reopen this hole.
  # `CliSpawnEnv` clears it from spawned agents for the same reason.
  ALERTS_ENABLED_ENV_VAR = "ALERTS_ENABLED"
  ALERTS_ENABLED_TRUE_VALUES = %w[1 true t yes y on].freeze
  ALERTS_ENABLED_FALSE_VALUES = %w[0 false f no n off].freeze

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

      # Before the snippet and before the batch, not just before the post: an
      # alert this instance may never send should not be rendered, and should not
      # be accumulated for a flush that will drop it. The caller gets the same
      # false either way, and `post_to_slack` checks again for the paths that
      # reach it directly.
      return log_gated(title, details: details, source: source) unless enabled?

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

    # Send an alert to the operator as a Slack DM rather than to #eng-alerts.
    #
    # Same environment gate, same Block Kit rendering, same cache-backed
    # suppression as {raise_alert} — the difference is the destination and the
    # throttle. A channel alert is a feed entry a human scrolls past; a DM is a
    # nag aimed at one person, so it is reserved for conditions that stay broken
    # until that person acts, and it repeats on a much slower clock
    # (OPERATOR_DM_DEDUP_WINDOW rather than DEDUP_WINDOW).
    #
    # Deliberately NOT routed through AlertBatcher: the batcher collapses bursts
    # of the same alert within one thread, which is a channel concern. A DM is
    # already throttled per subject by its dedup key.
    #
    # @param title [String] short DM title
    # @param details [String] the body, as Slack mrkdwn
    # @param source [String] the model/job/service raising it
    # @param dedup_key [String] REQUIRED and caller-owned: a DM should be keyed on
    #   the subject that is broken (e.g. one account), not on title + source, so
    #   two dead accounts produce two DMs rather than silently collapsing into one.
    # @param dedup_window [ActiveSupport::Duration] how long to suppress a repeat
    # @return [Boolean] true if a DM was sent
    def dm_operator(title, details:, dedup_key:, source: nil, dedup_window: OPERATOR_DM_DEDUP_WINDOW)
      return log_gated(title, details: details, source: source) unless enabled?

      user_id = operator_user_id
      if user_id.blank? || !SlackService.configured?
        logger.warn(
          "Operator DM not sent (missing SLACK_BOT_TOKEN or #{OPERATOR_USER_ID_KEY})",
          title: title,
          source: source
        )
        return false
      end

      if suppressed?(dedup_key)
        logger.info("Operator DM suppressed (duplicate within #{dedup_window.inspect})", title: title, dedup_key: dedup_key)
        return false
      end

      SlackService.send_dm(
        user_id: user_id,
        text: build_fallback_text(title, details: details, source: source),
        blocks: build_slack_blocks(title, details: details, source: source)
      )

      mark_sent(dedup_key, expires_in: dedup_window)
      logger.info("Operator DM sent", title: title, source: source)
      true
    rescue => e
      # Blanket, and deliberately so: this fires from token-refresh and
      # status-transition paths whose job is to keep the account pool running. A
      # Slack outage, a missing scope or an unreachable cache must degrade to a
      # logged false, never to a raise that strands an account mid-recovery.
      #
      # .warn, not .error: StructuredLogger#error reports to Sentry, and a Slack
      # outage raising an error event would page about the paging path — for the
      # one alert shape this file argues should not page.
      logger.warn("Failed to send operator DM", title: title, source: source, error: e.message)
      false
    end

    # Forget a DM suppression so the next occurrence of the same subject sends
    # immediately. Called when the underlying condition clears — otherwise an
    # account that breaks, is fixed, and breaks again inside the window would be
    # silently swallowed by the suppression its first failure wrote.
    def clear_dm_suppression(dedup_key)
      Rails.cache.delete(cache_key(dedup_key))
    rescue => e
      logger.warn("Cache delete failed", error: e.message)
      false
    end

    # The Slack user operator DMs are addressed to, or nil when unconfigured.
    def operator_user_id
      SecretsLoader.get(OPERATOR_USER_ID_KEY) || ENV[OPERATOR_USER_ID_KEY]
    end

    # Check if the service is configured and ready to send alerts
    # @return [Boolean] true if Slack is configured and channel ID is available
    def configured?
      SlackService.configured? && channel_id.present?
    end

    # Whether this instance is allowed to post to the alert channel at all.
    #
    # Separate from {configured?} on purpose: "I hold the credentials" and "I am
    # an instance that owns this channel" are different questions, and only the
    # second one decides whether a page is legitimate. See ALERTING_ENVIRONMENTS.
    #
    # @return [Boolean]
    def enabled?
      override = alerts_enabled_override
      return override unless override.nil?

      ALERTING_ENVIRONMENTS.include?(Rails.env.to_s)
    end

    # The environment tag stamped onto every alert, so a message that reaches the
    # channel from somewhere unexpected identifies itself instead of being read
    # as a production incident.
    # @return [String] e.g. "production", "staging", "development"
    def environment_label
      Rails.env.to_s
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

    # Record an alert this instance is not allowed to send. Warn, and carry the
    # body: it is dropped, but a developer exercising alerting should see what
    # would have gone out and why it didn't, rather than silence.
    # @return [false] so callers can `return log_gated(...)`
    def log_gated(title, details:, source:)
      logger.warn(
        "Alert not sent: this instance does not page the alert channel (set #{ALERTS_ENABLED_ENV_VAR}=true to page from here)",
        title: title,
        source: source,
        environment: environment_label,
        details: details&.truncate(500)
      )
      false
    end

    # Read as an explicit declaration or not at all: an unrecognized value is
    # treated as unset (and warned about) rather than as "yes, page production".
    #
    # ENV, not SecretsLoader — this is deploy configuration (which instance owns
    # the channel), not a secret, and it has to be answerable on an instance
    # whose credential store is exactly what's in doubt.
    #
    # @return [Boolean, nil] nil when unset or unparseable
    def alerts_enabled_override
      raw = ENV[ALERTS_ENABLED_ENV_VAR].to_s.strip.downcase
      return nil if raw.empty?
      return true if ALERTS_ENABLED_TRUE_VALUES.include?(raw)
      return false if ALERTS_ENABLED_FALSE_VALUES.include?(raw)

      logger.warn(
        "Ignoring unrecognized #{ALERTS_ENABLED_ENV_VAR} value; falling back to the environment default",
        value: raw,
        environment: environment_label
      )
      nil
    end

    # Check if an alert with this key was already sent within the dedup window
    def suppressed?(key)
      Rails.cache.exist?(cache_key(key))
    rescue => e
      logger.warn("Cache check failed, allowing alert through", error: e.message)
      false
    end

    # Mark an alert as sent in the cache
    def mark_sent(key, expires_in: DEDUP_WINDOW)
      Rails.cache.write(cache_key(key), true, expires_in: expires_in)
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
      # The choke point every path into Slack passes through, including
      # AlertBatcher's flush — which calls `emit` directly and so never sees
      # raise_alert's check.
      return log_gated(title, details: details, source: source) unless enabled?

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

      parts = [ tagged_title(title) ]
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
        text: { type: "plain_text", text: tagged_title(title).truncate(150), emoji: true }
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
      context_elements << { type: "mrkdwn", text: "*Environment:* #{environment_label}" }
      context_elements << { type: "mrkdwn", text: "*Time:* #{Time.current.strftime('%Y-%m-%d %H:%M:%S UTC')}" }

      blocks << { type: "context", elements: context_elements }

      blocks
    end

    # Tag the environment onto the title. Applied at render time, not to the
    # title callers pass in, so dedup keys and AlertBatcher's (title, source)
    # grouping stay keyed on the alert itself.
    def tagged_title(title)
      "[#{environment_label}] #{title}"
    end
  end
end

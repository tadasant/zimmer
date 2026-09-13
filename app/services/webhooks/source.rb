# frozen_string_literal: true

module Webhooks
  # One provider's inbound switch: whether its events arrive by polling, by webhook, or both,
  # and the secret its webhook deliveries are signed with.
  #
  # Both settings resolve from encrypted credentials first and process ENV second, the order
  # every other Slack setting uses (see SlackService#slack_bot_token).
  #
  # The mode is per source so one provider can move without the other. Two values are accepted:
  #
  #   poll                        the default, and what an unset or unrecognised value means.
  #                               The webhook endpoint is inert.
  #   webhook_with_poll_fallback  the endpoint accepts signed deliveries and fires triggers
  #                               from them; the poller keeps running as the backstop, and
  #                               TriggerEventClaim keeps the two from firing one event twice.
  #
  # `webhook` alone — the endpoint with no poller behind it — is not a mode. For Slack the
  # decision on #141 is that the Events API replaces SlackTriggerPollerJob and the poller and its
  # watermarks are deleted rather than left dormant, so the no-poll state is reached by deleting
  # the poller, not by a switch that parks it.
  class Source
    POLL = "poll"
    WEBHOOK_WITH_POLL_FALLBACK = "webhook_with_poll_fallback"
    MODES = [ POLL, WEBHOOK_WITH_POLL_FALLBACK ].freeze

    attr_reader :name, :mode_key, :secret_key

    def self.slack
      @slack ||= new(
        name: "slack", mode_key: "SLACK_TRIGGER_INGEST_MODE", secret_key: "SLACK_SIGNING_SECRET",
        served_conditions: -> {
          # COALESCE because TriggerCondition#event_type reads an absent key as `new_message`.
          TriggerCondition.slack.where(
            "COALESCE(trigger_conditions.configuration->>'event_type', 'new_message') IN (?)", SlackEventJob::SERVED_EVENT_TYPES
          )
        }
      )
    end

    # GitHub's repository or organization webhook. Serves `github_issue` conditions only; see
    # GithubEventJob. A day with no delivery is ordinary for it, since GitHub sends an event only
    # when something happens to an issue.
    def self.github
      @github ||= new(
        name: "github", mode_key: "GITHUB_TRIGGER_INGEST_MODE", secret_key: "GITHUB_WEBHOOK_SECRET",
        served_conditions: -> { TriggerCondition.where(condition_type: "github_issue") },
        expects_daily_deliveries: false
      )
    end

    # Every source with a webhook endpoint, in the order the health report lists them.
    def self.all
      [ slack, github ]
    end

    attr_reader :expects_daily_deliveries

    def initialize(name:, mode_key:, secret_key:, served_conditions: -> { TriggerCondition.none }, expects_daily_deliveries: true)
      @name = name
      @mode_key = mode_key
      @secret_key = secret_key
      @served_conditions = served_conditions
      @expects_daily_deliveries = expects_daily_deliveries
      @warned = Set.new
    end

    # The trigger conditions this source's webhook can fire. The poller also claims events for
    # conditions outside it (Slack's passive listening), and nothing can race it for those, so a
    # poll claim only says the webhook missed something when its condition is in this scope.
    def served_conditions
      @served_conditions.call
    end

    def mode
      raw = setting(mode_key).to_s.strip
      return POLL if raw.empty?
      return raw if MODES.include?(raw)

      warn_unrecognised(raw)
      POLL
    end

    # Whether this source's webhook path is switched on. Says nothing about whether it can
    # verify a delivery — see #accepting?.
    def webhook_enabled?
      mode == WEBHOOK_WITH_POLL_FALLBACK
    end

    def signing_secret
      setting(secret_key)
    end

    # Whether the endpoint should look at a delivery at all. Both halves are required: a
    # switched-on source with no secret could verify nothing, so it stays as inert as a
    # switched-off one.
    def accepting?
      webhook_enabled? && signing_secret.present?
    end

    private

    def setting(key)
      SecretsLoader.get(key).presence || ENV[key].presence
    end

    # WARN rather than raise: a typo in the mode must not take the poller down with it, and
    # falling back to `poll` is the configuration that changes nothing. Once per value per
    # process, because this is read on every poll and every delivery.
    def warn_unrecognised(raw)
      return if @warned.include?(raw)

      @warned << raw
      why = if raw == "webhook"
        "`webhook` without a poller is not a mode: a poller is replaced by deleting it " \
        "(tadasant/zimmer#141), not by switching it off. Use `#{WEBHOOK_WITH_POLL_FALLBACK}`."
      else
        "Expected one of #{MODES.join(', ')}."
      end
      Rails.logger.warn("[Webhooks::Source] #{mode_key}=#{raw.inspect} is not a mode Zimmer accepts; treating #{name} as `#{POLL}`. #{why}")
    end
  end
end

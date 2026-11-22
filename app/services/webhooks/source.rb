# frozen_string_literal: true

module Webhooks
  # One provider's inbound switch: whether its events arrive by polling, by webhook, or both,
  # and the secret its webhook deliveries are signed with.
  #
  # Both settings resolve from encrypted credentials first and process ENV second. Unlike the
  # Slack bot token (SlackService.setting), they are not read from the Parameter Store.
  #
  # The mode is per source so one provider can move without the other. Three values are accepted:
  #
  #   poll                        the default, and what an unset or unrecognised value means.
  #                               The webhook endpoint is inert.
  #   webhook_shadow              GitHub only. The endpoint accepts and records signed deliveries,
  #                               and GithubEventJob evaluates every condition against them, but it
  #                               fires nothing and claims nothing: it records what it WOULD have
  #                               fired (TriggerShadowObservation). The poller fires exactly as on
  #                               `poll` and records what it fired, and
  #                               Webhooks::GithubShadowComparison lines the two up. It is the
  #                               rehearsal before `webhook_with_poll_fallback`.
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
    WEBHOOK_SHADOW = "webhook_shadow"
    WEBHOOK_WITH_POLL_FALLBACK = "webhook_with_poll_fallback"
    MODES = [ POLL, WEBHOOK_SHADOW, WEBHOOK_WITH_POLL_FALLBACK ].freeze

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

    # GitHub's repository or organization webhook. Serves both GitHub condition types —
    # `github_issue` from `issues.opened`, `github_label` from the label and open/reopen deliveries;
    # see GithubEventJob. A day with no delivery is ordinary for it, since GitHub sends an event
    # only when something happens to an issue or a pull request.
    def self.github
      @github ||= new(
        name: "github", mode_key: "GITHUB_TRIGGER_INGEST_MODE", secret_key: "GITHUB_WEBHOOK_SECRET",
        served_conditions: -> { TriggerCondition.github },
        expects_daily_deliveries: false,
        shadow_supported: true
      )
    end

    # The same GitHub endpoint and secret, read for a different consumer: the per-session PR
    # pollers (Github::PrPollPass, Github::OrphanedPrConflictSweep) rather than triggers. Its
    # own mode, so PR polling can move without moving triggers and the other way round; see
    # Github::PrWebhookIngest for what each mode does there. It fires no trigger condition, and
    # it is not in .all: its deliveries are the `github` source's deliveries, which the health
    # report already counts.
    def self.github_prs
      @github_prs ||= new(
        name: "github_prs", mode_key: "GITHUB_PR_INGEST_MODE", secret_key: "GITHUB_WEBHOOK_SECRET",
        expects_daily_deliveries: false,
        shadow_supported: true
      )
    end

    # Every source with a webhook endpoint, in the order the health report lists them.
    def self.all
      [ slack, github ]
    end

    attr_reader :expects_daily_deliveries

    def initialize(name:, mode_key:, secret_key:, served_conditions: -> { TriggerCondition.none }, expects_daily_deliveries: true,
                   shadow_supported: false)
      @name = name
      @shadow_supported = shadow_supported
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
      return raw if modes.include?(raw)

      warn_unrecognised(raw)
      POLL
    end

    # The modes this source accepts. `webhook_shadow` only where the webhook job knows how to
    # evaluate without firing.
    def modes
      @shadow_supported ? MODES : MODES - [ WEBHOOK_SHADOW ]
    end

    # Whether this source's webhook FIRES triggers. Says nothing about whether it can verify a
    # delivery — see #accepting?. False in `webhook_shadow`, where the poller alone fires.
    def webhook_enabled?
      mode == WEBHOOK_WITH_POLL_FALLBACK
    end

    # Whether the webhook only records what it would fire. See `webhook_shadow` above.
    def shadow?
      mode == WEBHOOK_SHADOW
    end

    # Whether the endpoint takes deliveries at all: firing them, or shadowing them.
    def receiving?
      webhook_enabled? || shadow?
    end

    def signing_secret
      setting(secret_key)
    end

    # Whether the endpoint should look at a delivery at all. Both halves are required: a
    # switched-on source with no secret could verify nothing, so it stays as inert as a
    # switched-off one.
    def accepting?
      receiving? && signing_secret.present?
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
      elsif raw == WEBHOOK_SHADOW
        "`#{WEBHOOK_SHADOW}` is a GitHub-only mode."
      else
        "Expected one of #{modes.join(', ')}."
      end
      Rails.logger.warn("[Webhooks::Source] #{mode_key}=#{raw.inspect} is not a mode Zimmer accepts; treating #{name} as `#{POLL}`. #{why}")
    end
  end
end

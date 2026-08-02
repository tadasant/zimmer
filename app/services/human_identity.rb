# frozen_string_literal: true

# The registry of named human beings Zimmer can attribute a TimelineEvent to.
#
# Two ideas are deliberately kept apart here:
#
#   * WHO the humans are — a small, stable list that lives in
#     `config/human_identities.yml` and changes about as often as the household
#     does.
#   * WHICH external account belongs to which human — deployment configuration,
#     in the same class as the Slack trigger's `allowed_user_ids`. Slack user
#     IDs are NOT hardcoded in application source; they come from the
#     ZIMMER_HUMAN_SLACK_USER_IDS secret/env var, resolved through SecretsLoader
#     first and process ENV second (the same order TriggerCondition
#     .default_allowed_user_ids uses).
#
# The web UI needs no mapping: Zimmer has no login and a single circle of trust,
# so the one human with browser access *is* the web identity (`web_ui: true`).
# That is an assertion about the deployment, not a permission check — see
# SessionsController's authorization note.
class HumanIdentity
  class ConfigError < StandardError; end

  # Comma-separated `<slack_user_id>:<identity_name>` pairs.
  SLACK_ID_ENV_KEY = "ZIMMER_HUMAN_SLACK_USER_IDS"

  attr_reader :name, :display_name

  def initialize(name:, display_name:, web_ui:, slack_user_ids:)
    @name = name
    @display_name = display_name
    @web_ui = web_ui
    @slack_user_ids = slack_user_ids
  end

  def web_ui? = @web_ui

  # Slack IDs declared in the YAML only. The deployment-configured ones live in
  # .slack_id_map, which is the accessor callers should use.
  def configured_slack_user_ids = @slack_user_ids

  def ==(other) = other.is_a?(HumanIdentity) && other.name == name
  alias_method :eql?, :==
  def hash = name.hash

  def to_s = name

  class << self
    def config_path
      Rails.root.join("config", "human_identities.yml")
    end

    # Every configured human, in file order.
    #
    # Not memoized across calls in development so an edit to the YAML shows up
    # without a restart; memoized per-request would buy nothing measurable
    # (the file is a handful of lines and Rails caches the parse in production).
    def all
      if Rails.env.production?
        @all ||= load_all
      else
        load_all
      end
    end

    def find(name)
      return nil if name.blank?

      all.find { |identity| identity.name == name.to_s }
    end

    # The human behind anything typed into the Zimmer web UI.
    #
    # Returns nil if no identity claims `web_ui: true`, which makes web-UI
    # capture silently record nothing rather than guess — the safe direction.
    def web_ui
      all.find(&:web_ui?)
    end

    # Slack user ID => HumanIdentity, merging the deployment's configured pairs
    # over anything declared in the YAML. A pair naming an identity that does
    # not exist is dropped: an unknown name must not become an author.
    def slack_id_map
      map = {}

      all.each do |identity|
        identity.configured_slack_user_ids.each { |id| map[id] = identity }
      end

      parse_slack_id_pairs.each do |slack_id, identity_name|
        identity = find(identity_name)
        next if identity.nil?

        map[slack_id] = identity
      end

      map
    end

    # The human behind a Slack user ID, or nil when the ID maps to nobody we
    # know. nil is a correct answer: an unmapped Slack account may be another
    # workspace member, a bot, or an app posting with a bot token.
    def for_slack_user_id(slack_user_id)
      return nil if slack_user_id.blank?

      slack_id_map[slack_user_id.to_s]
    end

    def names = all.map(&:name)

    def reset_cache!
      @all = nil
    end

    private

    def load_all
      raw = YAML.safe_load_file(config_path) || {}
      entries = raw["identities"]
      raise ConfigError, "config/human_identities.yml must define an `identities` list" unless entries.is_a?(Array)

      identities = entries.map do |entry|
        name = entry["name"].to_s
        raise ConfigError, "every human identity needs a `name`" if name.blank?

        new(
          name: name,
          display_name: entry["display_name"].presence || name,
          web_ui: entry["web_ui"] == true,
          slack_user_ids: Array(entry["slack_user_ids"]).map(&:to_s)
        )
      end

      if identities.count(&:web_ui?) > 1
        raise ConfigError, "at most one human identity may set `web_ui: true`"
      end

      identities
    end

    def parse_slack_id_pairs
      raw = SecretsLoader.get(SLACK_ID_ENV_KEY) || ENV[SLACK_ID_ENV_KEY]

      raw.to_s.split(",").filter_map do |pair|
        slack_id, identity_name = pair.split(":", 2).map { |part| part.to_s.strip }
        next if slack_id.blank? || identity_name.blank?

        [ slack_id, identity_name ]
      end
    end
  end
end

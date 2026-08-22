# frozen_string_literal: true

# The catalogue of experimental settings, and the only thing you edit to add one.
#
# An "experimental setting" is a global switch that changes how Zimmer drives its
# agents — MCP tool search today, whatever lands next after that. Every one of
# them is a crude A/B test: it is turned on, spend and behaviour move, and the
# question afterwards is whether the setting moved them.
#
# One registry serves three surfaces, so a setting cannot be half-wired:
#
#   Settings → Experimental   renders a toggle per entry (SettingsController)
#   AppSettingsController      writes the toggle back
#   SessionExperimentalFlag    tags every session with what the setting was
#   CostAnalytics#by_experiment compares the cohorts that tagging produces
#
# ADDING A SETTING
#
# Append one entry to BUILT_INS. If it is backed by an AppSetting column, give it
# the column name and a migration; if it is a Zimmer Extension, nothing is needed
# here at all — experimental extensions are picked up from the registry
# automatically. Set `landed_at` when the setting shipped enabled (or disabled)
# for everyone, and ExperimentalFlagBackfillJob will label the history on either
# side of that date. Leave it nil and only sessions that run from then on get
# tagged, which is the more honest default for a setting that ships off.
class ExperimentalSettingsRegistry
  # One experimental setting.
  #
  # `attribute` names an AppSetting boolean column; `extension` holds a
  # Zimmer::Extension instead. Exactly one of the two is set.
  #
  # `landed_at` / `value_before` / `value_after` describe a step change in the
  # setting's value that predates this table — the commit that shipped it. They
  # are the ONLY thing that licenses inferring a session's cohort from its
  # timestamps, and the inference is recorded as such (source "backfilled") so
  # the report can say where the label came from.
  Setting = Struct.new(
    :key, :title, :description, :attribute, :extension,
    :default_on, :landed_at, :value_before, :value_after,
    keyword_init: true
  ) do
    def extension? = !extension.nil?

    def backfillable? = !landed_at.nil?

    # What the setting is right now. Returns nil rather than raising when the
    # settings row can't be read — this runs on the session-spawn path.
    def current_value
      return extension.enabled? if extension?

      AppSetting.current.public_send(:"#{attribute}?")
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      nil
    end

    # The value this setting had at `time`, per the step change `landed_at`
    # describes. Only meaningful for a backfillable setting.
    def value_at(time)
      return nil unless backfillable?

      time < landed_at ? value_before : value_after
    end

    def param_name
      extension? ? "app_setting[extensions][#{extension.id}]" : "app_setting[#{attribute}]"
    end

    def dom_id
      extension? ? "app_setting_extension_#{extension.id}" : "app_setting_#{attribute}"
    end
  end

  # Settings backed by an AppSetting column. These ship in the image, so unlike a
  # Zimmer Extension (which .dockerignore excludes) they are always present.
  BUILT_INS = [
    Setting.new(
      key: "mcp_tool_search",
      title: "MCP tool search",
      description: "Spawn Claude Code sessions with ENABLE_TOOL_SEARCH=true so the agent searches " \
                   "MCP tools on demand instead of loading every attached server's tool schemas up " \
                   "front. Claude Code only — Codex ignores it.",
      attribute: :mcp_tool_search_enabled,
      default_on: -> { AppSetting::DEFAULT_MCP_TOOL_SEARCH_ENABLED },
      # b59d9ad7, "feat(settings): make MCP tool search a first-class toggle, on
      # by default" — the commit that turned it on for every session at once.
      # Nothing before it ran with tool search; everything after it did.
      landed_at: Time.utc(2026, 8, 22, 13, 55, 34),
      value_before: false,
      value_after: true
    )
  ].freeze

  class << self
    # Every experimental setting: the built-ins, then any registered experimental
    # Zimmer Extension. A dropped extension disappears from every surface at once
    # rather than leaving a dead toggle behind.
    def all
      BUILT_INS + extension_settings
    end

    def keys = all.map(&:key)

    def find(key) = all.find { |s| s.key == key.to_s }

    def backfillable = all.select(&:backfillable?)

    def title_for(key) = find(key)&.title || key.to_s.humanize

    # key => current boolean, skipping anything that could not be read. This is
    # what gets written onto a session as it starts and as it ends.
    def current_values
      all.each_with_object({}) do |setting, values|
        value = setting.current_value
        values[setting.key] = value unless value.nil?
      end
    end

    # The default state each setting is labelled "recommended default" against in
    # the settings UI.
    def default_on?(setting)
      return setting.extension.default_enabled? if setting.extension?

      value = setting.default_on
      value.respond_to?(:call) ? value.call : value
    end

    private

    def extension_settings
      Zimmer::ExtensionRegistry.experimental.map do |ext|
        Setting.new(
          key: "extension.#{ext.id}",
          title: ext.title,
          description: ext.description,
          extension: ext
        )
      end
    end
  end
end

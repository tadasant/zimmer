# frozen_string_literal: true

# Moves stored model ids that pin a version onto the version-free built-in that
# replaced them — Codex `gpt-5.6-terra` → `terra`, Pi
# `openrouter/anthropic/claude-opus-4.6` → `openrouter/~anthropic/claude-opus-latest`
# (ModelCatalog::LEGACY_MODEL_ALIASES) — so the Settings default and every open
# session show, and keep following, the latest model.
#
# Nothing breaks without it: ModelCatalog still accepts a legacy id, and a Codex
# one launches as its family's latest model. But the Settings page and a
# session's model picker list only the version-free ids, so a stored legacy id
# would render as a value none of the options match. Data, not schema, so it is
# a post-deploy task rather than a migration.
#
# Covers the AppSetting default and every Codex and Pi session that is not
# archived or failed; finished sessions keep the id they ran with, as history.
# The write is `update_columns`, so it broadcasts nothing (an open page shows
# the new id on its next load), and a session running at deploy time whose job
# later saves the config it loaded may put the legacy id back. That is harmless:
# a legacy id still validates, and a Codex one still launches as its family.
# A legacy id with no replacement, or one an operator re-added as a model of
# their own, is left alone (ModelCatalog.canonical_model_id).
#
# IDEMPOTENT. Only rows still holding a legacy id are visited, and a row is
# only written when its id has a replacement, so a second run writes nothing.
# Its answer is in `post_deploy_task_runs` — on /health, in
# `GET /api/v1/health`, from `get_system_health` and at
# /supervisor/post_deploy_task_runs — as the count of settings and sessions it
# moved.
class MovePinnedModelsOntoFloatingAliases < PostDeployTask
  def self.candidates
    clauses = ModelCatalog::LEGACY_MODEL_ALIASES.map do |runtime, aliases|
      Session.where(agent_runtime: runtime).where("config->>'model' IN (?)", aliases.compact.keys)
    end
    clauses.reduce(:or).where.not(status: %w[archived failed]).order(:id)
  end

  def up
    checkpoint!(settings: move_app_setting) unless stats.key?("settings")
    moved = stats["sessions"].to_i

    outcome = sweep(self.class.candidates, batch_size: 200) do |batch|
      batch.each do |session|
        model = session.config["model"]
        canonical = ModelCatalog.canonical_model_id(session.agent_runtime, model)
        next if canonical == model

        session.update_columns(config: session.config.merge("model" => canonical))
        moved += 1
      end
      checkpoint!(sessions: moved)
    end

    checkpoint!(sessions: moved)
    outcome
  end

  private

  # A direct column write, not a save: the row's other validations are not this
  # task's business, and one that no longer passes must not stop the sweep.
  def move_app_setting
    setting = AppSetting.first
    return 0 unless setting&.default_model.present?

    runtime = setting.default_runtime.presence || RuntimeRegistry::DEFAULT_RUNTIME
    canonical = ModelCatalog.canonical_model_id(runtime, setting.default_model)
    return 0 if canonical == setting.default_model

    setting.update_columns(default_model: canonical, updated_at: Time.current)
    1
  end
end

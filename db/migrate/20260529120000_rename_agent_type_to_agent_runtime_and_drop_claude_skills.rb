class RenameAgentTypeToAgentRuntimeAndDropClaudeSkills < ActiveRecord::Migration[8.0]
  def up
    # Rename agent_type -> agent_runtime. The column is the runtime that drives
    # the session (Claude Code today; Codex forthcoming, see #3766). Existing
    # rows already hold "claude_code", so the rename preserves their values.
    rename_column :sessions, :agent_type, :agent_runtime

    # Backfill any NULLs before enforcing NOT NULL. The column previously had a
    # default but allowed NULL; guarantee every row resolves to a runtime.
    execute <<~SQL
      UPDATE sessions SET agent_runtime = 'claude_code' WHERE agent_runtime IS NULL
    SQL

    change_column_default :sessions, :agent_runtime, "claude_code"
    change_column_null :sessions, :agent_runtime, false

    # rename_column automatically renames the conventionally-named index
    # (index_sessions_on_agent_type -> index_sessions_on_agent_runtime), so no
    # explicit rename_index is needed here.

    # claude_skills was a per-session cache of discovered Claude skills. Skill
    # discovery now persists exclusively through the agent-root-scoped
    # ClaudeSkillsCacheService cache (Rails.cache), so the column is removed.
    remove_column :sessions, :claude_skills
  end

  def down
    add_column :sessions, :claude_skills, :jsonb, default: []

    change_column_null :sessions, :agent_runtime, true
    change_column_default :sessions, :agent_runtime, "claude_code"
    rename_column :sessions, :agent_runtime, :agent_type
  end
end

class AddClaudeSkillsToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :claude_skills, :jsonb, default: []
  end
end

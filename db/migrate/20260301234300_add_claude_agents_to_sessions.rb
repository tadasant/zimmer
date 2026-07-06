class AddClaudeAgentsToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :claude_agents, :jsonb, default: []
  end
end

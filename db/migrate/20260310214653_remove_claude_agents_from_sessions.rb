class RemoveClaudeAgentsFromSessions < ActiveRecord::Migration[8.0]
  def change
    remove_column :sessions, :claude_agents, :jsonb, default: []
  end
end

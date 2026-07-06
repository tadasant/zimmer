class AddPromptAndMcpServersToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :prompt, :text
    add_column :sessions, :mcp_servers, :json
  end
end

class AddMcpServerEnvToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :mcp_server_env, :json
  end
end

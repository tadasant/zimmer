class AddMcpServerHeadersToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :mcp_server_headers, :json
  end
end

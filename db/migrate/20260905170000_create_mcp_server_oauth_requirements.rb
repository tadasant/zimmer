class CreateMcpServerOauthRequirements < ActiveRecord::Migration[8.0]
  def change
    create_table :mcp_server_oauth_requirements do |t|
      t.string :server_name, null: false
      t.string :credential_key, null: false
      t.string :server_url
      t.string :determination, null: false
      t.string :detail
      t.datetime :determined_at, null: false

      t.timestamps
    end

    add_index :mcp_server_oauth_requirements, :credential_key, unique: true
    add_index :mcp_server_oauth_requirements, :server_name
  end
end

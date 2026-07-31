# frozen_string_literal: true

# An OAuth flow started from the Connectors page has no session behind it — the
# whole point of that button is that the user no longer has to spin one up just
# to authorize a connector. Make the association optional at the database level
# so those flows can exist.
#
# The unique index on [session_id, server_name] stays as it is: Postgres treats
# NULLs as distinct, so it constrains in-session flows exactly as before and
# imposes nothing on session-less ones (McpOauthController deletes the previous
# session-less flow for a server before starting another).
class AllowSessionLessMcpOauthPendingFlows < ActiveRecord::Migration[8.0]
  def change
    change_column_null :mcp_oauth_pending_flows, :session_id, true
  end
end

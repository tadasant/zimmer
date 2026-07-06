# frozen_string_literal: true

# Controller for managing MCP OAuth credentials display and deletion.
# Shows all stored OAuth credentials with metadata and provides deletion functionality.
class McpOauthCredentialsController < ApplicationController
  def index
    @credentials = McpOauthCredential.order(created_at: :desc)
  end

  def destroy
    @credential = McpOauthCredential.find(params[:id])
    @credential.destroy

    respond_to do |format|
      format.html { redirect_to oauth_status_index_path, notice: "OAuth credential for #{@credential.server_name} deleted." }
      format.turbo_stream { render turbo_stream: turbo_stream.remove(@credential) }
    end
  end
end

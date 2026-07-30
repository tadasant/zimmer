# frozen_string_literal: true

# Deletes a stored MCP OAuth credential — the "Disconnect" action on the
# Connectors page. Viewing credentials lives on ConnectorsController, which
# presents them per catalog server rather than as a bare credential table.
class McpOauthCredentialsController < ApplicationController
  def destroy
    @credential = McpOauthCredential.find(params[:id])
    @credential.destroy

    respond_to do |format|
      format.html { redirect_to connectors_path, notice: "OAuth credential for #{@credential.server_name} deleted." }
      format.turbo_stream { render turbo_stream: turbo_stream.remove(@credential) }
    end
  end
end

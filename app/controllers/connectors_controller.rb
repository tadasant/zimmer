# frozen_string_literal: true

# The Connectors page: every MCP server in Zimmer's catalog, with its live auth
# status and — when something is missing — exactly where to set it.
#
# The page never blocks on a probe. #index renders the full list from the
# catalog alone (an in-memory read) and each row is a lazy Turbo Frame pointing
# at #show, so a slow or failing probe costs that one row and nothing else. This
# is the same pattern the CLIs page uses for its status panel.
class ConnectorsController < ApplicationController
  def index
    @servers = ServersConfig.all.sort_by { |server| server.title.to_s.downcase }
    @unclaimed_credentials = unclaimed_credentials
  end

  # Which store a missing secret belongs in, and — when the Parameter Store is
  # wired up — whether its credential is the least-privilege shape it should be.
  #
  # Its own frame, like the connector rows: the IAM probe behind it is a network
  # call to Google, and the page must not wait on it. Unlike the rows it is
  # plain eager — one request, at the top of the page, that nobody should have to
  # scroll to trigger.
  def secret_store
    store = SecretProviders.chain.providers.find { |p| p.is_a?(SecretProviders::ParameterStoreProvider) }

    render partial: "connectors/secret_store", locals: {
      store: store,
      capabilities: store&.capabilities,
      reason: store.nil? ? SecretProviders.parameter_store_configuration.reason : nil
    }
  end

  # One connector's status, rendered into its lazy frame.
  def show
    status = ConnectorStatusProbe.for(params[:name])
    return head :not_found if status.nil?

    render partial: "connectors/connector", locals: { status: status }
  end

  private

  # Stored credentials that no catalog server claims — the server was renamed or
  # removed, or its config changed and the credential key no longer matches. The
  # injector will never use these, so they are shown separately (and deletably)
  # rather than being counted toward any connector's status.
  #
  # @return [ActiveRecord::Relation]
  def unclaimed_credentials
    claimed = ServersConfig.all.filter_map do |server|
      config = ServersConfig.credential_config(server.name)
      McpOauthCredential.compute_credential_key(server.name, config) if config
    end

    scope = McpOauthCredential.order(created_at: :desc)
    claimed.any? ? scope.where.not(credential_key: claimed) : scope
  end
end

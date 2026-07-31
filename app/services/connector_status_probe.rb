# frozen_string_literal: true

# Answers "can Zimmer actually use this MCP server right now?" for one catalog
# entry, and says what to do about it when the answer is no.
#
# This is what the Connectors page renders, one lazily-loaded frame per server.
# It resolves the same three inputs a spawn resolves, in the same order, so a
# connector reported Ready here is a connector that will actually connect:
#
#   1. Its `${VAR}` interpolations, through SecretProviders' chain — the Google
#      Parameter Store (when configured), Rails encrypted credentials, then
#      process ENV, plus the X token store ahead of all three. Any *required* one
#      with no value makes the server unstartable, whatever its auth story.
#   2. Whether an OAuth flow even applies (McpOauthCredentialInjector.oauth_capable_server?
#      — the shared definition used by the spawn gate and the failure classifier).
#   3. The stored OAuth credential, looked up by the same credential key the
#      injector uses. A credential filed under a *different* key is deliberately
#      not matched: the injector would not find it either, so counting it would
#      report Ready for a server that cannot connect.
#
# It never contacts the MCP server itself. It reports what is configured and
# stored, which is what determines whether a spawn succeeds; it does not claim
# the remote host is up. It may talk to the Parameter Store, and a store that
# does not answer becomes :store_unavailable for that server — deliberately NOT
# :missing_configuration, because "go set this secret" is the wrong instruction
# to give someone whose secret is already there. Anything else unexpected
# degrades to :probe_failed for that one server rather than raising: one bad
# catalog entry must not take the page down.
#
# It never reads or exposes a secret value. Presence comes from
# SecretsInterpolator#resolution, which answers without vending the value.
class ConnectorStatusProbe
  # The states a probe can honestly distinguish. Ordered roughly by how much
  # user action they demand.
  STATES = %i[
    ready
    no_credential_required
    needs_authorization
    token_expired
    needs_reauth
    missing_configuration
    store_unavailable
    probe_failed
  ].freeze

  # One required `${VAR}` and the provider that ACTUALLY resolved it.
  #
  # This is deliberately the resolved source rather than the configured one: a
  # variable present in both the Parameter Store and the encrypted credentials
  # reports GSM, because GSM is what the spawn will use. Reporting configuration
  # instead would show a value that is not the one in play.
  VariableSource = Struct.new(:variable, :badge, :title, :resolved, keyword_init: true) do
    def resolved? = !!resolved
  end

  # Result of one probe. Carries the state, the prose that explains it, and the
  # structured bits the view needs (missing variables, the credential record).
  class Status
    include ActionView::Helpers::DateHelper

    attr_reader :server, :state, :missing_variables, :credential, :error_message, :variable_sources

    def initialize(server:, state:, missing_variables: [], credential: nil, error_message: nil,
      variable_sources: [])
      @server = server
      @state = state
      @missing_variables = missing_variables
      @credential = credential
      @error_message = error_message
      @variable_sources = variable_sources
    end

    def server_name = server.name
    def title = server.title

    def ready? = state == :ready
    def missing_configuration? = state == :missing_configuration

    def actionable?
      %i[needs_authorization token_expired needs_reauth missing_configuration store_unavailable
         probe_failed].include?(state)
    end

    # True when starting an OAuth flow from the Connectors page is the thing
    # that fixes this row: the server is OAuth-based and Zimmer holds no usable
    # credential for it. :token_expired is deliberately excluded — that one has
    # a refresh token and RefreshMcpOauthTokensJob resolves it without the user.
    # A :missing_configuration row is not OAuth at all; its credential is a
    # `${VAR}` secret and no consent screen will set it.
    def authorizable?
      %i[needs_authorization needs_reauth].include?(state)
    end

    # Short badge text.
    def label
      case state
      when :ready then "Ready"
      when :no_credential_required then "No credential required"
      when :needs_authorization then "Needs authorization"
      when :token_expired then "Token expired"
      when :needs_reauth then "Needs re-auth"
      when :missing_configuration then "Missing configuration"
      when :store_unavailable then "Secret store unreachable"
      when :probe_failed then "Probe failed"
      end
    end

    # One sentence saying what the state means for this specific server.
    def summary
      case state
      when :ready then ready_summary
      when :no_credential_required
        "The catalog entry for this server configures no credential, so there is nothing to set up."
      when :needs_authorization
        "No OAuth credential is stored yet. Authorize it here — you don't need a session."
      when :token_expired
        "The stored access token has expired. It has a refresh token, so RefreshMcpOauthTokensJob will renew it automatically."
      when :needs_reauth
        "The stored access token has expired and carries no refresh token. Authorize it again to replace it."
      when :missing_configuration
        "#{'Variable'.pluralize(missing_variables.size)} #{missing_variables.to_sentence} #{missing_variables.one? ? 'has' : 'have'} no value, so this server cannot start."
      when :store_unavailable
        "#{missing_variables.to_sentence} could not be checked: #{error_message}. " \
        "This is not the same as the variable being unset — the store did not answer."
      when :probe_failed
        "Could not determine this connector's status: #{error_message}"
      end
    end

    # Where each missing variable has to be set. Empty unless the state is
    # :missing_configuration — there is nothing useful to tell someone to do
    # about a variable whose status could not be read. Always sourced from
    # SecretsLocation, so a change of secret store is a change to one file.
    #
    # @return [Array<Hash>]
    def instructions
      return [] unless missing_configuration?

      missing_variables.map { |name| SecretsLocation.instructions(name) }
    end

    # The stored credential's expiry, when there is one to show.
    def expires_at = credential&.expires_at

    private

    # Ready has two shapes: an OAuth flow that has been completed, and a server
    # whose static credential variables are all set. Saying which one is what
    # tells the user whether there is a token they could revoke.
    def ready_summary
      return static_ready_summary if credential.nil?

      if credential.expires_at.nil?
        "OAuth is complete and the credential is saved. It does not expire."
      else
        "OAuth is complete and the credential is saved. The access token expires in " \
        "#{distance_of_time_in_words(Time.current, credential.expires_at)}" \
        "#{credential.can_refresh? ? ' and will be refreshed automatically' : ''}."
      end
    end

    def static_ready_summary
      variables = server.required_variables
      "Configured — #{variables.to_sentence} #{variables.one? ? 'is' : 'are'} set."
    end
  end

  # Probe a catalog server by name.
  #
  # @param server_name [String]
  # @return [Status, nil] nil when the name is not in the catalog.
  def self.for(server_name)
    server = ServersConfig.find(server_name)
    return nil if server.nil?

    new(server).call
  end

  # @param server [ServersConfig::Server]
  def initialize(server, interpolator: SecretsInterpolator.new)
    @server = server
    @interpolator = interpolator
  end

  # @return [Status]
  def call
    absent, unreachable, reason, sources = classify_variables
    @variable_sources = sources
    if unreachable.any?
      return status(:store_unavailable, missing_variables: unreachable, error_message: reason)
    end
    return status(:missing_configuration, missing_variables: absent) if absent.any?
    return oauth_status if oauth_capable?
    return status(:ready) if server.required_variables.any?

    status(:no_credential_required)
  rescue => e
    Rails.logger.warn "[ConnectorStatusProbe] #{server.name}: #{e.class}: #{e.message}"
    status(:probe_failed, error_message: "#{e.class}: #{e.message}")
  end

  private

  attr_reader :server, :interpolator

  # Sort the server's required `${VAR}`s into those the providers answered
  # "not here" for and those they could not be asked about at all. Optional ones
  # (`${VAR:-default}`) are excluded — they fall back rather than failing.
  #
  # The two buckets are kept apart because they demand different things of the
  # user: one is "go set this", the other is "the store is down, wait".
  #
  # @return [Array(Array<String>, Array<String>, String, Array<VariableSource>)]
  #   [absent, unreachable, reason, sources]
  def classify_variables
    absent = []
    unreachable = []
    reason = nil
    sources = []

    server.required_variables.each do |name|
      resolution = interpolator.resolution(name)
      sources << VariableSource.new(variable: name, badge: resolution.source_badge,
        title: resolution.source_badge_title, resolved: resolution.found?)
      next if resolution.found?

      if resolution.unavailable?
        unreachable << name
        reason ||= resolution.error.message
      else
        absent << name
      end
    end

    [ absent, unreachable, reason, sources ]
  end

  def oauth_capable?
    McpOauthCredentialInjector.oauth_capable_server?(server.name)
  end

  def oauth_status
    credential = stored_credential
    return status(:needs_authorization) if credential.nil?
    return status(:ready, credential: credential) if credential.active?
    return status(:token_expired, credential: credential) if credential.can_refresh?

    status(:needs_reauth, credential: credential)
  end

  # The credential the injector would find for this server — keyed on the same
  # {type, url, headers} digest, so a catalog change that invalidates the key
  # shows up here as "needs authorization" exactly as it does at spawn time.
  def stored_credential
    config = ServersConfig.credential_config(server.name)
    return nil if config.nil?

    key = McpOauthCredential.compute_credential_key(server.name, config)
    McpOauthCredential.for_credential_key(key).order(updated_at: :desc).first
  end

  def status(state, **attrs)
    Status.new(server: server, state: state, variable_sources: @variable_sources || [], **attrs)
  end
end

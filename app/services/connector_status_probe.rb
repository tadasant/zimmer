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
# Ahead of all three sits the one thing it cannot work out for itself: a catalog
# entry carrying an `"unavailable": "<reason>"` declaration is reported
# :declared_unavailable without any of the checks being run. That covers the
# server whose configuration is impeccable and whose endpoint still cannot serve
# Zimmer — a fact only the catalog's curator knows.
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
    declared_unavailable
    store_unavailable
    probe_failed
  ].freeze

  # The states in which attaching the server to a session cannot work, and no
  # amount of waiting changes that. This is the definition every surface reads:
  # the Connectors page renders it per row, `get_configs` omits these servers
  # from the options it offers an agent, and `McpServerOptions` flags them in
  # the web pickers and the REST server lists.
  #
  # :token_expired is deliberately absent — that credential has a refresh token
  # and RefreshMcpOauthTokensJob renews it without anyone's help.
  #
  # :store_unavailable and :probe_failed are absent for a different reason:
  # they mean Zimmer could not find out, not that the answer is no. Both are
  # transient and both hit every server at once — a store blip would empty the
  # whole option list and send an agent off to register servers that already
  # exist. Reporting an indeterminate server as usable is the cheaper mistake.
  BLOCKING_STATES = %i[missing_configuration needs_authorization needs_reauth declared_unavailable].freeze

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
      variable_sources: [], credential_key: nil)
      @server = server
      @state = state
      @missing_variables = missing_variables
      @credential = credential
      @error_message = error_message
      @variable_sources = variable_sources
      @credential_key = credential_key
    end

    # What the server last advertised about needing OAuth, read lazily.
    #
    # Lazy on purpose: `#summary` is the only caller, and the two hottest readers
    # of this class — `get_configs` and `McpServerOptions` — render
    # `#unavailable_reason` instead and never ask. Resolving it eagerly in
    # `.all` would put one query per credential-less server, up to the size of
    # the catalog, on a routing session's critical path to produce a string
    # nobody reads. Memoized through `defined?` so a repeat ask is free.
    #
    # @return [String] one of McpServerOauthRequirement::DETERMINATIONS
    def oauth_determination
      return @oauth_determination if defined?(@oauth_determination)

      @oauth_determination = McpServerOauthRequirement.determination_for(@credential_key)
    end

    def server_name = server.name
    def title = server.title

    def ready? = state == :ready
    def missing_configuration? = state == :missing_configuration
    def declared_unavailable? = state == :declared_unavailable

    # Can a session attach this server right now? See BLOCKING_STATES.
    def available? = !BLOCKING_STATES.include?(state)

    # Why not, in a few words — for a roster that names unusable servers without
    # re-describing them. Terse on purpose: it has to fit on one line next to
    # the server name, and its job is to let a reader tell "exists but cannot be
    # used" from "does not exist". nil when the server is available.
    #
    # Markdown by default, because its first reader was `get_configs` and that
    # output is markdown. The web pickers and the REST lists ask for
    # `markdown: false`, where a backtick would render as a backtick. Same
    # states and the same words either way — only the variable names change
    # dress, so the two surfaces cannot say different things.
    #
    # The Connectors page renders #summary instead — same states, a sentence
    # each, addressed to someone who can go and fix them.
    #
    # @param markdown [Boolean] backtick `${VAR}` names for a markdown reader
    # @return [String, nil]
    def unavailable_reason(markdown: true)
      case state
      when :missing_configuration
        names = missing_variables.map { |name| markdown ? "`#{name}`" : name }
        "#{names.join(', ')} unresolved"
      when :needs_authorization
        "OAuth authorization not completed"
      when :needs_reauth
        "OAuth token expired and cannot be refreshed"
      when :declared_unavailable
        server.unavailable_reason
      end
    end

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
      when :declared_unavailable then "Unavailable"
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
        "No OAuth credential is stored yet. Authorize it here — you don't need a session." \
        "#{determination_sentence}"
      when :token_expired
        "The stored access token has expired. It has a refresh token, so RefreshMcpOauthTokensJob will renew it automatically."
      when :needs_reauth
        "The stored access token has expired and carries no refresh token. Authorize it again to replace it."
      when :missing_configuration
        "#{'Variable'.pluralize(missing_variables.size)} #{missing_variables.to_sentence} #{missing_variables.one? ? 'has' : 'have'} no value, so this server cannot start."
      when :declared_unavailable
        "The catalog declares this server unavailable, so nothing on this page will fix it — " \
        "the catalog entry has to change. Reason given: #{server.unavailable_reason}"
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

    # True when the server issued this credential without a refresh token, so
    # re-authorizing by hand is a recurring chore rather than a one-off. Said on
    # the row for every state that has such a credential — including :ready,
    # which is exactly where the surprise is otherwise stored up.
    def requires_periodic_reauth? = !!credential&.requires_periodic_reauth?

    private

    # Why this row says what it says, when the reason is the OAuth determination
    # rather than the stored credential.
    #
    # "Needs authorization" has two very different causes and used to read the
    # same for both: a server that advertises an OAuth requirement, and a remote
    # server nobody could classify, which Zimmer assumes might need one. Only the
    # second is a guess, and only the second is worth chasing when the server
    # turns out not to need OAuth at all. Silent when the answer adds nothing —
    # a server that advertised its requirement is not a mystery.
    #
    # @return [String]
    def determination_sentence
      case oauth_determination
      when McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED
        " Note: the last check found this server serving unauthenticated requests, " \
        "so it may not need authorization at all."
      when McpServerOauthRequirement::UNDETERMINED
        " Zimmer has not been able to confirm that this server requires OAuth — " \
        "no check has returned an answer — so it assumes it might."
      else
        ""
      end
    end

    # Ready has two shapes: an OAuth flow that has been completed, and a server
    # whose static credential variables are all set. Saying which one is what
    # tells the user whether there is a token they could revoke.
    def ready_summary
      return static_ready_summary if credential.nil?

      if credential.expires_at.nil?
        "OAuth is complete and the credential is saved. It does not expire."
      elsif credential.requires_periodic_reauth?
        "OAuth is complete and the credential is saved. The access token expires in " \
        "#{distance_of_time_in_words(Time.current, credential.expires_at)} and cannot be renewed."
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

  # Every catalog server's status, in catalog order.
  #
  # For callers that need the whole picture at once rather than one row at a
  # time — `get_configs`, which has to split the catalog into what an agent may
  # attach and what it may not. It is the same probe per server, so the two
  # surfaces cannot drift.
  #
  # What this costs, stated honestly, because a routing session calls it on its
  # critical path: one indexed credential lookup per OAuth-capable server, and
  # secret resolution through SecretProviders' chain. (The recorded OAuth
  # determination is a second indexed lookup, but `Status#oauth_determination`
  # defers it until something asks for the row's prose, and `get_configs` never
  # does.) When the Parameter Store
  # link is configured that chain CAN go to Google — it holds a 60-second
  # namespace snapshot, and a variable missing from the snapshot forces one
  # re-read (rate-limited to once per 10s across the process). That is the same
  # read the spawn itself would do, seconds later, and it is bounded.
  #
  # What it never does is probe an MCP server. There is no per-server network
  # call here and no request whose count grows with the catalog, which is what
  # keeps this deterministic enough to sit in front of a routing decision.
  #
  # @return [Array<Status>]
  def self.all
    interpolator = SecretsInterpolator.new
    ServersConfig.all.map { |server| new(server, interpolator: interpolator).call }
  end

  # @param server [ServersConfig::Server]
  def initialize(server, interpolator: SecretsInterpolator.new)
    @server = server
    @interpolator = interpolator
  end

  # @return [Status]
  def call
    return status(:declared_unavailable) if server.declared_unavailable?

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
        title: resolution.source_badge_title(name), resolved: resolution.found?)
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
    return status(:ready, credential: credential) if credential&.active?
    return status(:token_expired, credential: credential) if credential&.can_refresh?
    return status(:needs_reauth, credential: credential) if credential

    # No credential at all. This is the row where the difference between a server
    # that advertises OAuth and one nobody could classify is worth saying out
    # loud, so it carries the key to read the recorded determination under —
    # the key, not the determination, so the lookup happens only if someone asks
    # for the sentence. Still a local read either way: McpServerOauthRequirement
    # holds what an earlier probe already learned, and this class does not
    # contact MCP servers.
    status(:needs_authorization, credential_key: credential_key)
  end

  # The credential the injector would find for this server — keyed on the same
  # {type, url, headers} digest, so a catalog change that invalidates the key
  # shows up here as "needs authorization" exactly as it does at spawn time.
  def stored_credential
    return nil if credential_key.nil?

    McpOauthCredential.for_credential_key(credential_key).order(updated_at: :desc).first
  end

  # The {type, url, headers} digest this server's credential and OAuth
  # determination are both filed under. nil when the server has no catalog
  # credential config, memoized through `defined?` so that nil is cached too.
  def credential_key
    return @credential_key if defined?(@credential_key)

    config = ServersConfig.credential_config(server.name)
    @credential_key = config && McpOauthCredential.compute_credential_key(server.name, config)
  end

  def status(state, **attrs)
    Status.new(server: server, state: state, variable_sources: @variable_sources || [], **attrs)
  end
end

# Base controller for API v1 endpoints.
# Provides API key authentication via the X-API-Key header.
#
# A key is either an entry in the API_KEYS environment variable (comma-separated)
# or one minted on the API keys settings page. Both are ApiKey rows, which is what
# gives every request a key name for the log and lets a revoke take effect on the
# next request — see ApiKey.
#
# Usage:
#   curl -H "X-API-Key: your_api_key" https://example.com/api/v1/sessions
#
# A controller that declares `accepts_native_app_tokens` also takes
# `Authorization: Bearer <access token>` from Zimmer's own iOS app — an OAuth
# access token whose grant belongs to the built-in first-party client
# (OauthServer::NativeApp). It is opt-in per controller, so the phone's
# credential opens the surfaces the app drives and nothing else; a token any
# other OAuth client holds is refused here exactly as a bad key is.
class Api::BaseController < ActionController::API
  include ControllerDatabaseRetry

  class_attribute :native_app_tokens_accepted, instance_writer: false, default: false

  def self.accepts_native_app_tokens
    self.native_app_tokens_accepted = true
  end

  before_action :authenticate_api_key

  # Return 404 for not found records
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  # Return 422 for validation errors
  rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity

  private

  # Record the "uncle" lineage edge for a session-initiated queue/interrupt.
  #
  # The acting session is self-declared, via an `acting_session_id` on the
  # request body, because nothing about an API request identifies the caller:
  # one API key is shared by the whole fleet, so it names a key but not a
  # session. Omitting it records nothing — which is the right outcome for a
  # script or a human with a curl command, neither of which is a session.
  #
  # Deliberately absent from the web UI controllers: a person clicking "Send
  # Now" has no session on the other end, and the way to guarantee no edge is
  # written for them is for that path to have no way to declare one.
  def record_uncle_edge(session, source)
    Sessions::RecordUncleEdge.call(
      junior: session,
      acting_session_id: params[:acting_session_id],
      source: source
    )
  end

  # The one error envelope for the whole API surface.
  #
  # Every error response carries both `message` (a String) and `messages` (an
  # Array of the same content), so a consumer can read either key without
  # type-checking the value. Pass a String or an Array — `Array()` normalizes
  # both, and the String form is the Array joined with ", ".
  #
  # Extra top-level keys (e.g. `retry_after`) ride along via **extra.
  def render_api_error(error, message, status:, **extra)
    messages = Array(message).map(&:to_s)

    render json: {
      error: error,
      message: messages.join(", "),
      messages: messages
    }.merge(extra), status: status
  end

  # Every outcome is logged with the key's name, never the key. A success is INFO
  # (stdout, beside Rails' own request lines, tagged with the same request id). A
  # refusal that names a known key — revoked, or taken out of API_KEYS — is WARN,
  # so it ships to obs: that is a leaked or forgotten credential still being tried.
  def authenticate_api_key
    return authenticate_native_app_token if native_app_token_presented?

    authentication = ApiKey.authenticate(api_key_from_request, grant: api_key_grant)

    if authentication.authenticated?
      @authenticated_api_key = authentication.api_key
      Rails.logger.info("[api_key] #{request.request_method} #{request.path} authenticated as #{api_key_label(authentication.api_key)}")
    else
      log_api_key_refusal(authentication)
      render_api_error("Unauthorized", "Invalid or missing API key", status: :unauthorized)
    end
  end

  # Whether this request came from Zimmer's iOS app, signed in as a human. Unlike
  # an API key, which names a key, that grant names the person who approved the
  # phone, so a message typed in the app is a human's own words.
  def native_app_request?
    @native_app_grant.present?
  end

  def native_app_token_presented?
    native_app_tokens_accepted && native_app_bearer_token.present?
  end

  def native_app_bearer_token
    token = request.headers["Authorization"].to_s[/\ABearer\s+(.+)\z/i, 1]&.strip
    token if token&.start_with?(OauthServer::ACCESS_TOKEN_PREFIX)
  end

  # The same token check `/mcp` makes (expiry, revocation, audience), plus one
  # more: the grant must belong to the first-party app. Every refusal is the
  # same 401 a bad key gets; the log line says which it was.
  def authenticate_native_app_token
    config = OauthServer::Config.current
    lookup = if config.configured?
      OauthServer::Token.authenticate_access(native_app_bearer_token, resource: config.resource)
    else
      OauthServer::Token::Lookup.new(token: nil, refusal: :server_not_configured)
    end
    refusal = lookup.ok? && !lookup.grant.client.first_party? ? :not_the_native_app : lookup.refusal

    if refusal.nil?
      @native_app_grant = lookup.grant
      Rails.logger.info("[native_app] #{request.request_method} #{request.path} authenticated as grant #{@native_app_grant.id} (#{@native_app_grant.user_email})")
    else
      Rails.logger.info("[native_app] #{request.request_method} #{request.path} refused from #{request.remote_ip}: access token #{refusal}")
      render_api_error("Unauthorized", "Invalid or expired access token", status: :unauthorized)
    end
  end

  # Where the key lives on the request. Subclasses may widen this — the native
  # MCP endpoint also accepts `Authorization: Bearer <key>`, since MCP clients
  # configure a bearer token rather than a custom header.
  def api_key_from_request
    request.headers["X-API-Key"]
  end

  # Which ApiKey grant opens this controller. The whole API, unless a subclass
  # says otherwise — and the only one that does is the Quick Router ingest,
  # which honours the browser extension's `quick_router` keys and nothing else.
  # The match is exact in both directions, so overriding this narrows a
  # controller to one kind of key rather than adding one.
  def api_key_grant
    ApiKey::API_GRANT
  end

  def log_api_key_refusal(authentication)
    line = "[api_key] #{request.request_method} #{request.path} refused from #{request.remote_ip}: "

    case authentication.refusal
    when :revoked
      Rails.logger.warn("#{line}#{api_key_label(authentication.api_key)} was revoked at #{authentication.api_key.revoked_at.iso8601}")
    when :retired
      Rails.logger.warn("#{line}#{api_key_label(authentication.api_key)} is no longer in #{ApiKey::ENV_VAR}")
    when :wrong_grant
      # A `quick_router` key trying the API is the browser extension's credential
      # being used for something the extension never does.
      Rails.logger.warn("#{line}#{api_key_label(authentication.api_key)} has grant #{authentication.api_key.effective_grant}, not #{api_key_grant}")
    when :missing
      Rails.logger.info("#{line}no API key")
    else
      Rails.logger.info("#{line}unknown API key")
    end
  end

  # `inspect` quotes the name, so a newline in it cannot forge a second log line.
  def api_key_label(api_key)
    "#{api_key.name.inspect} (api_key_id=#{api_key.id || 'unsaved'}, source=#{api_key.source})"
  end

  def not_found
    render_api_error("Not Found", "The requested resource was not found", status: :not_found)
  end

  def unprocessable_entity(exception)
    render_api_error("Unprocessable Entity", exception.record.errors.full_messages, status: :unprocessable_entity)
  end

  # Pagination helper with validation
  def pagination_params
    {
      page: [ params[:page]&.to_i || 1, 1 ].max, # Minimum page 1
      per_page: [ [ params[:per_page]&.to_i || 25, 1 ].max, 100 ].min # Between 1-100
    }
  end

  # Apply pagination to a scope
  def paginate(scope)
    pagination = pagination_params
    offset = (pagination[:page] - 1) * pagination[:per_page]

    total = scope.count # Call count once for efficiency
    {
      records: scope.limit(pagination[:per_page]).offset(offset),
      pagination: {
        page: pagination[:page],
        per_page: pagination[:per_page],
        total_count: total,
        total_pages: (total.to_f / pagination[:per_page]).ceil
      }
    }
  end
end

# frozen_string_literal: true

# API controller for MCP server fallback elicitation endpoints.
#
# The pulsemcp fallback-elicitation protocol, as an MCP server speaks it:
#   POST  /api/v1/elicitations/session/:token      - Create an elicitation on the token's session
#   GET   /api/v1/elicitations/session/:token/:id  - Poll one of that session's elicitations
#
# The API-key surface:
#   POST  /api/v1/elicitations                     - Create an elicitation on _meta's session-id
#   GET   /api/v1/elicitations/:id                 - Poll any elicitation
#   PATCH /api/v1/elicitations/:id/respond         - Accept/decline/cancel a pending elicitation
#
# An MCP server has no API key, so it authenticates with the token in the path of
# the URL ElicitationEndpoint.spawn_env gave it (ElicitationEndpoint explains why
# the path). The token names one session, so on the token routes the session comes
# from the token, a `_meta` session-id naming a different session is refused, and
# a poll finds only that session's elicitations.
#
# respond is the programmatic counterpart to the human-only web path
# (ElicitationsController#respond_to_elicitation); it lets an authenticated API
# consumer (script, agent, or tool) resolve a pending elicitation. A token does not
# reach it: whoever raised a prompt must not be the one who answers it.
#
# On show, :id is the elicitation's request_id (the MCP-facing identifier). On
# respond it is either the request_id or the DB primary key, so the identifier a
# consumer already holds — from a poll response or from the web UI's own
# /elicitations/:id/respond route — works on both surfaces.
class Api::V1::ElicitationsController < Api::BaseController
  # create/show authenticate by the path's token when there is one and by the API
  # key otherwise. respond is API-key only, so it is NOT skipped here.
  skip_before_action :authenticate_api_key, only: [ :create, :show ]
  before_action :authenticate_elicitation_caller, only: [ :create, :show ]

  # POST /api/v1/elicitations/session/:token
  # POST /api/v1/elicitations
  def create
    meta = elicitation_meta
    request_id = meta["com.pulsemcp/request-id"]

    unless request_id.present?
      render_api_error("Missing parameter", "_meta[com.pulsemcp/request-id] is required", status: :unprocessable_entity)
      return
    end

    unless params[:message].present?
      render_api_error("Missing parameter", "message is required", status: :unprocessable_entity)
      return
    end

    session = session_for_create(meta, request_id)
    return unless session

    expires_at = parse_expiration(meta)

    elicitation = Elicitation.create!(
      session: session,
      request_id: request_id,
      mode: params[:mode] || "form",
      message: params[:message],
      requested_schema: params[:requestedSchema] || {},
      meta: meta,
      tool_name: meta["com.pulsemcp/tool-name"],
      context: meta["com.pulsemcp/context"],
      mcp_session_id: meta["com.pulsemcp/session-id"],
      expires_at: expires_at
    )

    # Send push notification
    SendPushNotificationJob.perform_later(session.id, :elicitation_pending, elicitation.message.truncate(150))

    # Broadcast elicitation banner to session detail page
    broadcast_elicitation_created(session, elicitation)

    render json: {
      action: "pending",
      _meta: {
        "com.pulsemcp/request-id" => request_id,
        "com.pulsemcp/poll-url" => poll_url_for(elicitation)
      }
    }, status: :created
  end

  # GET /api/v1/elicitations/session/:token/:id
  # GET /api/v1/elicitations/:id
  def show
    elicitation = elicitations_visible_to_caller.find_by!(request_id: params[:id])

    # Auto-expire if past expiration
    elicitation.expire_if_needed!

    render json: elicitation.to_poll_response
  rescue ActiveRecord::RecordNotFound
    render_api_error("Not Found", "Elicitation not found for request_id: #{params[:id]}", status: :not_found)
  end

  # PATCH /api/v1/elicitations/:id/respond
  #
  # Programmatic accept/decline of a pending elicitation. Mirrors the human web
  # path (ElicitationsController#respond_to_elicitation) but is authenticated and
  # returns the elicitation poll response as JSON.
  def respond
    elicitation = find_elicitation_for_respond!

    unless elicitation.pending?
      render_api_error("Unprocessable Entity", "Elicitation has already been resolved (status: #{elicitation.status})", status: :unprocessable_entity)
      return
    end

    action_type = params[:action_type]
    unless Elicitation::RESOLVE_ACTIONS.include?(action_type)
      render_api_error("Unprocessable Entity", "action_type must be one of: #{Elicitation::RESOLVE_ACTIONS.join(', ')}", status: :unprocessable_entity)
      return
    end

    elicitation.resolve!(action: action_type, content: response_content)

    broadcast_elicitation_resolved(elicitation.session, elicitation)

    render json: elicitation.to_poll_response
  rescue ActiveRecord::RecordNotFound
    render_api_error("Not Found", "Elicitation not found for: #{params[:id]}", status: :not_found)
  end

  private

  # Who may create or poll: the session a path token names, or an API-key holder.
  #
  # The token routes speak only tokens. One that does not verify is a 401 even with
  # a valid API key alongside it, so a key never makes a forged URL look sound.
  def authenticate_elicitation_caller
    token = request.path_parameters[:token]

    if token.nil?
      authenticate_api_key_or_warn
      return
    end

    @token_session = ElicitationEndpoint.session_for_token(token)
    return if @token_session

    if action_name == "create"
      Rails.logger.warn "[Api::V1::ElicitationsController] Elicitation POST with a session token that does not verify " \
        "(request_id: #{log_value(elicitation_meta['com.pulsemcp/request-id'])}) — a forged URL, or one minted under a different secret_key_base"
    end
    render_api_error("Unauthorized", "This elicitation URL does not belong to any session", status: :unauthorized)
  end

  # The bare routes take an API key. A keyless POST here is almost always an MCP
  # server that was never handed its session's URL — spawned without a session, or
  # pointed at the bare URL by a clone `.env` — so it warns, where obs sees it (INFO
  # isn't shipped), rather than failing as quietly as a denial would.
  def authenticate_api_key_or_warn
    authenticate_api_key
    return unless performed? && action_name == "create"

    meta = elicitation_meta
    Rails.logger.warn "[Api::V1::ElicitationsController] Elicitation POST without a session token or an API key " \
      "(request_id: #{log_value(meta['com.pulsemcp/request-id'])}, session-id: #{log_value(meta['com.pulsemcp/session-id'])}, " \
      "tool: #{log_value(meta['com.pulsemcp/tool-name'])}) — the MCP server was not given its session's ELICITATION_REQUEST_URL"
  end

  # A caller's value as it goes into a WARN line, which obs ships. Quoted, so a
  # newline in it cannot forge a second log line, and bounded.
  def log_value(value)
    value.to_s.truncate(80).inspect
  end

  # The session an elicitation is raised on, or nil after rendering the refusal.
  #
  # On a token route it is the token's session. `_meta` may still carry a
  # session-id — the client sends ELICITATION_SESSION_ID when it has one — and one
  # naming a different session is refused rather than overruled: a caller whose URL
  # and tag disagree is misconfigured or probing, and neither should land a prompt
  # anywhere. A blank one is fine, because the token already said who is asking.
  #
  # On the API-key route, `_meta` is the only place the session can come from.
  # `Session.locate` does not retry a numeric identifier as a slug: digits mean an
  # id on every surface, and the only slug such a retry could find is an all-digit
  # one, which the model refuses to write.
  def session_for_create(meta, request_id)
    claimed = meta["com.pulsemcp/session-id"]

    if @token_session
      return @token_session if claimed.blank? || Session.locate(claimed) == @token_session

      Rails.logger.warn "[Api::V1::ElicitationsController] Elicitation POST whose _meta session-id #{log_value(claimed)} " \
        "is not its token's session #{@token_session.id} (request_id: #{log_value(request_id)})"
      render_api_error("Forbidden", "_meta[com.pulsemcp/session-id] #{claimed} is not the session this elicitation URL belongs to", status: :forbidden)
      return nil
    end

    session = Session.locate(claimed)
    return session if session

    render_api_error("Session not found", "Could not find session for session-id: #{claimed}", status: :not_found)
    nil
  end

  # Where the caller polls. An MCP server goes back to its token route, since it
  # holds no key for the bare one.
  def poll_url_for(elicitation)
    if @token_session
      api_v1_session_elicitation_url(request.path_parameters[:token], elicitation.request_id)
    else
      api_v1_elicitation_url(elicitation.request_id)
    end
  end

  # A token sees its own session's elicitations; an API key sees them all. Another
  # session's request_id answers 404, the same as one that does not exist, so a
  # token cannot tell the two apart.
  def elicitations_visible_to_caller
    @token_session ? @token_session.elicitations : Elicitation
  end

  # `respond` resolves the same elicitation the web path resolves, so it takes
  # the same identifiers: the `request_id` (what `show` and the poll response
  # speak) or the numeric primary key (what `PATCH /elicitations/:id/respond`
  # in the UI speaks). Without this, an API consumer holding the id it read off
  # the web page could not act on it.
  #
  # Only `respond` is widened. `show` stays request_id-only on purpose — the poll
  # protocol speaks nothing else, and accepting a primary key there would turn it
  # into a sequential-id enumeration of whatever the caller can see.
  def find_elicitation_for_respond!
    identifier = params[:id].to_s

    by_request_id = Elicitation.find_by(request_id: identifier)
    return by_request_id if by_request_id

    return Elicitation.find(identifier) if identifier.match?(/\A\d+\z/)

    raise ActiveRecord::RecordNotFound, "Elicitation not found for: #{identifier}"
  end

  # Parse the optional content param into a plain Hash for storage. Accepts a
  # nested JSON object (ActionController::Parameters) or a JSON string.
  def response_content
    content = params[:content]
    return nil if content.blank?

    if content.is_a?(String)
      JSON.parse(content)
    elsif content.respond_to?(:to_unsafe_h)
      content.to_unsafe_h
    else
      content
    end
  rescue JSON::ParserError
    content
  end

  # Remove the elicitation banner from the session detail page. Guarded so a
  # broadcast failure never 500s the API response — the resolution has already
  # been persisted.
  def broadcast_elicitation_resolved(session, elicitation)
    BroadcastService.new.remove_elicitation_banner(session, elicitation)
  rescue => e
    Rails.logger.error "[Api::V1::ElicitationsController] Failed to broadcast elicitation removal: #{e.message}"
  end

  # Extract the _meta object from params, handling both nested and flat structures
  def elicitation_meta
    params[:_meta]&.to_unsafe_h || {}
  end

  # The deadline for this request.
  #
  # An MCP server that named its own `com.pulsemcp/expires-at` keeps it — it is
  # the one party that knows how long its call can stay open. Everything else
  # gets this instance's default: ELICITATION_EXPIRATION_MINUTES if the operator
  # set it, otherwise the built-in Elicitation::DEFAULT_EXPIRATION. An
  # unparseable timestamp is treated as if none was sent.
  #
  # The server's value is held to the same MIN/MAX bounds the operator's is. It
  # comes from a process Zimmer launched but did not write, so a deadline already
  # in the past would mint an elicitation that is born expired — one that resolves
  # straight into the "this approval request expired" banner — and one years out
  # would pin a session in needs_input.
  def parse_expiration(meta)
    requested = parse_requested_expiration(meta)
    return Elicitation.default_expiration.from_now if requested.nil?

    requested.clamp(Elicitation::MIN_EXPIRATION.from_now, Elicitation::MAX_EXPIRATION.from_now)
  end

  # The server's own timestamp, or nil when it sent none or sent nonsense.
  def parse_requested_expiration(meta)
    raw = meta["com.pulsemcp/expires-at"]
    return nil if raw.blank?

    Time.zone.parse(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def broadcast_elicitation_created(session, elicitation)
    BroadcastService.new.elicitation_banner(session, elicitation)
  rescue => e
    Rails.logger.error "[ElicitationsController] Failed to broadcast elicitation: #{e.message}"
  end
end

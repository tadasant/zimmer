# frozen_string_literal: true

# API controller for MCP server fallback elicitation endpoints.
#
# Provides three endpoints:
#   POST  /api/v1/elicitations         - Create a new elicitation request (MCP, unauthenticated)
#   GET   /api/v1/elicitations/:id     - Poll for elicitation status (MCP, unauthenticated)
#   PATCH /api/v1/elicitations/:id/respond - Accept/decline a pending elicitation (authenticated)
#
# create/show implement the pulsemcp fallback elicitation protocol: MCP servers
# POST approval requests here (unauthenticated), then poll for the user's
# response. respond is the programmatic counterpart to the human-only web path
# (ElicitationsController#respond_to_elicitation); it lets an authenticated API
# consumer (script, agent, or tool) resolve a pending elicitation, so it goes
# through standard API-key auth.
#
# On show, :id is the elicitation's request_id (the MCP-facing identifier). On
# respond it is either the request_id or the DB primary key, so the identifier a
# consumer already holds — from a poll response or from the web UI's own
# /elicitations/:id/respond route — works on both surfaces.
class Api::V1::ElicitationsController < Api::BaseController
  # create/show are called by MCP servers without an API key. respond is a
  # programmatic action and must be authenticated, so it is NOT skipped here.
  skip_before_action :authenticate_api_key, only: [ :create, :show ]

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

    session_identifier = meta["com.pulsemcp/session-id"]
    session = find_session_from_meta(meta)

    unless session
      # A blank session-id means the MCP server process was spawned without
      # ELICITATION_SESSION_ID (so @pulsemcp/mcp-elicitation omitted the tag). This
      # is a spawn-env defect, not a stale/expired session — warn so it surfaces in
      # obs (INFO isn't shipped) instead of silently 404ing. A present-but-unknown id
      # is a genuine not-found; log at info to keep it out of the alert stream.
      if session_identifier.blank?
        Rails.logger.warn "[Api::V1::ElicitationsController] Elicitation POST arrived with blank session-id (request_id: #{request_id}, tool: #{meta['com.pulsemcp/tool-name']}) — the MCP server was spawned without ELICITATION_SESSION_ID"
      else
        Rails.logger.info "[Api::V1::ElicitationsController] Elicitation POST for unknown session-id: #{session_identifier} (request_id: #{request_id})"
      end
      render_api_error("Session not found", "Could not find session for session-id: #{session_identifier}", status: :not_found)
      return
    end

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

    poll_url = api_v1_elicitation_url(elicitation.request_id)

    render json: {
      action: "pending",
      _meta: {
        "com.pulsemcp/request-id" => request_id,
        "com.pulsemcp/poll-url" => poll_url
      }
    }, status: :created
  end

  # GET /api/v1/elicitations/:id
  def show
    elicitation = Elicitation.find_by!(request_id: params[:id])

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

  # `respond` resolves the same elicitation the web path resolves, so it takes
  # the same identifiers: the `request_id` (what `show` and the poll response
  # speak) or the numeric primary key (what `PATCH /elicitations/:id/respond`
  # in the UI speaks). Without this, an API consumer holding the id it read off
  # the web page could not act on it.
  #
  # Only `respond` is widened. `show` stays request_id-only on purpose — it is
  # unauthenticated for the MCP poll protocol, and accepting a primary key there
  # would turn it into a sequential-id enumeration of every elicitation.
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

  # Find the Zimmer session from the meta session-id
  def find_session_from_meta(meta)
    session_identifier = meta["com.pulsemcp/session-id"]
    return nil unless session_identifier.present?

    # Try by Zimmer ID first (only if numeric), then by slug
    if session_identifier.to_s.match?(/\A\d+\z/)
      Session.find_by(id: session_identifier) || Session.find_by(slug: session_identifier)
    else
      Session.find_by(slug: session_identifier)
    end
  end

  # The deadline for this request.
  #
  # An MCP server that named its own `com.pulsemcp/expires-at` keeps it — it is
  # the one party that knows how long its call can stay open. Everything else
  # gets this instance's default: ELICITATION_EXPIRATION_MINUTES if the operator
  # set it, otherwise the built-in Elicitation::DEFAULT_EXPIRATION. An
  # unparseable timestamp is treated as if none was sent.
  def parse_expiration(meta)
    if meta["com.pulsemcp/expires-at"].present?
      Time.zone.parse(meta["com.pulsemcp/expires-at"]) || Elicitation.default_expiration.from_now
    else
      Elicitation.default_expiration.from_now
    end
  rescue ArgumentError
    Elicitation.default_expiration.from_now
  end

  def broadcast_elicitation_created(session, elicitation)
    BroadcastService.new.elicitation_banner(session, elicitation)
  rescue => e
    Rails.logger.error "[ElicitationsController] Failed to broadcast elicitation: #{e.message}"
  end
end

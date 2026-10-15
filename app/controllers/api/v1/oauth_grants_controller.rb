# frozen_string_literal: true

# The MCP connections list on Settings → API keys (OauthServer::Grant), for the
# iOS app: the same rows the page lists, and the two things the page lets a
# person do to one — revoke it, or move it between "acts on your behalf" and
# "relay only".
#
# Both writes take the app's sign-in acting as you, and nothing else: an API key
# is the fleet's, and one that could revoke connections could disconnect every
# phone from a session's shell. A relay-only app may read the list — its own row
# is flagged `current` — but may not revoke even itself here; it signs out through
# `POST /oauth/revoke`, like any OAuth client.
class Api::V1::OauthGrantsController < Api::BaseController
  accepts_native_app_tokens

  before_action :require_a_person_on_the_app, only: [ :update, :destroy ]
  before_action :set_grant, only: [ :update, :destroy ]

  # GET /api/v1/oauth_grants
  #
  # The page's list: active connections first, most recently used first, at
  # most 50. `current` marks the caller's own connection, so the app can say
  # "this phone"; it is false on every row for an API key.
  def index
    grants = OauthServer::Grant.includes(:client).listed.limit(50).to_a
    render json: { oauth_grants: grants.map { |grant| grant_json(grant) } }
  end

  # PATCH /api/v1/oauth_grants/:id — `privilege`: `act_as_human` or `relay_only`.
  #
  # Applies from the connection's next request. 422 for any other value, and
  # for a revoked connection, which has to be approved again to reconnect. A
  # connection already at that level is left alone, and still answers 200.
  # Lowering the caller's own connection is allowed; its writes here are then
  # refused until a person raises it again on the page.
  def update
    privilege = params[:privilege].to_s
    unless OauthServer::PRIVILEGES.include?(privilege)
      return render_api_error("Unknown privilege level", "privilege must be one of #{OauthServer::PRIVILEGES.join(', ')}",
                              status: :unprocessable_entity)
    end
    if @grant.revoked?
      return render_api_error("Connection revoked", "#{@grant.client_label}'s connection is revoked; approve it again to reconnect",
                              status: :unprocessable_entity)
    end

    reason = privilege == OauthServer::ACT_AS_HUMAN ? OauthServer::Grant::APP_UPGRADE : OauthServer::Grant::APP_DOWNGRADE
    # The model logs the change; the actor rides on the reason, so it is not logged twice.
    @grant.change_privilege!(privilege, reason: reason)

    message = if privilege == OauthServer::ACT_AS_HUMAN
      "#{@grant.client_label} now acts on your behalf: messages it sends are recorded as yours."
    else
      "#{@grant.client_label} is now relay only: messages it sends are recorded as the assistant's, from its next request on."
    end
    render json: { oauth_grant: grant_json(@grant), message: message }
  end

  # DELETE /api/v1/oauth_grants/:id
  #
  # Revokes the connection: its access token is refused from the next request on
  # and its refresh token ends, so the client has to be approved again. The
  # caller's own connection included — the response says `signed_out: true`, and
  # the app's next request is a 401. A connection already revoked answers 200
  # unchanged.
  def destroy
    own = @grant.id == native_app_grant.id
    @grant.revoke!("revoked from #{native_app_actor}")
    render json: {
      oauth_grant: grant_json(@grant),
      signed_out: own,
      message: "Revoked #{@grant.client_label}'s connection. It is refused from the next request on."
    }
  end

  private

  def set_grant
    @grant = OauthServer::Grant.includes(:client).find(params[:id])
  end

  # What the page shows on a row, as data. `client_name` is the client's own
  # name for itself and untrusted; `client_label` is it or "Unnamed client".
  def grant_json(grant)
    client = grant.client
    {
      id: grant.id,
      client_name: client.client_name.presence,
      client_label: grant.client_label,
      client_id: client.client_id,
      first_party: client.first_party?,
      registration: client.cimd? ? "published" : "self_registered",
      publisher_host: client.cimd? ? client.publisher_host : nil,
      user_email: grant.user_email,
      privilege: grant.privilege,
      acts_as_you: grant.acts_as_human?,
      status: grant.revoked? ? "revoked" : "active",
      current: native_app_request? && grant.id == native_app_grant.id,
      created_at: grant.created_at,
      last_used_at: grant.last_used_at,
      scope_changed_at: grant.scope_changed_at,
      scope_change_reason: grant.scope_change_reason,
      revoked_at: grant.revoked_at,
      revocation_reason: grant.revocation_reason
    }
  end
end

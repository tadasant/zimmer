# frozen_string_literal: true

# The API keys list on Settings → API keys (ApiKey), for the iOS app: the rows
# the page lists, minting a named key, revoking one, restoring one revoked by
# mistake. The web page's controller is ApiKeysController; this mirrors what it
# accepts and what it logs.
#
# The writes take the app's sign-in acting as you, and nothing else. The reason
# the page has no API-key sibling holds here unchanged: a key that could mint
# keys would be self-issuing, and one that could revoke them would let any
# session holding a key disconnect every other. A person on their phone is
# neither, which is what the grant's privilege proves.
class Api::V1::ApiKeysController < Api::BaseController
  accepts_native_app_tokens

  before_action :require_a_person_on_the_app, only: [ :create, :destroy, :restore ]
  before_action :set_api_key, only: [ :destroy, :restore ]

  # GET /api/v1/api_keys
  #
  # Every key by name — active first, newest first — with its fingerprint (the
  # first eight characters of its SHA-256, the page's way of matching a key you
  # hold to its row) and never the key itself. `status` is `active`, `revoked`,
  # or `retired` (an `API_KEYS` entry no longer in the variable).
  # `agent_sessions_use_it` marks the key this deployment writes into every agent
  # session's Zimmer MCP servers, as the page does before it lets anyone revoke it.
  def index
    ApiKey.register_env_keys
    scope = ApiKey.listed
    scope = scope.includes(:external_app) if ApiKey.column_names.include?("external_app_id")
    digest = self_session_digest
    render json: { api_keys: scope.map { |api_key| api_key_json(api_key, self_session_digest: digest) } }
  end

  # POST /api/v1/api_keys — `name` (required, 100 characters, no control
  # characters, unique), `grant` (`api` for the whole API, the default, or
  # `quick_router` for the browser extension's ingest and nothing else).
  #
  # → 201 `{api_key, token}`. `token` is the only copy of the key there will ever
  # be: Zimmer keeps a digest, the list never shows it, and the response is
  # `no-store`. 422 with the page's messages for a name that is taken or
  # malformed, or a grant that is not one a person may mint.
  def create
    api_key, token = ApiKey.mint!(name: submitted_name, grant: submitted_grant)
    log_lifecycle("minted", api_key)
    response.headers["Cache-Control"] = "no-store"
    render json: { api_key: api_key_json(api_key, self_session_digest: nil), token: token }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_api_error("Key not created", e.record.errors.full_messages, status: :unprocessable_entity)
  rescue ActiveRecord::RecordNotUnique
    render_api_error("Key not created", "Name has already been taken", status: :unprocessable_entity)
  rescue ActiveRecord::ActiveRecordError => e
    render_api_error("Key not created", e.message, status: :unprocessable_entity)
  end

  # DELETE /api/v1/api_keys/:id — revoke. Requests with the key are refused from
  # the next one on; the row stays, so `restore` can undo it.
  def destroy
    @api_key.revoke!
    log_lifecycle("revoked", @api_key)
    render json: { api_key: api_key_json(@api_key, self_session_digest: self_session_digest),
                   message: "Revoked #{@api_key.name}. Requests with it are refused from now on." }
  end

  # POST /api/v1/api_keys/:id/restore — the page's Restore: a revoked key
  # authenticates again at once.
  def restore
    @api_key.restore!
    log_lifecycle("restored", @api_key)
    render json: { api_key: api_key_json(@api_key, self_session_digest: self_session_digest),
                   message: "Restored #{@api_key.name}. It authenticates again." }
  end

  private

  def set_api_key
    @api_key = ApiKey.find(params[:id])
  end

  # `name` at the top level, or `api_key[name]` as the page's form sends it.
  def submitted_name
    nested = params[:api_key]
    value = nested.is_a?(ActionController::Parameters) ? nested[:name] : params[:name]
    value.is_a?(String) ? value : nil
  end

  # As the page: the whole API when none was sent, and an unrecognised value
  # passed through for the model to refuse rather than widened to everything.
  def submitted_grant
    nested = params[:api_key]
    value = nested.is_a?(ActionController::Parameters) ? nested[:grant] : params[:grant]
    value.to_s.presence || ApiKey::API_GRANT
  end

  # The page's marker for the key agent sessions hold. A lookup that fails costs
  # the marker, not the list.
  def self_session_digest
    key = SelfSessionInjector.new.self_target[:api_key].to_s.strip
    key.present? ? ApiKey.digest(key) : nil
  rescue StandardError => e
    Rails.logger.warn("[api_key] could not resolve the self-session key to mark it: #{e.class}: #{e.message.truncate(200)}")
    nil
  end

  def api_key_json(api_key, self_session_digest:)
    status = if api_key.revoked? then "revoked"
    elsif api_key.retired? then "retired"
    else "active"
    end
    external_app = api_key.external_app? && api_key.respond_to?(:external_app) ? api_key.external_app : nil

    {
      id: api_key.id,
      name: api_key.name,
      status: status,
      source: api_key.source,
      grant: api_key.effective_grant,
      fingerprint: api_key.fingerprint,
      external_app: external_app ? { id: external_app.id, name: external_app.name } : nil,
      agent_sessions_use_it: api_key.self_session_key?(self_session_digest),
      last_used_at: api_key.last_used_at,
      created_at: api_key.created_at,
      revoked_at: api_key.revoked_at
    }
  end

  # The page's audit line, with the actor the page cannot name: WARN, so it ships
  # to obs, saying which key was created, revoked or restored, by whom, and when.
  def log_lifecycle(verb, api_key)
    Rails.logger.warn(
      "[api_key] #{verb} #{api_key.name.inspect} (api_key_id=#{api_key.id}, source=#{api_key.source}, grant=#{api_key.effective_grant}) " \
      "from #{native_app_actor}"
    )
  end
end

# frozen_string_literal: true

# The API keys settings page (tadasant/zimmer#46): list every key by name with
# when it was last used, mint a named key, revoke one, restore one revoked by
# mistake.
#
# **No credential guards this page**, the same as the rest of the web UI: the
# network perimeter is the authentication boundary. Anything that can reach the
# host can mint and revoke keys here, and that includes the fleet's own agent
# sessions, which run on the host.
#
# It is deliberately browser-only, with no REST or MCP sibling. An API
# key that could mint API keys would make the credential self-issuing, and one
# that could revoke them would let any session holding a key disconnect every
# other session from Zimmer by revoking the key they share. That keeps key
# management out of the tools a session is handed. It is not a wall: a
# session's shell can drive this page with `curl`.
class ApiKeysController < ApplicationController
  before_action :set_api_key, only: [ :revoke, :restore ]

  def index
    load_page
  end

  # Rendered rather than redirected: the response is the only place the new key
  # will ever appear, and a redirect would have to carry it through the flash —
  # which is to say, the session cookie. `no-store` keeps it out of the browser's
  # HTTP cache, and the view exempts the page from Turbo's snapshot cache.
  def create
    @api_key, @minted_token = ApiKey.mint!(name: submitted_name, grant: submitted_grant)
    log_lifecycle("minted", @api_key)
    response.headers["Cache-Control"] = "no-store"
    load_page
    render :index
  rescue ActiveRecord::RecordInvalid => e
    render_create_error(e.record.errors.full_messages)
  rescue ActiveRecord::RecordNotUnique
    # Two submits of one name at once (a double-click): the loser passes the
    # uniqueness validation and meets the unique index instead.
    render_create_error([ "Name has already been taken" ])
  rescue ActiveRecord::ActiveRecordError => e
    # Last, so the two specific rescues above keep their own wording. Reaches
    # the refusal `mint!` raises when the grant column is not on the table yet:
    # a refusal this page can state is better than a 500.
    render_create_error([ e.message ])
  end

  def revoke
    @api_key.revoke!
    log_lifecycle("revoked", @api_key)
    redirect_to api_keys_path, notice: "Revoked #{@api_key.name}. Requests with it are refused from now on."
  end

  def restore
    @api_key.restore!
    log_lifecycle("restored", @api_key)
    redirect_to api_keys_path, notice: "Restored #{@api_key.name}. It authenticates again."
  end

  private

  def set_api_key
    @api_key = ApiKey.find(params[:id])
  end

  # `api_key[name]` from the form; nil for anything else, including a scalar
  # `api_key` that `dig` would raise on.
  def submitted_name
    submitted = params[:api_key]
    submitted[:name] if submitted.is_a?(ActionController::Parameters)
  end

  # `api_key[grant]` from the form; the full API when the form sent none, as a
  # form from before the choice existed would. A value that is present but not
  # a grant is passed through for the model to refuse: silently widening an
  # unrecognised narrow choice to the whole API is the one wrong answer here.
  def submitted_grant
    submitted = params[:api_key]
    grant = submitted[:grant].to_s if submitted.is_a?(ActionController::Parameters)
    grant.presence || ApiKey::API_GRANT
  end

  def render_create_error(messages)
    @create_errors = messages
    @attempted_name = submitted_name
    @attempted_grant = submitted_grant
    load_page
    render :index, status: :unprocessable_entity
  end

  # `register_env_keys` gives every `API_KEYS` entry its row before the list is
  # read, so a key that has not been used since this table existed is still
  # listed — and can be revoked before it is ever used.
  def load_page
    ApiKey.register_env_keys
    @api_keys = ApiKey.listed.to_a
    @self_session_digest = self_session_digest
  end

  # The digest of the key this deployment writes into its own sessions' Zimmer
  # MCP entries, so the page can mark that row. A lookup that fails costs the
  # marker, not the page.
  def self_session_digest
    key = SelfSessionInjector.new.self_target[:api_key].to_s.strip
    key.present? ? ApiKey.digest(key) : nil
  rescue StandardError => e
    Rails.logger.warn("[api_key] could not resolve the self-session key to mark it: #{e.class}: #{e.message.truncate(200)}")
    nil
  end

  # WARN, so it ships to obs: which key was created, revoked or restored, and when,
  # is the audit trail this page exists to give.
  def log_lifecycle(verb, api_key)
    Rails.logger.warn(
      "[api_key] #{verb} #{api_key.name.inspect} (api_key_id=#{api_key.id}, source=#{api_key.source}, grant=#{api_key.effective_grant}) " \
      "from the settings page, #{request.remote_ip}"
    )
  end
end

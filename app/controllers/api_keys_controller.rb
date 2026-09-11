# frozen_string_literal: true

# The API keys settings page (tadasant/zimmer#46): list every key by name with
# when it was last used, mint a named key, revoke one, restore one revoked by
# mistake.
#
# **The whole page sits behind the operator credential** (OperatorHttpBasicAuth,
# `SUPERVISOR_PASSWORD`), not just its writes. That is the one credential the
# fleet's own agent sessions do not hold — they hold an API key. So this is
# deliberately browser-only, with no REST or MCP sibling: a surface where an API
# key could mint API keys would make the credential self-issuing, and one where
# it could revoke them would let any session disconnect every other session from
# Zimmer by revoking the key they share. Deciding who holds a credential stays
# with the human.
#
# It fails closed like every other operator surface: with `SUPERVISOR_PASSWORD`
# unset the page is closed, and the `API_KEYS` entries keep authenticating as
# they always did.
class ApiKeysController < ApplicationController
  include SpeculativeRequest
  include OperatorHttpBasicAuth

  before_action :authenticate_operator
  before_action :set_api_key, only: [ :revoke, :restore ]

  def index
    load_page
  end

  # Rendered rather than redirected: the response is the only place the new key
  # will ever appear, and a redirect would have to carry it through the flash —
  # which is to say, the session cookie. `no-store` keeps it out of the browser's
  # HTTP cache, and the view exempts the page from Turbo's snapshot cache.
  def create
    @api_key, @minted_token = ApiKey.mint!(name: submitted_name)
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

  def render_create_error(messages)
    @create_errors = messages
    @attempted_name = submitted_name
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
      "[api_key] #{verb} #{api_key.name.inspect} (api_key_id=#{api_key.id}, source=#{api_key.source}) " \
      "from the settings page, #{request.remote_ip}"
    )
  end

  # Mirrors HealthController: a real navigation gets the Basic challenge; a
  # hover-prefetch gets the refusal without it, so the cursor crossing the
  # Settings link does not open a sign-in dialog; an unconfigured realm says so
  # instead of prompting for a credential nothing can satisfy.
  def refuse_operator(realm_configured: true)
    message = if realm_configured
      "The API keys page needs the operator credential (HTTP Basic, the same one " \
        "#{OperatorHttpBasicAuth::PASSWORD_ENV} sets for /supervisor)."
    else
      "#{OperatorHttpBasicAuth::PASSWORD_ENV} is unset or blank, so the API keys page is closed. " \
        "Set it in the deployment's secrets to use it. Keys in #{ApiKey::ENV_VAR} keep working either way."
    end

    if realm_configured && !prefetch_request?
      request_http_basic_authentication(OperatorHttpBasicAuth::REALM, message)
    else
      render plain: message, status: :unauthorized
    end
  end
end

# frozen_string_literal: true

# Settings → Zimmer plugins: register an external app, choose which triggers it may
# invoke, turn it off, and mint and revoke its keys. See ExternalApp.
#
# No credential guards this page, the same as the rest of the web UI and the API
# keys page: the network perimeter is the authentication boundary. The MCP sibling
# is the opt-in `external_apps` tool group (`search_external_apps`,
# `action_external_app`).
#
# Minting a plugin key here, or through that tool, hands out nothing the minter did
# not already have: a plugin key invokes a subset of the triggers any full-API key
# can invoke, and reaches nothing else. That is why, unlike an `api` key, it can be
# minted over MCP.
class ExternalAppsController < ApplicationController
  before_action :set_external_app, only: %i[show update destroy mint_key revoke_key]

  def index
    load_index
  end

  def create
    @external_app = ExternalApp.new(name: submitted[:name].to_s.strip, description: submitted[:description].to_s.strip.presence)
    @external_app.save!
    log_lifecycle("registered", @external_app)
    redirect_to external_app_path(@external_app), notice: "Registered #{@external_app.name}. Choose the triggers it may invoke, then create a key."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    @create_errors = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages : [ "Name has already been taken" ]
    load_index
    render :index, status: :unprocessable_entity
  end

  def show
    load_show
  end

  def update
    ExternalApp.transaction do
      @external_app.assign_attributes(
        name: submitted[:name].to_s.strip,
        description: submitted[:description].to_s.strip.presence,
        enabled: ActiveModel::Type::Boolean.new.cast(submitted[:enabled]) || false
      )
      @external_app.save!
      @external_app.replace_triggers!(submitted_trigger_ids)
    end
    log_lifecycle("updated", @external_app, "enabled=#{@external_app.enabled?} triggers=#{@external_app.trigger_ids.sort.join(',')}")
    redirect_to external_app_path(@external_app), notice: "Saved #{@external_app.name}."
  rescue ActiveRecord::RecordInvalid, ExternalApp::InvalidAllowlist => e
    @update_errors = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages : [ e.message ]
    @external_app.reload
    load_show
    render :show, status: :unprocessable_entity
  end

  def destroy
    @external_app.destroy!
    log_lifecycle("deleted", @external_app)
    redirect_to external_apps_path, notice: "Deleted #{@external_app.name} and its keys."
  end

  # Rendered rather than redirected, like ApiKeysController#create: the response is
  # the only place the key will ever appear.
  def mint_key
    @api_key, @minted_token = @external_app.mint_key!
    log_lifecycle("minted a key for", @external_app, "api_key_id=#{@api_key.id}")
    response.headers["Cache-Control"] = "no-store"
    load_show
    render :show
  rescue ActiveRecord::ActiveRecordError => e
    @update_errors = [ e.message ]
    load_show
    render :show, status: :unprocessable_entity
  end

  def revoke_key
    api_key = @external_app.api_keys.find(params[:api_key_id])
    api_key.revoke!
    log_lifecycle("revoked a key for", @external_app, "api_key_id=#{api_key.id}")
    redirect_to external_app_path(@external_app), notice: "Revoked #{api_key.name}. Requests with it are refused from now on."
  end

  private

  def set_external_app
    @external_app = ExternalApp.find(params[:id])
  end

  # `external_app[...]` from the form, or an empty set for anything else.
  def submitted
    raw = params[:external_app]
    raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new
  end

  def submitted_trigger_ids
    ids = submitted[:trigger_ids]
    ids.is_a?(Array) ? ids : []
  end

  def load_index
    @external_apps = ExternalApp.listed.includes(:triggers, :api_keys).to_a
  end

  def load_show
    @allowlistable_triggers = ExternalApp.allowlistable_triggers.to_a
    # A trigger turned into a workflow trigger after it was allowlisted is still
    # listed, so the operator can see it and take it off.
    @allowlistable_triggers |= @external_app.triggers.to_a
    @api_keys = @external_app.api_keys.order(Arel.sql("revoked_at IS NOT NULL"), created_at: :desc).to_a
    @recent_sessions = @external_app.sessions.limit(10).to_a
  end

  # WARN, so it ships to obs, like ApiKeysController's audit lines.
  def log_lifecycle(verb, external_app, detail = nil)
    Rails.logger.warn(
      "[external_app] #{verb} #{external_app.name.inspect} (external_app_id=#{external_app.id})" \
      "#{" #{detail}" if detail} from the settings page, #{request.remote_ip}"
    )
  end
end

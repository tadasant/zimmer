# frozen_string_literal: true

# The Inference page over the REST API — the iOS app's route to what /inference
# shows and does, with the same rules (ClaudeAccountActions, AppSetting).
#
#   GET    /api/v1/inference                         the page: roster, pool, rotation log, policy (?runtime=)
#   POST   /api/v1/inference/accounts                add an account (runtime, email, priority, api_key)
#   POST   /api/v1/inference/accounts/:id/refresh    re-probe one account's quota
#   POST   /api/v1/inference/accounts/:id/activate   make it the current account
#   DELETE /api/v1/inference/accounts/:id            remove it (the current one hands over)
#   POST   /api/v1/inference/logins                  start the CLI login for an account (account_id)
#   GET    /api/v1/inference/logins/:id              poll it: status, verification URL, device code
#   POST   /api/v1/inference/logins/:id/code         paste the authorization code back (code)
#   POST   /api/v1/inference/logins/:id/cancel       stop it
#   PATCH  /api/v1/inference/spot_policy             the spot gate's six knobs
#   PATCH  /api/v1/inference/fleet_top_up            the backlog top-up's four
#   PATCH  /api/v1/inference/genesis/:genesis        reclassify a genesis kind (priority_class)
#   DELETE /api/v1/inference/genesis                 reset every kind to its default
#
# The read takes an API key. Every write takes only the iOS app's sign-in, on a
# grant that acts as its person — these are the operator's levers over which
# account the fleet runs on and how much work it does, and an agent must not
# reach them through the fleet's key. The web page is the other way in.
#
# The policy writes take the parameter names `action_spot_policy` takes and
# apply its validation; the account verbs share ClaudeAccountActions with the
# web controller. Every audit line the web writes — a rotation event's
# `triggered_by`, AppSetting's policy line — names the grant's email and the app.
class Api::V1::InferenceController < Api::BaseController
  accepts_native_app_tokens

  PERSON_ACTIONS = %i[
    create_account refresh_account activate_account destroy_account
    start_login submit_login_code cancel_login
    update_spot_policy update_fleet_top_up update_genesis_class reset_genesis_classes
  ].freeze

  before_action :require_a_person_on_the_app, only: PERSON_ACTIONS
  before_action :set_account, only: %i[refresh_account activate_account destroy_account]
  before_action :set_login_attempt, only: %i[login_status submit_login_code cancel_login]

  rescue_from ClaudeAccountActions::Refused do |error|
    render_api_error("Refused", error.message, status: :unprocessable_entity)
  end

  # GET /api/v1/inference
  # Converges a stale quota_exceeded column against the reading on file first, as
  # opening the page does — so the roster the phone shows is the pool that serves.
  def show
    report = InferenceReport.new(runtime: InferenceReport.normalize_runtime(params[:runtime]))
    ClaudeAccountActions.heal(report.runtime, report.snapshots, log_tag: "Api::V1::InferenceController") unless report.pi?

    render json: report.as_json
  end

  # POST /api/v1/inference/accounts
  def create_account
    runtime = InferenceReport.normalize_runtime(params[:runtime])
    account = ClaudeAccountActions.add!(runtime: runtime, email: params[:email],
      priority: params[:priority].presence || 0, api_key: params[:api_key])
    Rails.logger.info("[Api::V1::InferenceController] #{native_app_actor} added #{account.email} to the #{runtime} pool")

    render json: { account: account_json(account), message: added_message(account) }, status: :created
  end

  # POST /api/v1/inference/accounts/:id/refresh
  # The probe's failure, when it fails, rides on the card as `probe_error`.
  def refresh_account
    probe = ClaudeAccountActions.probe(@account, trigger: "manual_refresh")
    @account.reload
    heal_runtime(@account.runtime)

    render json: { account: account_json(@account, error: probe.error), pool: pool_json(@account.runtime) }
  end

  # POST /api/v1/inference/accounts/:id/activate
  def activate_account
    outcome = ClaudeAccountActions.switch!(@account, triggered_by: native_app_actor)
    Rails.logger.info("[Api::V1::InferenceController] #{native_app_actor}: #{outcome.message}")

    render json: { account: account_json(@account.reload), message: outcome.message }
  end

  # DELETE /api/v1/inference/accounts/:id
  def destroy_account
    outcome = ClaudeAccountActions.delete!(@account, triggered_by: native_app_actor)
    Rails.logger.info("[Api::V1::InferenceController] #{native_app_actor}: #{outcome.message}")

    render json: {
      message: outcome.message,
      current_account: outcome.current_account && account_json(outcome.current_account)
    }
  end

  # POST /api/v1/inference/logins
  # Starts the login CLI in the worker for `account_id`. The attempt's
  # verification URL and device code arrive on the poll, not here: the CLI has
  # not printed them yet.
  def start_login
    account = ClaudeAccount.find(params[:account_id])
    attempt = ClaudeAccountActions.start_login!(account)
    Rails.logger.info("[Api::V1::InferenceController] #{native_app_actor} started login attempt #{attempt.id} for #{account.email}")

    render json: { login: InferenceReport.login_attempt_json(attempt) }, status: :created
  end

  # GET /api/v1/inference/logins/:id
  # Drives an orphaned attempt terminal on the way, as the page's poll does, and
  # carries the account's card beside it so a succeeded login shows the account
  # it just authenticated.
  def login_status
    @attempt.fail_orphaned!

    render json: { login: InferenceReport.login_attempt_json(@attempt), account: account_json(@attempt.claude_account) }
  end

  # POST /api/v1/inference/logins/:id/code
  def submit_login_code
    code = params[:code].to_s.strip
    return render_api_error("Refused", "Paste the authorization code the page shows", status: :unprocessable_entity) if code.blank?
    if @attempt.terminal?
      return render_api_error("Refused", "This login has already finished (#{@attempt.status})", status: :unprocessable_entity)
    end

    @attempt.update!(pasted_code: code)
    render json: { login: InferenceReport.login_attempt_json(@attempt) }
  end

  # POST /api/v1/inference/logins/:id/cancel
  # A finished attempt is left as it finished; the answer is the same either way.
  def cancel_login
    @attempt.update!(status: "canceled", pasted_code: nil) unless @attempt.terminal?

    render json: { login: InferenceReport.login_attempt_json(@attempt) }
  end

  # PATCH /api/v1/inference/spot_policy
  # `enabled`, `five_hour_reserve_pct`, `weekly_reserve_pct`, `max_concurrent_sessions`,
  # `preemption_enabled`, `starvation_age_ceiling_hours` — any subset, at least one.
  def update_spot_policy
    setting = AppSetting.editable
    setting.policy_change_source = change_source("spot_policy")
    changed = []

    # `.nil?`, not truthiness: 0 is a meaningful reserve, and `false` is the whole
    # point of `preemption_enabled`.
    Mcp::Tools::ActionSpotPolicy::GATING_FIELDS.each do |arg, column|
      next if params[arg].nil?

      value = params[arg]
      value = ActiveModel::Type::Boolean.new.cast(value) if Mcp::Tools::ActionSpotPolicy::BOOLEAN_GATING_ARGS.include?(arg)
      setting.public_send(:"#{column}=", value)
      changed << arg
    end

    if changed.empty?
      return render_api_error("Nothing to change",
        "Pass #{Mcp::Tools::ActionSpotPolicy::GATING_FIELDS.keys.join(', ')}", status: :unprocessable_entity)
    end
    unless setting.save
      return render_api_error("Invalid spot policy", setting.errors.full_messages, status: :unprocessable_entity)
    end

    render json: { changed: changed, spot_policy: report.spot_policy_json }
  end

  # PATCH /api/v1/inference/fleet_top_up
  # `max_running_sessions`, `idle_minutes`, `min_fire_interval_minutes`,
  # `quiet_backlog_interval_minutes` — any subset, at least one.
  def update_fleet_top_up
    setting = AppSetting.editable
    setting.policy_change_source = change_source("fleet_top_up")
    changed = []

    Mcp::Tools::ActionSpotPolicy::TOP_UP_FIELDS.each do |arg, column|
      next if params[arg].nil?

      setting.public_send(:"#{column}=", params[arg])
      changed << arg
    end

    if changed.empty?
      return render_api_error("Nothing to change",
        "Pass #{Mcp::Tools::ActionSpotPolicy::TOP_UP_FIELDS.keys.join(', ')}", status: :unprocessable_entity)
    end
    unless setting.save
      return render_api_error("Invalid top-up policy", setting.errors.full_messages, status: :unprocessable_entity)
    end

    render json: { changed: changed, fleet_top_up: report.fleet_top_up_json }
  end

  # PATCH /api/v1/inference/genesis/:genesis  (priority_class: spot | priority)
  # The unit is the genesis, not the session: every session deriving its class
  # from that kind moves at once. The trigger-backed kinds are refused and point
  # at the trigger, as the page and `action_spot_policy` do.
  def update_genesis_class
    genesis = params[:genesis].to_s
    klass = params[:priority_class].to_s

    unless SessionGenesis.valid?(genesis)
      return render_api_error("Unknown genesis", "#{genesis.inspect} is not a genesis. Valid: #{SessionGenesis::SETTABLE_KEYS.join(', ')}",
        status: :unprocessable_entity)
    end
    unless SessionGenesis.settable?(genesis)
      return render_api_error("Refused",
        "#{SessionGenesis.label(genesis)} takes its class from the trigger that fires it. Set it on the trigger instead.",
        status: :unprocessable_entity)
    end
    unless SessionGenesis::CLASSES.include?(klass)
      return render_api_error("Unknown class", "priority_class must be one of #{SessionGenesis::CLASSES.join(', ')}",
        status: :unprocessable_entity)
    end

    setting = AppSetting.editable
    setting.policy_change_source = change_source("genesis #{genesis}")
    setting.set_genesis_class(genesis, klass)
    unless setting.save
      return render_api_error("Invalid genesis classes", setting.errors.full_messages, status: :unprocessable_entity)
    end

    affected = Session.genesis_count_for(genesis)
    render json: {
      message: "#{SessionGenesis.label(genesis)} is now #{klass}. #{affected} live #{'session'.pluralize(affected)} reclassified.",
      genesis_classes: report.genesis_classes_json
    }
  end

  # DELETE /api/v1/inference/genesis
  def reset_genesis_classes
    setting = AppSetting.editable
    setting.policy_change_source = change_source("genesis reset")
    setting.reset_genesis_classes
    unless setting.save
      return render_api_error("Invalid genesis classes", setting.errors.full_messages, status: :unprocessable_entity)
    end

    render json: { message: "Genesis classes reset to defaults.", genesis_classes: report.genesis_classes_json }
  end

  private

  def set_account
    @account = ClaudeAccount.find(params[:id])
  end

  # An attempt that is gone (pruned after its retention window) or detached (its
  # account was deleted mid-login) has nothing left to report. The page answers
  # its poller with a terminal "no longer tracked" panel; here that is a 404 the
  # phone stops polling on.
  def set_login_attempt
    @attempt = RuntimeLoginAttempt.find_by(id: params[:id])
    return unless @attempt.nil? || @attempt.detached?

    render_api_error("Not Found", "Login no longer tracked: the attempt was pruned or its account was deleted", status: :not_found)
  end

  # The surface AppSetting names on its audit line, with the person behind it.
  def change_source(what)
    "api:/api/v1/inference #{what} by #{native_app_actor}"
  end

  def report(runtime = ClaudeAuthProvider::RUNTIME)
    InferenceReport.new(runtime: runtime)
  end

  def account_json(account, error: nil)
    snapshot = account.latest_snapshot
    is_current = account == ClaudeAccount.current_account(account.runtime)
    InferenceReport.account_json(account, snapshot: snapshot, is_current: is_current, error: error)
  end

  def pool_json(runtime)
    report(runtime).pool_json
  end

  def heal_runtime(runtime)
    runtime_report = report(runtime)
    ClaudeAccountActions.heal(runtime, runtime_report.snapshots, log_tag: "Api::V1::InferenceController")
  end

  def added_message(account)
    account.has_valid_config? ? "Added #{account.email}." : "Added #{account.email}. Authenticate it to capture credentials."
  end
end

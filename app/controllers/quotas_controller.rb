# frozen_string_literal: true

class QuotasController < ApplicationController
  # Page load — renders immediately with cached snapshots from DB.
  # No API calls are made here.
  #
  # The runtime sub-tab (Claude Code / Codex) is selected via ?runtime=. Each
  # runtime keeps its own account pool, current account, and rotation history.
  def show
    # Auto-adopt filesystem identity changes (e.g., from `claude /login` on
    # the worker) so the DB stays in sync without requiring a session spawn
    # or an explicit Sync click. The provider hook is a no-op for runtimes
    # that don't support manual re-login reconciliation.
    RuntimeAuthProvider.for(current_runtime).reconcile_filesystem_identity!

    @accounts = ClaudeAccount.for_runtime(current_runtime).order(:priority)
    @current_account = ClaudeAccount.current_account(current_runtime)
    @snapshots = latest_snapshots_for(@accounts)
    @rotation_events = rotation_events_for(current_runtime)

    # The filesystem-sync banner is Claude-specific (it reads ~/.claude.json and
    # offers the rake-bootstrap path). Codex credentials are managed entirely
    # through the DB pool, so the banner is suppressed on that tab.
    @filesystem_email = current_runtime == ClaudeAuthProvider::RUNTIME ? ClaudeAccount.filesystem_oauth_email : nil
  end

  # POST: Refresh all accounts sequentially, streaming each card update.
  def refresh_all
    @accounts = ClaudeAccount.for_runtime(current_runtime).order(:priority)
    @current_account = ClaudeAccount.current_account(current_runtime)

    response.headers["Content-Type"] = "text/vnd.turbo-stream.html; charset=utf-8"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    self.response_body = Enumerator.new do |yielder|
      @accounts.each do |account|
        result = probe_account(account)
        snapshot = result&.success? ? QuotaSnapshotService.save_snapshot(account, result, trigger: "page_view") : account.latest_snapshot
        error = result&.success? ? nil : result&.error_message

        html = render_account_card(account, snapshot, error)
        yielder << turbo_stream.replace("account_card_#{account.id}", html: html)
      end

      # Update aggregate stats after all probes complete
      @snapshots = latest_snapshots_for(@accounts)
      auto_heal_accounts
      aggregate_html = render_to_string(partial: "quotas/aggregate_stats", formats: [ :html ], locals: {
        accounts: @accounts.reload, snapshots: @snapshots, current_account: @current_account
      })
      yielder << turbo_stream.replace("aggregate_stats", html: aggregate_html)
    end
  end

  # POST: Refresh a single account, returning a Turbo Stream update.
  def refresh_account
    account = ClaudeAccount.find(params[:id])
    @current_account = ClaudeAccount.current_account(account.runtime)
    @accounts = ClaudeAccount.for_runtime(account.runtime).order(:priority)

    result = probe_account(account)
    snapshot = result&.success? ? QuotaSnapshotService.save_snapshot(account, result, trigger: "page_view") : account.latest_snapshot
    error = result&.success? ? nil : result&.error_message

    @snapshots = latest_snapshots_for(@accounts)
    auto_heal_accounts

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("account_card_#{account.id}",
            html: render_account_card(account.reload, snapshot, error)),
          turbo_stream.replace("aggregate_stats",
            html: render_to_string(partial: "quotas/aggregate_stats", formats: [ :html ], locals: {
              accounts: @accounts.reload, snapshots: @snapshots, current_account: @current_account
            }))
        ]
      end
    end
  end

  # POST: Add an account to a runtime's pool. Creates the DB row (email +
  # priority); for Codex an optional api_key stores a ready-to-use OPENAI_API_KEY
  # credential. OAuth accounts are created empty here and authenticated via the
  # Authenticate flow (or rake capture_tokens) afterward.
  def add_account
    runtime = normalize_runtime(params[:runtime])
    email = params[:email].to_s.strip
    priority = params[:priority].present? ? params[:priority].to_i : 0
    api_key = params[:api_key].to_s.strip

    if email.blank?
      redirect_to quotas_path(runtime: runtime), alert: "Email is required to add an account."
      return
    end

    # Email uniqueness is per-runtime: only block if an account already exists
    # for this email IN THIS runtime's pool. The same email may hold a separate
    # account on another runtime (e.g. one codex + one claude_code account).
    existing = ClaudeAccount.for_runtime(runtime).find_by(email: email)
    if existing
      redirect_to quotas_path(runtime: runtime),
        alert: "An account for #{email} already exists in the #{RuntimeRegistry.label_for(runtime)} pool."
      return
    end

    account = ClaudeAccount.new(email: email, runtime: runtime, priority: priority)
    if runtime == CodexAuthProvider::RUNTIME && api_key.present?
      account.oauth_config = { "api_key" => api_key }
    end
    account.save!

    notice =
      if account.has_valid_config?
        "Added #{email}."
      else
        "Added #{email}. Authenticate it to capture credentials."
      end
    redirect_to quotas_path(runtime: runtime), notice: notice
  rescue ActiveRecord::RecordInvalid => e
    redirect_to quotas_path(runtime: runtime), alert: "Could not add account: #{e.record.errors.full_messages.to_sentence}"
  end

  # DELETE: Remove an account from its runtime's pool. When the deleted account
  # is the current one, activate the next available account in that runtime (or
  # leave the runtime with no current account if none remain). The worker's
  # before-spawn reconciliation backfills the filesystem from the DB.
  def destroy_account
    account = ClaudeAccount.find(params[:id])
    runtime = account.runtime
    email = account.email
    was_current = account.is_current?

    account.destroy!

    notice = "Deleted #{email}."
    if was_current
      next_account = next_activatable_account(runtime)
      if next_account
        RuntimeAuthProvider.for(runtime).activate!(next_account)
        AccountRotationEvent.create(
          rotated_from: nil,
          rotated_to: next_account,
          reason: "deleted_current_account",
          source: "manual"
        )
        notice = "Deleted #{email}. Activated #{next_account.email} as the current account."
      else
        notice = "Deleted #{email}. No other configured account remains — this runtime now has no active account."
      end
    end

    redirect_to quotas_path(runtime: runtime), notice: notice
  end

  def switch_account
    account = ClaudeAccount.find(params[:id])
    runtime = account.runtime

    ok, error = validate_switchable(account)
    unless ok
      redirect_to quotas_path(runtime: runtime), alert: error
      return
    end

    current = ClaudeAccount.current_account(runtime)

    # Route through the provider's activate! so manual switches take exactly the
    # same activation path as automatic rotations: write the runtime's credential
    # files, mark current in the DB, snapshot (Claude). Skipping the filesystem
    # write here would leave subsequent session spawns running under the previous
    # account's credentials until reconciliation kicked in.
    RuntimeAuthProvider.for(runtime).activate!(account)

    AccountRotationEvent.create(
      rotated_from: current,
      rotated_to: account,
      reason: "manual_switch",
      source: "manual"
    )

    redirect_to quotas_path(runtime: runtime), notice: "Switched to #{account.email}"
  end

  # POST: Read the worker's ~/.claude.json + .credentials.json and populate
  # the matching ClaudeAccount's oauth_config. Used after `claude /login`
  # on the worker to avoid the rake-task 3-step dance. Claude Code only.
  def sync_from_filesystem
    fs_email = ClaudeAccount.filesystem_oauth_email

    if fs_email.blank?
      redirect_to quotas_path, alert: "No OAuth tokens detected on the worker filesystem. Run `claude /login` on the worker first."
      return
    end

    account = ClaudeAccount.sync_from_filesystem!

    if account
      redirect_to quotas_path, notice: "Captured tokens for #{fs_email}#{account.is_current? ? " (marked current)" : ""}."
    else
      redirect_to quotas_path, alert: "Filesystem holds tokens for #{fs_email}, but no matching ClaudeAccount exists. Run `bin/rails 'claude_accounts:add[#{fs_email},0]'` first."
    end
  end

  # POST: Begin a UI-driven login for an OAuth account. Cancels any in-flight
  # attempt for the account, creates a fresh RuntimeLoginAttempt, and enqueues
  # RuntimeLoginJob (which holds the login CLI open in the worker). Renders the
  # login panel so the Stimulus poller can stream progress in.
  def start_login
    account = ClaudeAccount.find(params[:id])

    if account.codex? && account.codex_api_key_account?
      return render_login_panel(account, alert: "API-key accounts don't use the login flow.")
    end

    # Only one live attempt per account — supersede any existing one so we never
    # leave two login CLIs racing. The supersede-then-create runs under a row lock
    # on the account so two near-simultaneous Authenticate clicks can't each cancel
    # the other's not-yet-created row and both end up live.
    attempt = account.with_lock do
      account.runtime_login_attempts.active.update_all(status: "canceled", updated_at: Time.current)
      account.runtime_login_attempts.create!(runtime: account.runtime)
    end
    RuntimeLoginJob.perform_later(attempt.id)

    render_login_panel(account)
  end

  # GET: Poll an in-flight login. Returns a Turbo Stream — the whole account card
  # on success (so Switch becomes available), otherwise just the login panel.
  def login_status
    attempt = RuntimeLoginAttempt.find(params[:attempt_id])
    account = attempt.claude_account

    # Lazily expire a stale attempt so a closed browser tab doesn't leave it
    # "awaiting_user" forever.
    if !attempt.terminal? && attempt.expired_window?
      attempt.update!(status: "expired", error_message: "Login window expired.")
    end

    if attempt.succeeded?
      @current_account = ClaudeAccount.current_account(account.runtime)
      render turbo_stream: turbo_stream.replace(
        "account_card_#{account.id}",
        html: render_account_card(account, account.latest_snapshot, nil)
      )
    else
      render turbo_stream: turbo_stream.replace(
        "login_panel_#{account.id}",
        partial: "quotas/login_panel", locals: { account: account }
      )
    end
  end

  # POST: Hand the user's pasted authorization code (Claude) to the worker via
  # the attempt row. The job writes it to the held-open CLI's stdin.
  def submit_login_code
    attempt = RuntimeLoginAttempt.find(params[:attempt_id])
    code = params[:code].to_s.strip

    if code.present? && !attempt.terminal?
      attempt.update!(pasted_code: code)
    end

    render_login_panel(attempt.claude_account)
  end

  # POST: Cancel an in-flight login. The job sees the status change and stops the
  # CLI subprocess.
  def cancel_login
    attempt = RuntimeLoginAttempt.find(params[:attempt_id])
    attempt.update!(status: "canceled") unless attempt.terminal?

    render_login_panel(attempt.claude_account)
  end

  private

  # Renders the login panel Turbo Stream for an account, optionally flashing an
  # alert. Shared by the login actions so they all return a consistent response.
  def render_login_panel(account, alert: nil)
    flash.now[:alert] = alert if alert
    render turbo_stream: turbo_stream.replace(
      "login_panel_#{account.id}",
      partial: "quotas/login_panel", locals: { account: account }
    )
  end

  # The runtime selected by the ?runtime= param, validated against the known
  # runtimes. Defaults to Claude Code.
  def current_runtime
    @current_runtime ||= normalize_runtime(params[:runtime])
  end
  helper_method :current_runtime

  def normalize_runtime(value)
    ClaudeAccount::RUNTIMES.include?(value) ? value : ClaudeAuthProvider::RUNTIME
  end

  # Validate that an account can be made current. Returns [ok, error_message].
  # Codex API-key accounts authenticate statically — nothing to refresh. OAuth
  # accounts (both runtimes) must hold a refresh token that validates against the
  # vendor before we write potentially-revoked credentials to the filesystem.
  def validate_switchable(account)
    unless account.has_valid_config?
      return [ false, "Cannot switch to #{account.email} — no credentials stored. Authenticate the account first." ]
    end

    return [ true, nil ] if account.codex? && account.codex_api_key_account?

    unless account.can_refresh_token?
      return [ false, "Cannot switch to #{account.email} — no refresh token. Re-authenticate the account." ]
    end

    unless account.refresh_token!
      return [ false, "Cannot switch to #{account.email} — token validation failed. Re-authenticate the account." ]
    end

    [ true, nil ]
  end

  # The first available account in the runtime whose credentials validate, so a
  # safe-delete fallback never activates a bricked account. Codex API-key
  # accounts skip the refresh probe.
  def next_activatable_account(runtime)
    ClaudeAccount.available.for_runtime(runtime).find do |account|
      if account.codex? && account.codex_api_key_account?
        true
      else
        account.can_refresh_token? && account.refresh_token!
      end
    end
  end

  # Rotation events whose target account belongs to the given runtime. Rotation
  # history is shared across runtimes in one table, so filter to the current tab.
  # The runtime filter is applied in SQL *before* the limit so each runtime gets
  # its own most-recent slice — filtering after AccountRotationEvent.recent's
  # LIMIT 50 would let a busy runtime crowd the other off the page entirely.
  def rotation_events_for(runtime)
    AccountRotationEvent
      .where(rotated_to: ClaudeAccount.for_runtime(runtime))
      .order(created_at: :desc)
      .limit(50)
      .includes(:rotated_from, :rotated_to)
  end

  def probe_account(account)
    return nil unless account.can_refresh_token?

    if account.token_expired? || account.token_expiring_soon?
      account.refresh_token!
      account.reload
    end

    token = account.oauth_config&.dig("credentials_json", "claudeAiOauth", "accessToken")
    return nil unless token.present?

    result = QuotaCheckService.check_with_token(token)

    if !result.success? && result.error_message&.include?("401") && account.can_refresh_token?
      if account.refresh_token!
        account.reload
        token = account.oauth_config&.dig("credentials_json", "claudeAiOauth", "accessToken")
        result = QuotaCheckService.check_with_token(token) if token.present?
      end
    end

    result
  end

  def auto_heal_accounts
    ClaudeAccount.quota_exceeded.for_runtime(current_runtime).each do |account|
      snapshot = @snapshots[account.id]
      next unless snapshot
      account.update!(status: :active) if QuotaResetCheckerJob.window_clear?(snapshot)
    end
  end

  def render_account_card(account, snapshot, error)
    render_to_string(partial: "quotas/account_card", formats: [ :html ], locals: {
      account: account,
      snapshot: snapshot,
      error: error,
      is_current: account == @current_account
    })
  end

  def latest_snapshots_for(accounts)
    ClaudeAccountQuotaSnapshot
      .where(claude_account_id: accounts.pluck(:id))
      .select("DISTINCT ON (claude_account_id) *")
      .order(:claude_account_id, created_at: :desc)
      .index_by(&:claude_account_id)
  end
end

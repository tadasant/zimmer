# frozen_string_literal: true

class QuotasController < ApplicationController
  # Page load — renders immediately with cached snapshots from DB. No API calls
  # are made here; the one write it does make is #auto_heal_accounts converging a
  # status column against the reading already on file.
  #
  # The runtime sub-tab (Claude Code / Codex) is selected via ?runtime=. Each
  # runtime keeps its own account pool, current account, and rotation history.
  def show
    # Reads. The page has exactly two verbs for an account — Authenticate and
    # Switch — and nothing that asks an operator to reconcile, adopt or sync
    # between stores, because with the DB as sole owner there is no second store
    # to disagree with. See issue #618's acceptance criterion.
    @accounts = ClaudeAccount.for_runtime(current_runtime).order(:priority)
    @current_account = ClaudeAccount.current_account(current_runtime)
    @snapshots = latest_snapshots_for(@accounts)

    # Converge the sticky status column against the readings we are about to
    # render. The badges derive their own answer either way
    # (ClaudeAccount#effective_status), so this is not what keeps the page
    # honest — it is what keeps the POOL honest, because `available` and
    # AccountRotationService read the column and would otherwise go on refusing
    # an account whose card plainly says it has headroom. Costs one UPDATE per
    # account whose label had drifted, and nothing at all once they agree.
    #
    # QuotaResetCheckerJob does this on a 15-minute sweep from the same
    # predicate; opening the page is simply the other thing that can trigger it,
    # which matters precisely when the sweep is the thing that has stopped
    # running (#426).
    auto_heal_accounts

    @rotation_events = rotation_events_for(current_runtime)

    load_spot_gate if current_runtime == ClaudeAuthProvider::RUNTIME
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
      spot_gate_stream(yielder)
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
        streams = [
          turbo_stream.replace("account_card_#{account.id}",
            html: render_account_card(account.reload, snapshot, error)),
          turbo_stream.replace("aggregate_stats",
            html: render_to_string(partial: "quotas/aggregate_stats", formats: [ :html ], locals: {
              accounts: @accounts.reload, snapshots: @snapshots, current_account: @current_account
            }))
        ]
        spot_gate_stream(streams, runtime: account.runtime)
        render turbo_stream: streams
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
    # The status column defaults to :active (enum 0), but a freshly-added account
    # with no credentials yet isn't servable and shouldn't wear an "Active" badge
    # in the pool — it's excluded from the `available` serve pool anyway (that
    # scope requires a non-empty oauth_config). Seed it as :needs_reauth so the UI
    # honestly reads "needs authentication" until capture! flips it to :active.
    account.status = :needs_reauth unless account.has_valid_config?
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
  #
  # The account row goes; its history does not. Quota snapshots, login attempts,
  # and rotation events are nullified rather than destroyed, and each carries the
  # account's email — see ClaudeAccount's associations.
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
        # The source account is already gone, so it can only be named by the
        # email preserved on the event — which is what tells the rotation table
        # this move came from a deleted account rather than from nowhere.
        AccountRotationEvent.create(
          rotated_from: nil,
          rotated_from_email: email,
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

    # Re-activating the account that is already current is a repair, not a
    # rotation: it rewrites the live credential files from the DB copy. Recording
    # it as a rotation from an account to itself would put a meaningless row in
    # the history operators read to understand rotations.
    reactivation = current&.id == account.id

    unless reactivation
      AccountRotationEvent.create(
        rotated_from: current,
        rotated_to: account,
        reason: "manual_switch",
        source: "manual"
      )
    end

    notice = reactivation ? "Re-activated #{account.email} — its credentials were rewritten to the worker." : "Switched to #{account.email}"
    redirect_to quotas_path(runtime: runtime), notice: notice
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
      account.runtime_login_attempts.active.update_all(
        status: "canceled", pasted_code: nil, updated_at: Time.current
      )
      account.runtime_login_attempts.create!(runtime: account.runtime)
    end
    RuntimeLoginJob.perform_later(attempt.id)

    render_login_panel(account)
  end

  # GET: Poll an in-flight login. Returns a Turbo Stream — the whole account card
  # on success (so Switch becomes available), otherwise just the login panel.
  def login_status
    attempt = RuntimeLoginAttempt.find_by(id: params[:attempt_id])

    # The row is gone (pruned after its retention window), or its account was
    # deleted mid-login and the row was detached to preserve the history. Either
    # way there is no panel left to repaint. Raising RecordNotFound here would
    # 404 the poller, which counts it as a transient network error and silently
    # gives up a few ticks later, freezing the panel on whatever it last
    # rendered. Answer with a terminal panel instead so the user is told what
    # happened.
    return render_lost_attempt(params[:attempt_id]) if attempt.nil? || attempt.detached?

    account = attempt.claude_account

    # Lazily drive an orphaned attempt terminal so the panel resolves on the very
    # next poll rather than waiting on CleanupRuntimeLoginAttemptsJob's 5-minute
    # cron. Covers both an elapsed verification window (a closed browser tab that
    # never came back) and a worker that died mid-login without running Ruby, in
    # which case nothing else will ever touch this row.
    attempt.fail_orphaned!

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

    return render_lost_attempt(attempt.id) if attempt.detached?

    if code.present? && !attempt.terminal?
      attempt.update!(pasted_code: code)
    end

    render_login_panel(attempt.claude_account)
  end

  # POST: Cancel an in-flight login. The job sees the status change and stops the
  # CLI subprocess. The pasted authorization code is dropped here rather than left
  # for the job to clear: the job may not be running at all, which is the whole
  # premise of the orphan handling above.
  def cancel_login
    attempt = RuntimeLoginAttempt.find(params[:attempt_id])
    # Guard before the write: a detached attempt has already been resolved by
    # RuntimeLoginJob with the reason its account was deleted, and overwriting
    # that with a bare "canceled" would lose the only explanation of what happened.
    return render_lost_attempt(attempt.id) if attempt.detached?

    attempt.update!(status: "canceled", pasted_code: nil) unless attempt.terminal?

    render_login_panel(attempt.claude_account)
  end

  private

  # The spot gate card: the policy, the reading it acts on, and the per-genesis
  # classes. It reads the same Claude Code quota windows the rest of this page
  # reports, which is why it renders here and only on the Claude tab.
  #
  # One decision. `SpotGateService.evaluate` is the whole answer, and
  # `get_spot_policy` renders the same call, so the page and the tool cannot
  # disagree about whether a spot session would start.
  def load_spot_gate
    @app_setting = AppSetting.current
    @spot_decision = SpotGateService.evaluate
    # Running spot sessions the ceiling has stopped. The decision above says what
    # would happen to a session STARTING now; this says what already happened to
    # the ones that were in flight when a window arrived at its target.
    @spot_paused_count = SpotSessionPause.paused_count
    @genesis_classes = SessionGenesis.effective_classes(@app_setting.genesis_class_overrides)
    @genesis_counts = Session.genesis_counts
  end

  # Append a re-rendered spot gate to a refresh response. The card's decision is
  # read from the very snapshots a refresh has just replaced, so without this a
  # refreshed page would show new utilization bars beside a decision taken before
  # them. Takes whatever collects the streams — the enumerator's yielder for the
  # streaming refresh, an array for the single-account one.
  def spot_gate_stream(sink, runtime: current_runtime)
    return unless runtime == ClaudeAuthProvider::RUNTIME

    load_spot_gate
    sink << turbo_stream.replace("spot-gate",
      html: render_to_string(partial: "quotas/spot_gate", formats: [ :html ]))
  end

  # Answer a poll for an attempt row that no longer exists, or whose account was
  # deleted out from under it. We can't name the account either way, so target
  # the login-attempt element the poller itself lives on. The replacement carries
  # no Stimulus controller, so polling stops — with a message on screen instead
  # of a frozen spinner.
  def render_lost_attempt(attempt_id)
    render turbo_stream: turbo_stream.replace(
      "login_attempt_#{attempt_id.to_i}",
      partial: "quotas/login_attempt_lost"
    )
  end

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

    # A stored access token Anthropic still honours is the direct answer to the
    # question this method is actually asking — can this account serve a session
    # — and unlike #refresh_token! it does not spend the single-use refresh
    # token to find out. Gating admission on a refresh ROUND TRIP is what let the
    # failure block its own repair: an account freshly authenticated through the
    # UI holds a working access token and an unused refresh token, and demanding
    # a refresh here burned the latter to learn nothing about the former.
    #
    # Sits AFTER the refresh-token existence check on purpose. A pair with no
    # refresh token is a dead end even while its access token works — in eight
    # hours nothing can mint another — so "it works right now" must not admit it.
    # See issue #618, hole 4.
    return [ true, nil ] if account.access_token_honored?

    unless account.refresh_token!
      # A rejection Zimmer could not attribute to a dead credential leaves the
      # account active on purpose (#530), so telling the human to re-authenticate
      # would be telling them to fix something that is probably not broken.
      if account.reload.needs_reauth?
        return [ false, "Cannot switch to #{account.email} — token validation failed. Re-authenticate the account." ]
      end

      return [ false, "Cannot switch to #{account.email} — its stored token was rejected as out of date. Try again shortly, or re-authenticate if it keeps failing." ]
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

  # Rotation events belonging to the given runtime. Rotation history is shared
  # across runtimes in one table, so filter to the current tab. The runtime
  # filter is applied in SQL *before* the limit so each runtime gets its own
  # most-recent slice — filtering after AccountRotationEvent.recent's LIMIT 50
  # would let a busy runtime crowd the other off the page entirely.
  #
  # The filter reads the event's own `runtime` column rather than joining to the
  # target account, so an event whose accounts have since been deleted still
  # appears on the page it exists to inform.
  def rotation_events_for(runtime)
    AccountRotationEvent
      .for_runtime(runtime)
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

    token = account.claude_access_token
    return nil unless token.present?

    result = QuotaCheckService.check_with_token(token)

    if !result.success? && result.error_message&.include?("401") && account.can_refresh_token?
      if account.refresh_token!
        account.reload
        token = account.claude_access_token
        result = QuotaCheckService.check_with_token(token) if token.present?
      end
    end

    result
  end

  # Converge the status column of every account whose latest reading says its
  # windows have cleared. Same predicate QuotaResetCheckerJob restores on, logged
  # the same way: a status flipping without a line saying which reading did it is
  # not something anyone can reconstruct afterwards, and this path now runs on a
  # page view rather than only on an explicit refresh.
  #
  # A healing failure must never take the page with it. /quotas is where a human
  # goes to fix an auth problem, and a row that fails validation for some reason
  # of its own is not a reason to deny them the page.
  def auto_heal_accounts
    ClaudeAccount.quota_exceeded.for_runtime(current_runtime).each do |account|
      snapshot = @snapshots[account.id]
      next unless snapshot
      next unless snapshot.windows_clear?

      account.update!(status: :active)
      Rails.logger.info "[QuotasController] Restored #{account.email} to active: both windows are clear " \
        "(5h #{snapshot.utilization_5h.inspect}/#{snapshot.status_5h.inspect}, " \
        "7d #{snapshot.utilization_7d.inspect}/#{snapshot.status_7d.inspect}, " \
        "reading taken #{snapshot.created_at&.iso8601})"
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn "[QuotasController] Could not restore #{account.email} to active: #{e.message}"
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

  # One query for the readings the page renders and the pool figure averages.
  # The definition lives on ClaudeAccountPool because the spot gate loads the
  # same set when it evaluates away from a page render.
  def latest_snapshots_for(accounts)
    ClaudeAccountPool.latest_snapshots(accounts)
  end
end

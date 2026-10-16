# frozen_string_literal: true

class InferenceController < ApplicationController
  # The tabs, in order. Every registered runtime gets one — including the ones
  # with no account pool. The surface was called Quotas while every tab was a
  # pool of subscription accounts with a quota window; Pi has neither, which is
  # why the page is now Inference and the tab list is RuntimeRegistry's rather
  # than ClaudeAccount::RUNTIMES.
  TABS = RuntimeRegistry::BUNDLES.keys.freeze

  # Page load — renders immediately with cached snapshots from DB. No API calls
  # are made here; the one write it does make is #auto_heal_accounts converging a
  # status column against the reading already on file.
  #
  # The runtime sub-tab (Claude Code / Codex) is selected via ?runtime=. Each
  # runtime keeps its own account pool, current account, and rotation history.
  def show
    # Pi pools no accounts — it resolves a provider credential per request — so
    # its tab manages that credential instead, and none of the pool machinery
    # below has anything to render for it.
    return show_pi if current_runtime == PiAuthProvider::RUNTIME

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

    # Read on every tab, not just the Claude one: the Account Pool section
    # renders the dollar capacity model from it, and that section is above the
    # spot gate card `load_spot_gate` sets up.
    @app_setting = AppSetting.current

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
        probe = ClaudeAccountActions.probe(account, trigger: "page_view")

        html = render_account_card(account, probe.snapshot, probe.error)
        yielder << turbo_stream.replace("account_card_#{account.id}", html: html)
      end

      # Update aggregate stats after all probes complete
      @snapshots = latest_snapshots_for(@accounts)
      auto_heal_accounts
      aggregate_html = render_to_string(partial: "inference/aggregate_stats", formats: [ :html ], locals: {
        accounts: @accounts.reload, snapshots: @snapshots, current_account: @current_account,
        setting: AppSetting.current
      })
      yielder << turbo_stream.replace("aggregate_stats", html: aggregate_html)
      pool_alert_stream(yielder)
      spot_gate_stream(yielder)
    end
  end

  # POST: Refresh a single account, returning a Turbo Stream update.
  def refresh_account
    account = ClaudeAccount.find(params[:id])
    @current_account = ClaudeAccount.current_account(account.runtime)
    @accounts = ClaudeAccount.for_runtime(account.runtime).order(:priority)

    probe = ClaudeAccountActions.probe(account, trigger: "page_view")

    @snapshots = latest_snapshots_for(@accounts)
    auto_heal_accounts

    respond_to do |format|
      format.turbo_stream do
        streams = [
          turbo_stream.replace("account_card_#{account.id}",
            html: render_account_card(account.reload, probe.snapshot, probe.error)),
          turbo_stream.replace("aggregate_stats",
            html: render_to_string(partial: "inference/aggregate_stats", formats: [ :html ], locals: {
              accounts: @accounts.reload, snapshots: @snapshots, current_account: @current_account,
              setting: AppSetting.current
            }))
        ]
        pool_alert_stream(streams, runtime: account.runtime)
        spot_gate_stream(streams, runtime: account.runtime)
        render turbo_stream: streams
      end
    end
  end

  # POST: Add an account to a runtime's pool. Creates the DB row (email +
  # priority); for Codex an optional api_key stores a ready-to-use OPENAI_API_KEY
  # credential. OAuth accounts are created empty here and authenticated via the
  # Authenticate flow afterward. The rules live on ClaudeAccountActions, shared
  # with the REST API.
  def add_account
    runtime = normalize_runtime(params[:runtime])
    account = ClaudeAccountActions.add!(runtime: runtime, email: params[:email],
      priority: params[:priority].presence || 0, api_key: params[:api_key])

    notice =
      if account.has_valid_config?
        "Added #{account.email}."
      else
        "Added #{account.email}. Authenticate it to capture credentials."
      end
    redirect_to inference_path(runtime: runtime), notice: notice
  rescue ClaudeAccountActions::Refused => e
    redirect_to inference_path(runtime: runtime), alert: e.message
  end

  # DELETE: Remove an account from its runtime's pool. Deleting the current one
  # activates the next available account, or leaves the runtime with none — see
  # ClaudeAccountActions.delete!.
  def destroy_account
    account = ClaudeAccount.find(params[:id])
    runtime = account.runtime

    outcome = ClaudeAccountActions.delete!(account)

    redirect_to inference_path(runtime: runtime), notice: outcome.message
  end

  # POST: Make an account the runtime's current one. The admission rules and
  # the rotation event live on ClaudeAccountActions, shared with the REST API.
  def switch_account
    account = ClaudeAccount.find(params[:id])
    runtime = account.runtime

    outcome = ClaudeAccountActions.switch!(account)
    redirect_to inference_path(runtime: runtime), notice: outcome.message
  rescue ClaudeAccountActions::Refused => e
    redirect_to inference_path(runtime: runtime), alert: e.message
  end

  # POST: Begin a UI-driven login for an OAuth account (ClaudeAccountActions
  # .start_login! supersedes any in-flight attempt and enqueues RuntimeLoginJob).
  # Renders the login panel so the Stimulus poller can stream progress in.
  def start_login
    account = ClaudeAccount.find(params[:id])

    ClaudeAccountActions.start_login!(account)
    render_login_panel(account)
  rescue ClaudeAccountActions::Refused => e
    render_login_panel(account, alert: e.message)
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
        partial: "inference/login_panel", locals: { account: account }
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

  # PUT: Create or rotate Pi's OpenRouter key in the Parameter Store.
  #
  # The value is read from params, handed to ManagedSecret, and never touched
  # again — not echoed into the flash, not logged (`_key` is already in
  # `config.filter_parameters`, and a test pins that), not returned in the
  # response. What comes back is a fingerprint at most.
  def update_openrouter_key
    result = ManagedSecret.openrouter_key.write(params[:openrouter_api_key].to_s)

    redirect_to inference_path(runtime: PiAuthProvider::RUNTIME),
      **flash_for(result)
  end

  # DELETE: Remove the key from the store.
  def destroy_openrouter_key
    result = ManagedSecret.openrouter_key.delete

    redirect_to inference_path(runtime: PiAuthProvider::RUNTIME),
      **flash_for(result)
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
    @app_setting ||= AppSetting.current
    @spot_decision = SpotGateService.evaluate
    # The standing population of sessions the `spot_budget` ceiling stopped and
    # has not yet put back. The decision above says what would happen to a
    # session STARTING now; this says how many are already asleep. They are
    # dormant in `waiting`, so this number is unrelated to the concurrency limit
    # and is routinely larger than it — see SpotSessionPause.paused_count.
    @spot_paused_count = SpotSessionPause.paused_count
    # The OTHER dormant population: sessions the gate refused before a turn and
    # has not yet let through. Disjoint from the paused one above and resumed by a
    # different mechanism (their own re-check, not the ceiling sweep), so the card
    # prints both rather than one under a label that reads like both.
    @spot_held_count = SpotSessionHold.held_count
    # How many of those ladders have stalled — a hold whose own re-check time has
    # passed is waiting on nothing until SpotHoldSweepJob puts it back.
    @spot_overdue_hold_count = SpotSessionHold.overdue_count
    # The THIRD dormant population: spot sessions a priority session took the
    # slot of. It shares the paused queue and its resume owner, so it is not a
    # separate mechanism — but it is a separate CAUSE, and printing it inside
    # `@spot_paused_count` would report the concurrency limit's cost under the
    # budget ceiling's label.
    @spot_preempted_count = SpotSessionPause.preempted_count
    # The starvation lane: how many held sessions are past the age ceiling, how
    # old the oldest wait is, and which session (if any) the lane is running.
    # One reading, shared with `get_spot_policy`.
    @spot_starvation = SpotHoldExplanation::Starvation.read(setting: @app_setting)
    # Which of the three ceilings is holding spot work and what lifts it, in the
    # words `get_spot_policy` uses for the same decision.
    @spot_hold_explanation = SpotHoldExplanation.new(
      @spot_decision,
      paused_count: @spot_paused_count,
      held_count: @spot_held_count,
      overdue_hold_count: @spot_overdue_hold_count,
      preempted_count: @spot_preempted_count,
      starvation: @spot_starvation
    )
    # The capacity model behind the reserve controls: the form types a
    # percentage and prints the dollars that percentage carves out, and both
    # come from the same object the decision above was taken on.
    @spot_windows = QuotaCapacityModel.windows(measure: ClaudeAccountPool.measure, setting: @app_setting)
    @genesis_classes = SessionGenesis.effective_classes(@app_setting.genesis_class_overrides)
    @genesis_counts = Session.genesis_counts
    # The backlog top-up card below the gate: the three numbers
    # `no_sessions_in_progress` fires on, and where the fleet sits against them.
    # One reading, shared with `get_spot_policy`, so the page and the tool cannot
    # disagree about whether a top-up is due.
    @fleet_top_up = FleetTopUpStatus.current(setting: @app_setting)
  end

  # Append a re-rendered dry-pool banner to a refresh response. A refresh is
  # precisely when the pool's answer to "can anything serve a session" changes —
  # it is the probe that discovers a refused token — so leaving the banner behind
  # would leave the page's loudest element describing the pool as it was before
  # the button was pressed.
  def pool_alert_stream(sink, runtime: current_runtime)
    sink << turbo_stream.replace("pool_alert",
      html: render_to_string(partial: "inference/pool_alert", formats: [ :html ], locals: {
        runtime: runtime, accounts: @accounts.reload, snapshots: @snapshots
      }))
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
      html: render_to_string(partial: "inference/spot_gate", formats: [ :html ]))
  end

  # Answer a poll for an attempt row that no longer exists, or whose account was
  # deleted out from under it. We can't name the account either way, so target
  # the login-attempt element the poller itself lives on. The replacement carries
  # no Stimulus controller, so polling stops — with a message on screen instead
  # of a frozen spinner.
  def render_lost_attempt(attempt_id)
    render turbo_stream: turbo_stream.replace(
      "login_attempt_#{attempt_id.to_i}",
      partial: "inference/login_attempt_lost"
    )
  end

  # Renders the login panel Turbo Stream for an account, optionally flashing an
  # alert. Shared by the login actions so they all return a consistent response.
  def render_login_panel(account, alert: nil)
    flash.now[:alert] = alert if alert
    render turbo_stream: turbo_stream.replace(
      "login_panel_#{account.id}",
      partial: "inference/login_panel", locals: { account: account }
    )
  end

  # The runtime selected by the ?runtime= param, validated against the known
  # runtimes. Defaults to Claude Code.
  def current_runtime
    @current_runtime ||= normalize_runtime(params[:runtime])
  end
  helper_method :current_runtime

  def normalize_runtime(value)
    TABS.include?(value) ? value : ClaudeAuthProvider::RUNTIME
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

  # Converge the status column of every account whose latest reading says its
  # windows have cleared — ClaudeAccountActions.heal, which QuotaResetCheckerJob's
  # 15-minute sweep applies from the same predicate. The page view is simply the
  # other thing that can trigger it, which matters precisely when the sweep is
  # the thing that has stopped running (#426).
  def auto_heal_accounts
    ClaudeAccountActions.heal(current_runtime, @snapshots, log_tag: "InferenceController")
  end

  def render_account_card(account, snapshot, error)
    render_to_string(partial: "inference/account_card", formats: [ :html ], locals: {
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

  # The Pi tab. One object, carrying no secret value — see ManagedSecret.
  def show_pi
    @openrouter_status = ManagedSecret.openrouter_key.status
    render :show
  end

  # A Result's two sentences, as a redirect flash. The detail is a second
  # sentence rather than a second flash so a partial success — written, but not
  # readable — reads as one event.
  def flash_for(result)
    message = [ result.message, result.detail ].compact.join(" ")

    result.ok? ? { notice: message } : { alert: message }
  end
end

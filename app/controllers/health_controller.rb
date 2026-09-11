# frozen_string_literal: true

# Controller for the health check dashboard
#
# Provides system health monitoring, diagnostics, and cleanup actions.
# All actions require user interaction for safety (no automated cleanup).
class HealthController < ApplicationController
  include OperatorHttpBasicAuth

  # Maximum days for archive operation (security bound)
  MAX_ARCHIVE_DAYS = 365
  # Minimum days for archive operation
  MIN_ARCHIVE_DAYS = 1

  # The mutating actions, behind the operator credential (#312, #371).
  #
  # Until this gate, `/health` was the one surface reaching HealthMonitorService that asked
  # for nothing at all: `Api::V1::HealthController` requires an API key and the MCP
  # `action_health` tool requires the `health` tool group, while these POSTs were anonymous.
  # The perimeter argument that covers the rest of the web UI does not reach them, because
  # **the caller they most need to exclude is already inside the perimeter**: agent sessions
  # run on the production host, and a session's shell can reach this app (measured — a GET
  # of `/health` from inside a session answers 200). So an ordinary session could halt the
  # fleet's demand-side queues with a `curl`, which is exactly what the `health` tool group
  # exists to prevent.
  #
  # What is gated is every action that *changes* something, and nothing else. Three things
  # stay deliberately open, and each would be a worse outcome to close than to leave:
  #
  # - **Every GET.** `#dashboard`, `#refresh` and `#export_diagnostics` are read-only, and a
  #   read-only dashboard behind the network perimeter is the documented design
  #   (limitations.md, "The web UI has no login, by design"). `#deep` and Rails' `/up` are
  #   the health checks kamal-proxy gates the deploy cutover on; a 401 there would fail
  #   every deploy.
  # - **`#exit_queue_recovery_mode`.** The way out of a halt must always be available — the
  #   action's own note already says so, which is why it is not rate-limited either. Its
  #   blast radius is resuming normal processing, and this realm fails closed: on a
  #   deployment that has not set SUPERVISOR_PASSWORD, gating it would mean an operator who
  #   entered recovery mode could not leave it from the UI.
  # - **`SystemHealthMonitorJob`** and the other in-process callers, which reach
  #   HealthMonitorService directly and never traverse a route.
  OPERATOR_GATED_ACTIONS = %i[
    cleanup_processes
    retry_sessions
    archive_old
    enter_queue_recovery_mode
    run_post_deploy_tasks
    discard_queued_jobs
    reschedule_queued_jobs
  ].freeze

  before_action :authenticate_operator, only: OPERATOR_GATED_ACTIONS

  def dashboard
    @health_service = HealthMonitorService.new
    @health_report = @health_service.full_health_report
  end

  # GET /up/deep
  #
  # The strict sibling of `/up`. `/up` answers 200 for a process that booted;
  # this answers 200 only when the database, the cache, and Redis each responded
  # to a real round trip, and 503 naming the one that did not. DeepHealthCheck
  # carries the reasoning, including why this is deliberately not behind the
  # HealthActionCooldown that guards the maintenance actions below.
  def deep
    report = DeepHealthCheck.new.call

    render json: report, status: report[:status] == "ok" ? :ok : :service_unavailable
  end

  def refresh
    @health_service = HealthMonitorService.new
    @health_report = @health_service.full_health_report

    respond_to do |format|
      format.html { render partial: "health_content", locals: { health_report: @health_report } }
      format.json { render json: @health_report }
    end
  end

  def cleanup_processes
    return render_rate_limited if rate_limited?(:cleanup_processes)

    @health_service = HealthMonitorService.new
    results = @health_service.cleanup_orphaned_processes

    record_action(:cleanup_processes)

    respond_to do |format|
      format.html do
        if results[:terminated].any? || results[:already_dead].any?
          flash[:notice] = "Cleanup complete: #{results[:terminated].size} terminated, #{results[:already_dead].size} already dead"
        elsif results[:failed].any?
          flash[:alert] = "Cleanup partially failed: #{results[:failed].size} processes could not be terminated"
        else
          flash[:notice] = "No orphaned processes to clean up"
        end
        redirect_to health_dashboard_path
      end
      format.json { render json: results }
    end
  end

  # POST /health/run_post_deploy_tasks
  #
  # Re-arm any failed one-time post-deploy task and kick a pass. The mechanism
  # runs itself after every deploy; this is the surface for the case it cannot
  # handle on its own — a task that failed for a reason somebody has now fixed —
  # so that unsticking it does not need a shell on the box.
  #
  # Not behind HealthActionCooldown: it terminates nothing and rewrites nothing
  # in bulk, and the way to restart a stuck rollout should work first time.
  def run_post_deploy_tasks
    result = PostDeployTask::Runner.request!

    respond_to do |format|
      format.html do
        flash[:notice] = if result[:rearmed].positive?
          "Re-armed #{result[:rearmed]} post-deploy task#{'s' unless result[:rearmed] == 1} and queued a run"
        else
          "Queued a post-deploy task run"
        end
        redirect_to health_dashboard_path
      end
      format.json { render json: result }
    end
  end

  def retry_sessions
    return render_rate_limited if rate_limited?(:retry_sessions)

    session_ids = params[:session_ids]&.map(&:to_i)

    @health_service = HealthMonitorService.new
    results = @health_service.retry_failed_sessions(session_ids: session_ids)

    record_action(:retry_sessions)

    respond_to do |format|
      format.html do
        flash_for_retry(results)
        redirect_to health_dashboard_path
      end
      format.json { render json: results }
    end
  end

  def archive_old
    return render_rate_limited if rate_limited?(:archive_old)

    # Validate days parameter with bounds checking
    days = (params[:days] || 7).to_i
    days = days.clamp(MIN_ARCHIVE_DAYS, MAX_ARCHIVE_DAYS)
    older_than = days.days

    @health_service = HealthMonitorService.new
    results = @health_service.archive_old_sessions(older_than: older_than)

    record_action(:archive_old)

    respond_to do |format|
      format.html do
        if results[:archived].any?
          flash[:notice] = "Moved #{results[:archived].size} old session(s) to trash"
        elsif results[:failed].any?
          flash[:alert] = "Failed to trash #{results[:failed].size} session(s)"
        else
          flash[:notice] = "No old sessions to trash"
        end
        redirect_to health_dashboard_path
      end
      format.json { render json: results }
    end
  end

  # POST /health/enter_queue_recovery_mode
  #
  # Halts the demand-side job queues so the cause of a backlog can be
  # investigated. See QueueRecoveryMode — in particular, this does NOT halt
  # `agents`, so sessions can still be started and can still run.
  #
  # Deliberately NOT behind HealthActionCooldown. The cooldown exists to throttle
  # bulk mutations (terminating processes, rewriting session rows); this writes two
  # rows. More importantly, its partner action must work on the first try during an
  # incident, and a cooldown that fails closed when the cache is down — which is a
  # plausible symptom of the very overload being recovered from — would be a lock
  # on the escape hatch.
  def enter_queue_recovery_mode
    status = QueueRecoveryMode.enter!(
      reason: params[:reason],
      ttl: recovery_mode_ttl,
      actor: "web UI"
    )

    respond_to do |format|
      format.html do
        flash[:notice] = "Queue recovery mode ON — #{QueueRecoveryMode::HALTED_QUEUES.join(", ")} halted, " \
          "auto-resuming at #{status.expires_at&.strftime("%H:%M UTC")}."
        redirect_to health_dashboard_path
      end
      format.json { render json: status.as_json }
    end
  rescue QueueRecoveryMode::NotAvailable => e
    respond_to do |format|
      format.html do
        flash[:alert] = e.message
        redirect_to health_dashboard_path
      end
      format.json { render json: { error: "Queue recovery mode unavailable", message: e.message }, status: :service_unavailable }
    end
  end

  # POST /health/exit_queue_recovery_mode
  #
  # Resumes normal processing. Idempotent, and never rate-limited or gated: the
  # way out of a halt must always be available.
  def exit_queue_recovery_mode
    status = QueueRecoveryMode.exit!(actor: "web UI")

    respond_to do |format|
      format.html do
        flash[:notice] = "Queue recovery mode OFF — background job processing resumed."
        redirect_to health_dashboard_path
      end
      format.json { render json: status.as_json }
    end
  end

  # POST /health/discard_queued_jobs
  #
  # The third cleanup lever for a runaway queue, on the surface a human reaches
  # for during an incident, so they are not sent to GoodJob's own dashboard
  # mid-incident (#335). NOT RECOVERABLE — see QueuedJobMaintenance.
  #
  # Gated by OPERATOR_GATED_ACTIONS above. That is the load-bearing half of #312:
  # the destructive `/health` actions used to be anonymous while their REST and
  # MCP siblings required a key, and an agent session's shell can reach this app.
  # A bulk discard must not be a `curl` away.
  #
  # `expected_count` comes from the hidden field the panel renders beside each
  # row, which is the count confirmation doing real work rather than ceremony: a
  # page rendered ten minutes ago names a count that no longer matches, and the
  # click is refused instead of discarding a set the operator never saw.
  def discard_queued_jobs
    result = QueuedJobMaintenance.discard!(
      job_class: params[:job_class],
      queue_name: params[:queue_name],
      expected_count: params[:expected_count],
      reason: params[:reason],
      actor: "web UI"
    )

    respond_to do |format|
      format.html do
        flash[:notice] = "Discarded #{result.affected} queued job#{'s' unless result.affected == 1} " \
          "(#{queued_job_breakdown(result)}). Not recoverable."
        redirect_to health_dashboard_path
      end
      format.json { render json: result.as_json }
    end
  rescue QueuedJobMaintenance::Refused => e
    render_maintenance_refusal(e)
  end

  # POST /health/reschedule_queued_jobs
  #
  # The reversible sibling. Same gate, same count confirmation.
  def reschedule_queued_jobs
    result = QueuedJobMaintenance.reschedule!(
      job_class: params[:job_class],
      queue_name: params[:queue_name],
      expected_count: params[:expected_count],
      scheduled_at: params[:delay_minutes].presence&.to_i&.minutes&.from_now,
      actor: "web UI"
    )

    respond_to do |format|
      format.html do
        flash[:notice] = "Rescheduled #{result.affected} queued job#{'s' unless result.affected == 1} " \
          "(#{queued_job_breakdown(result)}) to #{result.scheduled_at&.utc&.strftime("%H:%M UTC")}."
        redirect_to health_dashboard_path
      end
      format.json { render json: result.as_json }
    end
  rescue QueuedJobMaintenance::Refused => e
    render_maintenance_refusal(e)
  end

  def export_diagnostics
    @health_service = HealthMonitorService.new
    @health_report = @health_service.full_health_report

    respond_to do |format|
      format.json do
        render json: {
          health_report: @health_report,
          exported_at: Time.current,
          rails_env: Rails.env,
          ruby_version: RUBY_VERSION
        }
      end
    end
  end

  private

  # Report every bucket of a retry, not just the two that used to be flashed.
  #
  # `skipped` carries a reason per session — a missing working directory, or a
  # recovery turn `Session#claim_system_recovery_turn!` refused because the row is
  # in the trash, already running, or superseded by the session that replaced it.
  # Flashing counts and dropping that list left
  # the dashboard saying "No sessions to retry" to an operator who had just asked
  # for one specific session by id, which is indistinguishable from a bug. The
  # JSON surfaces have always returned the whole hash; this is the HTML one
  # catching up.
  #
  # @param results [Hash] from HealthMonitorService#retry_failed_sessions
  def flash_for_retry(results)
    parts = []
    parts << "Retry initiated for #{results[:retried].size} session(s)" if results[:retried].any?
    parts << "Failed to retry #{results[:failed].size} session(s)" if results[:failed].any?
    if results[:skipped].any?
      reasons = results[:skipped].map { |entry| entry[:reason] }.uniq.join(" ")
      parts << "Skipped #{results[:skipped].size} session(s). #{reasons}"
    end

    return flash[:notice] = "No sessions to retry" if parts.empty?

    # Only a genuine failure is an alert. A skip is not one: the bulk "retry all
    # recent failures" flow legitimately passes over sessions whose clone is gone,
    # and colouring that red would page the dashboard on every ordinary sweep. The
    # reason still rides along in the message, which is the part that was missing.
    if results[:failed].any?
      flash[:alert] = parts.join(". ")
    else
      flash[:notice] = parts.join(". ")
    end
  end

  # A refusal is the normal, expected answer here — a count that moved between the
  # render and the click is the count confirmation working — so it lands as a
  # flash on the page the operator is already on, with the service's own message,
  # which names the real count they can retry with.
  def render_maintenance_refusal(error)
    respond_to do |format|
      format.html do
        flash[:alert] = error.message
        redirect_to health_dashboard_path
      end
      format.json { render json: { error: "Refused", message: error.message }, status: :unprocessable_entity }
    end
  end

  # "GitHubPullRequestPollerJob 494" — the per-class audit in the flash, so what
  # was thrown away is on screen and not only in the log.
  def queued_job_breakdown(result)
    return "nothing" if result.by_job_class.blank?

    result.by_job_class.map { |klass, count| "#{klass} #{count}" }.join(", ")
  end

  # Minutes from the form, converted to a Duration. Blank means the default;
  # QueueRecoveryMode clamps whatever arrives into MIN_TTL..MAX_TTL, so a hand-typed
  # "9999" becomes the cap rather than an error.
  def recovery_mode_ttl
    minutes = params[:ttl_minutes]
    return nil if minutes.blank?

    minutes.to_i.minutes
  end

  # Refusing and *challenging* are two different things, and on this surface the difference
  # decides whether the operator gets a usable answer or a dead button. Three cases.
  #
  # **HTML, realm configured** — challenge. The dashboard's maintenance controls are
  # `button_to` and `form_with` submissions, and a 401 carrying `WWW-Authenticate: Basic`
  # makes the browser prompt and re-send the POST with the credential.
  #
  # **HTML, realm NOT configured** — still a 401, but refused *without* the challenge and
  # with a body the operator can actually read. A challenge here would open a native
  # sign-in dialog that *no* credential can satisfy, because there is nothing to compare
  # against; the operator would type passwords at it until they gave up. And the
  # explanation would never reach them either: `request_http_basic_authentication` renders
  # `text/plain`, while Turbo renders a form submission's non-redirect body only when it is
  # `text/html` — so a cancelled dialog leaves a button that does nothing at all. Rendering
  # HTML keeps the status honest and puts the reason on screen. Same reasoning as
  # `Supervisor::ApplicationController`'s unconfigured branch, which renders a page instead
  # of a prompt.
  #
  # **JSON** — a body and no challenge either way. It is a script, so a challenge buys it
  # nothing, and omitting it keeps a same-origin `fetch` from opening a native sign-in
  # dialog on a page nobody was leaving.
  #
  # Every branch names the variable, so an unconfigured deployment is diagnosable from the
  # response and not only from the log.
  def refuse_operator(realm_configured: true)
    message = if realm_configured
      "This maintenance action needs the operator credential (HTTP Basic, the same one " \
      "#{OperatorHttpBasicAuth::PASSWORD_ENV} sets for /supervisor)."
    else
      "#{OperatorHttpBasicAuth::PASSWORD_ENV} is unset or blank, so the maintenance actions " \
      "on this page are closed. Set it in the deployment's secrets to use them. The " \
      "read-only dashboard, and POST /api/v1/health/* with an API key, are unaffected."
    end

    respond_to do |format|
      format.html do
        if realm_configured
          request_http_basic_authentication(OperatorHttpBasicAuth::REALM, message)
        else
          render html: message, status: :unauthorized
        end
      end
      format.json { render json: { error: "Unauthorized", message: message }, status: :unauthorized }
    end
  end

  # The same cooldown Api::V1::HealthController and the MCP action_health tool
  # enforce — the same object, so a caller cannot get a second run out of one
  # cooldown by switching surfaces.
  #
  # This surface has no key to fingerprint: the operator realm is one shared credential
  # rather than an identity, so every visitor lands in the one anonymous bucket. That is
  # the global cooldown this controller has always had. What is new is that it fails closed
  # when the cache cannot enforce it, instead of silently waving every action
  # through.
  def cooldown
    @cooldown ||= HealthActionCooldown.new(nil)
  end

  def rate_limited?(action)
    cooldown.limited?(action)
  end

  def record_action(action)
    cooldown.record(action)
  end

  def render_rate_limited
    if cooldown.store_usable?
      render_cooldown_pending
    else
      render_cooldown_unenforceable
    end
  end

  def render_cooldown_pending
    respond_to do |format|
      format.html do
        flash[:alert] = "Please wait #{HealthActionCooldown::COOLDOWN.to_i} seconds between cleanup actions"
        redirect_to health_dashboard_path
      end
      format.json do
        render json: { error: "Rate limited", retry_after: HealthActionCooldown::COOLDOWN.to_i }, status: :too_many_requests
      end
    end
  end

  def render_cooldown_unenforceable
    Rails.logger.error("[health] refusing #{action_name}: the cache cannot enforce the cooldown")
    message = "The cache is unavailable, so the #{HealthActionCooldown::COOLDOWN.to_i}-second cooldown cannot be enforced. " \
      "Maintenance actions are disabled until it is back."

    respond_to do |format|
      format.html do
        flash[:alert] = message
        redirect_to health_dashboard_path
      end
      format.json do
        render json: { error: "Rate limiting unavailable", message: message }, status: :service_unavailable
      end
    end
  end
end

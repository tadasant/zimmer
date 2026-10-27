require "test_helper"
require "mocha/minitest"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# A spawn refused because no account in the pool holds a usable access token is an
# outage of the whole runtime, not a fault of the session (#1399). On 2026-10-27 it
# failed six sessions terminally — two alert-triage first turns, three routers woken
# mid-orchestration, and the very session spawned to tell the operator the pool was
# broken. These pin that a first turn and a resume both PARK instead, carry the turn
# they were refused, resume when the pool comes back, and that the operator hears
# about it without a Claude session.
class AgentSessionJobPoolUnavailableTest < ActiveJob::TestCase
  REFUSAL = "No Claude account in the pool holds a usable access token — authenticate one from /inference"

  setup do
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.delete_all
    AppSetting.current.tap { |s| s.save! unless s.persisted? }.update_columns(pool_outage_alerted_at: nil)

    # The credential injection is what ClaudeSpawnEnv would refuse on; the mock
    # adapter below raises the refusal itself, so keep the real pool out of it.
    ClaudeAuthProvider.any_instance.stubs(:inject_for_session!).returns(nil)

    @clone_path = Dir.mktmpdir("pool_unavailable_test")
    @session = Session.create!(
      prompt: "Triage this alert",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => @clone_path, "working_directory" => @clone_path }
    )
  end

  teardown do
    FileUtils.rm_rf(@clone_path) if @clone_path
  end

  def account!(email:, status:, token: "tok-#{SecureRandom.hex(4)}", **attrs)
    ClaudeAccount.create!(
      email: email,
      status: status,
      runtime: "claude_code",
      oauth_config: { "credentials_json" => { "claudeAiOauth" => { "accessToken" => token } } },
      **attrs
    )
  end

  # Runs one turn whose spawn — fresh or resumed — is refused for want of a token.
  # Returns which adapter call the refusal came from.
  def run_refused_turn(follow_up_prompt = nil)
    calls = []
    cli = MockClaudeCliAdapter.new
    cli.execute_hook = ->(_opts) { calls << :execute; raise ClaudeSpawnEnv::PoolUnavailableError, REFUSAL }
    cli.resume_hook = ->(_opts) { calls << :resume; raise ClaudeSpawnEnv::PoolUnavailableError, REFUSAL }

    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.file_system = MockFileSystemAdapter.new
    job.cli_adapter = cli
    job.file_system.mkdir_p(@clone_path)
    job.file_system.write("#{@clone_path}/claude_stderr.log", "")

    job.perform(@session.id, follow_up_prompt)
    calls
  end

  def enqueued_turn_prompts
    enqueued_jobs.select { |j| j[:job] == AgentSessionJob }.map { |j| j[:args][1] }
  end

  test "a first turn refused for want of a token parks on the quota-drained pool and resumes with its own prompt" do
    # The 2026-10-27 shape: one account benched because its organization disabled
    # Claude Code, every other one over quota, nothing current.
    account!(email: "benched@example.com", status: :needs_reauth, access_disabled_at: 1.hour.ago)
    drained = account!(email: "drained@example.com", status: :quota_exceeded)

    calls = run_refused_turn
    assert_equal [ :execute ], calls, "a first turn spawns fresh"

    @session.reload
    assert_equal "waiting", @session.status, "the session must park, not fail"
    assert_nil @session.metadata["failure_reason"]
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, @session.metadata["auth_outage_reason"]
    assert_equal "Triage this alert", @session.metadata[AuthOutageParkService::UNDELIVERED_PROMPT_KEY]
    assert_nil @session.running_job_id
    assert AuthOutageParkService.parked?(@session)
    assert @session.logs.exists?([ "content LIKE ?", "%nothing in this session went wrong%" ])

    # Nothing wakes it while the pool is still drained.
    clear_enqueued_jobs
    assert_equal 0, AuthOutageParkService.wake_parked_sessions!

    # QuotaResetCheckerJob restores the drained account; the sweep resumes the turn
    # with the task it never got to run, not with a bare nudge.
    drained.update!(status: :active)
    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal [ "Triage this alert" ], enqueued_turn_prompts
    @session.reload
    assert_nil @session.metadata["auth_outage_reason"]
    assert_nil @session.metadata[AuthOutageParkService::UNDELIVERED_PROMPT_KEY]
  end

  test "a resume refused for want of a token parks and redelivers the wake-up's prompt once an account is re-authenticated" do
    dead = account!(email: "dead@example.com", status: :needs_reauth)
    @session.update!(
      transcript: { "type" => "user", "message" => { "content" => "earlier turn" } }.to_json,
      metadata: @session.metadata.merge("runtime_started" => true)
    )
    wake_prompt = "Wake-up: check on child session 25900"

    calls = run_refused_turn(wake_prompt)
    assert_equal [ :resume ], calls, "a started session resumes its conversation"

    @session.reload
    assert_equal "waiting", @session.status, "a router woken mid-orchestration must park, not fail"
    assert_nil @session.metadata["failure_reason"]
    assert_equal AuthOutageParkService::AUTH_UNRECOVERABLE, @session.metadata["auth_outage_reason"]
    assert_equal wake_prompt, @session.metadata[AuthOutageParkService::UNDELIVERED_PROMPT_KEY]

    clear_enqueued_jobs
    assert_equal 0, AuthOutageParkService.wake_parked_sessions!, "nothing has changed in the pool yet"

    # A human re-authenticates on /inference: new credentials, back to active.
    dead.update!(
      status: :active,
      oauth_config: { "credentials_json" => { "claudeAiOauth" => { "accessToken" => "fresh" } } }
    )
    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal [ wake_prompt ], enqueued_turn_prompts
  end

  test "a refused recovery nudge on a started session resumes with the sweep's own nudge" do
    account!(email: "drained@example.com", status: :quota_exceeded)
    @session.update!(
      transcript: { "type" => "user", "message" => { "content" => "earlier turn" } }.to_json,
      metadata: @session.metadata.merge("runtime_started" => true)
    )

    run_refused_turn(AutomatedPrompts::SYSTEM_RECOVERY)

    @session.reload
    assert_equal "waiting", @session.status
    assert_nil @session.metadata[AuthOutageParkService::UNDELIVERED_PROMPT_KEY]

    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:active])
    clear_enqueued_jobs
    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert AutomatedPrompts.system_recovery?(enqueued_turn_prompts.first)
  end

  test "the operator is alerted from Rails, once, naming the org-disabled account" do
    account!(email: "benched@example.com", status: :needs_reauth, access_disabled_at: 1.hour.ago)
    account!(email: "drained@example.com", status: :quota_exceeded)

    errors = []
    Rails.logger.stubs(:error).with { |msg| errors << msg.to_s; true }

    sessions_before = Session.count
    assert_enqueued_with(job: SendPushNotificationJob) do
      run_refused_turn
    end

    page = errors.find { |m| m.include?("[PoolOutageAlert]") }
    assert page, "the refusal must page through an ERROR record, not a spawned session"
    assert_match(/benched@example\.com: its organization disabled Claude subscription access/, page)
    assert_match(/remove the account from the pool/, page)
    assert_match(/drained@example\.com: over quota/, page)
    assert_equal sessions_before, Session.count, "no agent session is spawned to deliver it"

    # A second refusal inside the throttle window parks too, but does not page again.
    second = Session.create!(prompt: "Another alert", agent_runtime: "claude_code", status: :waiting,
      git_root: "https://github.com/test/repo.git", branch: "main", session_id: SecureRandom.uuid,
      metadata: { "clone_path" => @clone_path, "working_directory" => @clone_path })
    @session = second
    errors.clear
    run_refused_turn
    assert_equal "waiting", second.reload.status
    assert_empty errors.grep(/\[PoolOutageAlert\]/)
  end

  # Re-authenticating is the clearest recovery there is; the parked sessions should
  # not sit out the rest of a fifteen-minute sweep interval waiting to hear about it.
  test "a re-authentication brings the wake sweep forward only when something is parked" do
    clear_enqueued_jobs
    assert_not AuthOutageParkService.request_prompt_wake!
    assert_no_enqueued_jobs(only: QuotaResetCheckerJob)

    account!(email: "drained@example.com", status: :quota_exceeded)
    run_refused_turn
    assert_enqueued_with(job: QuotaResetCheckerJob) do
      assert AuthOutageParkService.request_prompt_wake!
    end
  end

  # Spot parks are not the sweep's to resume: the ranked fleet wake restarts them
  # through Sessions::RestartWithPrompt, which must deliver the refused turn too.
  test "a spot park restarted by the fleet wake delivers the refused turn, not a nudge" do
    account!(email: "drained@example.com", status: :quota_exceeded)
    @session.update!(scheduling_class: SessionGenesis::SPOT)

    run_refused_turn
    @session.reload
    assert AuthOutageParkService.parked?(@session)
    assert_not AuthOutageWakeAuthority.sweep_owned?(@session)

    clear_enqueued_jobs
    assert Sessions::RestartWithPrompt.call(@session, actor: :mcp).ok?
    assert_equal [ "Triage this alert" ], enqueued_turn_prompts
    assert_nil @session.reload.metadata[AuthOutageParkService::UNDELIVERED_PROMPT_KEY]
  end

  # The follow-up arm admits a session re-entered while `running`. With no process
  # to end, a `pending_sleep` would never be carried out — it must come to rest.
  test "a session refused while already running parks into waiting" do
    account!(email: "drained@example.com", status: :quota_exceeded)
    @session.update!(status: :running)

    assert AuthOutageParkService.park_refused_spawn!(@session, follow_up_prompt: "keep going on the report")

    @session.reload
    assert_equal "waiting", @session.status
    assert AuthOutageParkService.parked?(@session)
    assert_equal "keep going on the report", @session.metadata[AuthOutageParkService::UNDELIVERED_PROMPT_KEY]
  end

  test "a session archived before its spawn was refused is not parked and pages nobody" do
    @session.update!(status: :archived)
    errors = []
    Rails.logger.stubs(:error).with { |msg| errors << msg.to_s; true }

    assert_not AuthOutageParkService.park_refused_spawn!(@session)
    assert_nil @session.reload.metadata["auth_outage_reason"]
    assert_empty errors.grep(/\[PoolOutageAlert\]/)
  end

  test "the throttle is released once the pool serves a parked session again" do
    drained = account!(email: "drained@example.com", status: :quota_exceeded)
    run_refused_turn
    assert_not_nil AppSetting.current.pool_outage_alerted_at

    drained.update!(status: :active)
    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_nil AppSetting.current.pool_outage_alerted_at
  end
end

# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class OutcomesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Session.delete_all
    # Spawning a session must never actually run an agent from a controller test.
    AgentSessionJob.stubs(:enqueue_new_session).returns(nil)

    @archived = archived_fixture(title: "Fix the login redirect loop", status: :archived, root: "zimmer",
                               runtime: "claude_code", model: "opus")
    @codex = archived_fixture(title: "Backfill the agent root keys", status: :archived, root: "agents",
                            runtime: "codex", model: "gpt-5.6-terra")
    @live = archived_fixture(title: "Still running", status: :running, root: "zimmer",
                           runtime: "claude_code", model: "opus")
  end

  def archived_fixture(title:, status:, root:, runtime:, model:, created_at: 2.days.ago, metadata: {})
    Session.create!(
      title: title, prompt: "x", git_root: "https://github.com/tadasant/zimmer.git", status: status,
      archived_at: (status == :archived ? 1.day.ago : nil), agent_runtime: runtime,
      config: { "model" => model }, metadata: { "agent_root_key" => root }.merge(metadata),
      created_at: created_at
    )
  end

  def analyze!(session, outcome: "Success", failures: 1)
    children = Array.new(failures) do |i|
      { "id" => "S0.#{i}", "trigger" => { "kind" => "New", "source" => "agent" },
        "goal" => { "text" => "Try it", "kind" => "Plan" },
        "outcome" => { "kind" => "Failure", "explanation" => "Broke on the first run." },
        "meta" => {}, "children" => [] }
    end
    OutcomeAnalyses::Save.call(session: session, root: {
      "id" => "S0", "trigger" => { "kind" => "New", "source" => "user" },
      "goal" => { "text" => "Land the fix", "kind" => "Action" },
      "outcome" => { "kind" => outcome, "explanation" => "Landed after a retry." },
      "meta" => {}, "children" => children
    }).analysis
  end

  # --- Ledger ---------------------------------------------------------------

  test "the ledger lists archived sessions and not live ones" do
    get outcomes_path

    assert_response :success
    assert_select "h1", "Outcomes"
    assert_match @archived.title, response.body
    refute_match @live.title, response.body
  end

  test "an unanalyzed row offers Analyze and no drilldown" do
    get outcomes_path

    assert_match "not analyzed", response.body
    assert_select "form[action=?]", analyze_outcome_path(@archived.id)
    assert_select "a[href=?]", outcome_path(@archived.id), false
  end

  test "an analyzed row shows the outcome, the counts and a link to the drilldown" do
    analyze!(@archived, failures: 3)

    get outcomes_path

    assert_select "a[href=?]", outcome_path(@archived.id)
    assert_match "Success", response.body
  end

  test "filters narrow the ledger and survive into the Analyze All form" do
    get outcomes_path, params: { agent_runtime: "codex" }

    assert_response :success
    assert_match @codex.title, response.body
    refute_match @archived.title, response.body
    assert_select "form[action=?]", analyze_all_outcomes_path do
      assert_select "input[name=agent_runtime][value=codex]", 1
    end
  end

  test "the Analyze All button counts only what it would actually enqueue" do
    analyze!(@archived)

    get outcomes_path

    assert_select "input[type=submit][value=?]", "Analyze All (1)"
  end

  test "the concurrency input is offered with no upper bound" do
    get outcomes_path

    assert_select "input[name=concurrency][type=number]" do |inputs|
      assert_equal OutcomeAnalysisBatch::MIN_CONCURRENCY.to_s, inputs.first["min"]
      assert_nil inputs.first["max"], "a typed-in 100 must be honored, not clamped by the form"
    end
  end

  test "warns when the analysis skill is missing from the catalog" do
    OutcomeAnalyses::Config.stubs(:skill_available?).returns(false)

    get outcomes_path

    assert_match "Analysis sessions are not fully wired up yet", response.body
    assert_match OutcomeAnalyses::Config.skill_id, response.body
  end

  # --- Drilldown ------------------------------------------------------------

  test "the drilldown renders a flamegraph cell per segment with its tooltip payload" do
    analyze!(@archived, failures: 2)

    get outcome_path(@archived.id)

    assert_response :success
    assert_select "[data-segment-id]", 3
    assert_select "[data-segment-id=S0][data-outcome=Success]"
    assert_select "[data-segment-id='S0.0'][data-outcome=Failure]" do
      assert_select "[data-explanation=?]", "Broke on the first run."
    end
    assert_select "[data-outcome-flamegraph-target=tooltip]", 1
  end

  test "the drilldown lists every segment in depth-first order" do
    analyze!(@archived, failures: 2)

    get outcome_path(@archived.id)

    assert_select "tr#segment-row-S0"
    assert_select "tr#segment-row-S0\\.0"
    assert_select "tr#segment-row-S0\\.1"
  end

  test "a failed segment under a successful root is shown as failed, not softened" do
    analyze!(@archived, outcome: "Success", failures: 1)

    get outcome_path(@archived.id)

    assert_select "[data-segment-id=S0][data-outcome=Success]"
    assert_select "[data-segment-id='S0.0'][data-outcome=Failure]"
  end

  test "the drilldown redirects when the session has not been analyzed" do
    get outcome_path(@archived.id)

    assert_redirected_to outcomes_path
    assert_match(/has not been analyzed/, flash[:alert])
  end

  test "the drilldown lists superseded analyses" do
    analyze!(@archived)
    analyze!(@archived, outcome: "Failure")

    get outcome_path(@archived.id)

    assert_match "Superseded analyses", response.body
  end

  # --- Stats ----------------------------------------------------------------

  test "stats is a separate surface with its own grouping" do
    analyze!(@archived)
    analyze!(@codex, outcome: "Failure")

    get outcomes_stats_path

    assert_response :success
    assert_select "h1", "Outcome stats"
    assert_match "By harness", response.body
    assert_match "Failed segments per transcript", response.body
  end

  test "stats can be grouped by model and by agent root" do
    analyze!(@archived)

    get outcomes_stats_path, params: { group_by: "model" }
    assert_match "By model", response.body

    get outcomes_stats_path, params: { group_by: "agent_root" }
    assert_match "By agent root", response.body
  end

  test "stats says so plainly when nothing has been analyzed" do
    get outcomes_stats_path

    assert_response :success
    assert_match "No analyses match these filters yet", response.body
  end

  # --- Analyze --------------------------------------------------------------

  test "Analyze spawns one session and returns to the filtered ledger" do
    assert_difference -> { Session.outcome_analysis_sessions.count }, 1 do
      post analyze_outcome_path(@archived.id), params: { agent_runtime: "codex" }
    end

    assert_redirected_to outcomes_path(agent_runtime: "codex")
    assert_match(/Analyzing session ##{@archived.id}/, flash[:notice])
  end

  test "Analyze reports the failure instead of 500ing when the spawn cannot happen" do
    OutcomeAnalyses::SpawnAnalysisSession.stubs(:call).raises(
      OutcomeAnalyses::SpawnAnalysisSession::Error, "agent root missing"
    )

    post analyze_outcome_path(@archived.id)

    assert_redirected_to outcomes_path
    assert_match(/Could not start the analysis/, flash[:alert])
  end

  test "nothing analyzes on a page load" do
    assert_no_difference -> { Session.outcome_analysis_sessions.count } do
      get outcomes_path
      get outcomes_stats_path
    end
  end

  # --- Analyze All ----------------------------------------------------------

  test "Analyze All builds a batch from the current filters at the typed concurrency" do
    assert_difference -> { OutcomeAnalysisBatch.count }, 1 do
      post analyze_all_outcomes_path, params: { agent_runtime: "codex", concurrency: "7" }
    end

    batch = OutcomeAnalysisBatch.last
    assert_equal 7, batch.concurrency
    assert_equal 1, batch.total_count
    assert_equal [ @codex.id ], batch.items.pluck(:session_id)
    assert_match(/Queued 1 analysis at 7 at a time/, flash[:notice])
  end

  test "an ill-advised concurrency is honored and called out rather than clamped" do
    post analyze_all_outcomes_path, params: { concurrency: "100" }

    assert_equal 100, OutcomeAnalysisBatch.last.concurrency
    assert_match(/well above what the spot gate will let through/, flash[:notice])
  end

  test "Analyze All says so when the filters match nothing left to analyze" do
    analyze!(@archived)
    analyze!(@codex)

    assert_no_difference -> { OutcomeAnalysisBatch.count } do
      post analyze_all_outcomes_path, params: { concurrency: "1" }
    end

    assert_match(/No unanalyzed archived sessions match/, flash[:alert])
  end

  test "a running batch is rendered with its counts and a Stop button" do
    post analyze_all_outcomes_path, params: { concurrency: "1" }
    batch = OutcomeAnalysisBatch.last

    get outcomes_path

    assert_match "Batch ##{batch.id}", response.body
    assert_select "form[action=?]", cancel_outcome_batch_path(batch)
  end

  test "Stop cancels the queue and leaves in-flight analyses to finish" do
    post analyze_all_outcomes_path, params: { concurrency: "1" }
    batch = OutcomeAnalysisBatch.last

    post cancel_outcome_batch_path(batch)

    assert_equal OutcomeAnalysisBatch::CANCELED, batch.reload.status
    assert_equal 0, batch.items.queued.count
    assert_match(/Stopped batch ##{batch.id}/, flash[:notice])
  end

  test "the ledger reaches the stats view and back, carrying the filters" do
    get outcomes_path, params: { agent_runtime: "codex", model: "gpt-5.6-terra" }

    assert_select "a[href=?]", outcomes_stats_path(agent_runtime: "codex", model: "gpt-5.6-terra")
  end

  test "the menu bar links to Outcomes" do
    get root_path

    assert_select "a[href=?]", outcomes_path
  end
end

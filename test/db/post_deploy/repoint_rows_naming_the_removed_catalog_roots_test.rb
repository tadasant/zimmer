# frozen_string_literal: true

require "test_helper"

# The ops half of https://github.com/tadasant/zimmer/issues/67. Removing
# `agent-orchestrator` and `agents` from roots.json leaves every trigger armed
# against them raising `AgentRootNotFoundError` on every fire —
# `Trigger#heal_stale_agent_root!` cannot find a successor, because the sessions
# it matches on carry a git_root no surviving root points at.
class RepointRowsNamingTheRemovedCatalogRootsTest < ActiveSupport::TestCase
  CATALOG_REPO = "https://github.com/tadasant/zimmer-catalog.git"

  setup do
    @entry = PostDeployTask::Registry.find("20260907120000")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  def session(agent_root_key, subdirectory: nil)
    Session.create!(prompt: "root #{SecureRandom.hex(4)}", agent_runtime: "claude_code",
                    status: :waiting, git_root: CATALOG_REPO, branch: "main",
                    subdirectory: subdirectory,
                    metadata: { "agent_root_key" => agent_root_key, "process_pid" => 7 })
  end

  def trigger(agent_root_name, last_session_id: nil)
    Trigger.create!(name: "t #{SecureRandom.hex(4)}", status: "enabled",
                    agent_root_name: agent_root_name, prompt_template: "go",
                    reuse_session: true, last_session_id: last_session_id,
                    mcp_servers: [], catalog_skills: [], catalog_hooks: [], catalog_plugins: [],
                    trigger_conditions_attributes: [
                      { condition_type: "schedule",
                        configuration: { "interval" => 1, "unit" => "days", "time" => "03:00", "timezone" => "UTC" } }
                    ])
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    outcome = @task_class.new(run: run, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  test "repoints both removed roots on triggers and sessions, and leaves every other root alone" do
    orchestrator_session = session("agent-orchestrator", subdirectory: "agents/agent-orchestrator")
    agents_session = session("agents", subdirectory: "agents")
    live_session = session("general-agent")

    orchestrator_trigger = trigger("agent-orchestrator", last_session_id: orchestrator_session.id)
    agents_trigger = trigger("agents", last_session_id: agents_session.id)
    live_trigger = trigger("zimmer", last_session_id: live_session.id)

    run, outcome = run_task

    assert_nil outcome, "a task that finishes returns something other than CONTINUE"

    assert_equal "zimmer", orchestrator_trigger.reload.agent_root_name
    assert_equal "zimmer", agents_trigger.reload.agent_root_name
    assert_equal "zimmer", live_trigger.reload.agent_root_name, "already correct, and untouched"

    assert_equal "zimmer", orchestrator_session.reload.metadata["agent_root_key"]
    assert_equal "zimmer", agents_session.reload.metadata["agent_root_key"]
    assert_equal "general-agent", live_session.reload.metadata["agent_root_key"],
      "a session on a root that still ships must not be rewritten"

    assert_equal 7, orchestrator_session.metadata["process_pid"], "unrelated metadata keys survive"
    assert_equal 2, run.stats["triggers"]
    assert_equal 2, run.stats["sessions"]
  end

  test "leaves the sessions' own clone coordinates alone" do
    stale = session("agents", subdirectory: "agents")

    run_task

    stale.reload
    assert_equal CATALOG_REPO, stale.git_root,
      "rewriting git_root would claim the session ran somewhere it did not"
    assert_equal "agents", stale.subdirectory
  end

  test "a repointed trigger heals instead of raising" do
    stale_session = session("agent-orchestrator", subdirectory: "agents/agent-orchestrator")
    stale_trigger = trigger("agent-orchestrator", last_session_id: stale_session.id)

    # The defect the task exists for: before it runs, the name is absent from the
    # catalog and no (git_root, subdirectory) successor exists, so healing raises.
    assert_raises(AgentRootsConfig::AgentRootNotFoundError) do
      stale_trigger.send(:heal_stale_agent_root!)
    end

    run_task

    # Afterwards the name resolves, so heal_stale_agent_root! returns at its
    # `exists?` guard without reaching the raise.
    assert_nothing_raised { stale_trigger.reload.send(:heal_stale_agent_root!) }
    assert_equal "zimmer", stale_trigger.reload.agent_root_name
  end

  test "is idempotent - a second run finds nothing left to do" do
    stale = session("agents")
    stale_trigger = trigger("agents", last_session_id: stale.id)

    first_run, = run_task
    assert_equal 1, first_run.stats["triggers"]
    assert_equal 1, first_run.stats["sessions"]

    second_run, outcome = run_task

    assert_nil outcome
    # The counters are cumulative across slices of one ledger row, so "nothing
    # left to do" reads as "they did not move" rather than as zero: both
    # relations are keyed on the OLD value, so a repointed row no longer matches.
    assert_equal 1, second_run.stats["triggers"], "no trigger was repointed twice"
    assert_equal 1, second_run.stats["sessions"], "no session was repointed twice"
    assert_empty Trigger.where(agent_root_name: %w[agent-orchestrator agents]),
      "nothing is left matching the removed roots"
    assert_equal "zimmer", stale_trigger.reload.agent_root_name
    assert_equal "zimmer", stale.reload.metadata["agent_root_key"]
  end
end

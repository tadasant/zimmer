# frozen_string_literal: true

require "test_helper"

# The per-session spot/priority lever in the web UI: the button on the hold
# banner, which is what releases one held session without touching the trigger
# that spawned it or the policy every other session of its genesis shares.
class SessionsControllerSchedulingClassTest < ActionDispatch::IntegrationTest
  setup do
    @session = sessions(:needs_input)
    @session.update!(genesis: SessionGenesis::GITHUB_ISSUE, scheduling_class: nil)
  end

  test "promoting one session leaves its genesis and its siblings alone" do
    sibling = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::GITHUB_ISSUE)
    assert @session.spot?

    patch update_scheduling_class_session_url(@session), params: { scheduling_class: SessionGenesis::PRIORITY }

    assert_redirected_to session_path(@session)
    assert @session.reload.priority?
    assert_equal SessionGenesis::GITHUB_ISSUE, @session.genesis
    assert sibling.reload.spot?, "one session moved, not the whole genesis"
  end

  test "a blank value returns the session to deriving from its genesis" do
    @session.update!(scheduling_class: SessionGenesis::PRIORITY)

    patch update_scheduling_class_session_url(@session), params: { scheduling_class: "" }

    assert_nil @session.reload.scheduling_class
    assert @session.spot?
  end

  test "an unknown class is refused" do
    patch update_scheduling_class_session_url(@session), params: { scheduling_class: "whenever" }

    assert_nil @session.reload.scheduling_class
    assert_match(/Unknown scheduling class/, flash[:alert])
  end

  test "the new-session form can spawn a spot session" do
    post sessions_url, params: {
      session: {
        prompt: "Long unattended batch",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        scheduling_class: SessionGenesis::SPOT,
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator",
      agent_runtime: "claude_code"
    }

    created = Session.order(:id).last
    assert_equal SessionGenesis::WEB_UI, created.genesis, "a human still typed it"
    assert_equal SessionGenesis::SPOT, created.scheduling_class
    assert created.spot?
  end

  test "the form's default option leaves the class derived" do
    post sessions_url, params: {
      session: {
        prompt: "Ordinary request",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        scheduling_class: "",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator",
      agent_runtime: "claude_code"
    }

    created = Session.order(:id).last
    assert_nil created.scheduling_class
    assert created.priority?
  end

  test "the change is recorded in the session's own log" do
    patch update_scheduling_class_session_url(@session), params: { scheduling_class: SessionGenesis::PRIORITY }

    assert @session.logs.where("content LIKE ?", "%Scheduling class set to priority%").exists?
  end
end

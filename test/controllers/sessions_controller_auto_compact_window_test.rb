require "test_helper"

# Covers the new-session form path for the per-session auto_compact_window knob
# (the CLAUDE_CODE_AUTO_COMPACT_WINDOW budget). The HTML form submits it as
# session[auto_compact_window]; only Claude Code honors it, and the field is
# disabled (so it submits blank, keeping the column default) for other runtimes.
class SessionsControllerAutoCompactWindowTest < ActionDispatch::IntegrationTest
  test "create persists a custom auto_compact_window from the form" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        auto_compact_window: 350_000,
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator",
      agent_runtime: "claude_code"
    }

    assert_equal 350_000, Session.last.auto_compact_window
  end

  test "create defaults auto_compact_window to the column default when blank" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        auto_compact_window: "",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator",
      agent_runtime: "claude_code"
    }

    assert_equal 1_000_000, Session.last.auto_compact_window
  end

  test "create defaults auto_compact_window when the param is omitted entirely" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator"
    }

    assert_equal 1_000_000, Session.last.auto_compact_window
  end

  test "create rejects an out-of-range auto_compact_window" do
    assert_no_difference "Session.count" do
      post sessions_url, params: {
        session: {
          prompt: "Test prompt",
          git_root: "https://github.com/tadasant/zimmer-catalog.git",
          auto_compact_window: 2_000_000,
          mcp_servers: []
        },
        agent_root_name: "agent-orchestrator",
        agent_runtime: "claude_code"
      }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects a non-positive auto_compact_window" do
    assert_no_difference "Session.count" do
      post sessions_url, params: {
        session: {
          prompt: "Test prompt",
          git_root: "https://github.com/tadasant/zimmer-catalog.git",
          auto_compact_window: 0,
          mcp_servers: []
        },
        agent_root_name: "agent-orchestrator",
        agent_runtime: "claude_code"
      }
    end

    assert_response :unprocessable_entity
  end

  # --- Mid-session update path: PATCH /sessions/:id/update_auto_compact_window ---
  # Mirrors the mid-session model change. The value is a top-level column consumed
  # as CLAUDE_CODE_AUTO_COMPACT_WINDOW at spawn time, so it applies on the next
  # turn / restart (the running process keeps its window).

  test "update_auto_compact_window persists the new value and logs the change" do
    session = sessions(:running)
    old_window = session.auto_compact_window

    assert_difference "session.logs.count", 1 do
      patch update_auto_compact_window_session_url(session),
        params: { auto_compact_window: 500_000 },
        as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal 500_000, body["auto_compact_window"]
    assert_equal 500_000, session.reload.auto_compact_window

    log = session.logs.order(:created_at).last
    assert_includes log.content, "Context window updated (#{old_window} → 500000)"
    assert_includes log.content, "applies on next turn or restart"
  end

  test "update_auto_compact_window does not log when value is unchanged" do
    session = sessions(:running)
    current = session.auto_compact_window

    assert_no_difference "session.logs.count" do
      patch update_auto_compact_window_session_url(session),
        params: { auto_compact_window: current },
        as: :json
    end

    assert_response :success
    assert_equal current, session.reload.auto_compact_window
  end

  test "update_auto_compact_window rejects an out-of-range value" do
    session = sessions(:running)
    original = session.auto_compact_window

    patch update_auto_compact_window_session_url(session),
      params: { auto_compact_window: 2_000_000 },
      as: :json

    assert_response :unprocessable_entity
    assert_equal original, session.reload.auto_compact_window
  end

  test "update_auto_compact_window rejects a non-positive value" do
    session = sessions(:running)
    original = session.auto_compact_window

    patch update_auto_compact_window_session_url(session),
      params: { auto_compact_window: 0 },
      as: :json

    assert_response :unprocessable_entity
    assert_equal original, session.reload.auto_compact_window
  end

  test "update_auto_compact_window rejects a blank or non-integer value" do
    session = sessions(:running)
    original = session.auto_compact_window

    [ "", "abc", "5.5" ].each do |bad|
      patch update_auto_compact_window_session_url(session),
        params: { auto_compact_window: bad },
        as: :json

      assert_response :unprocessable_entity
      assert_equal original, session.reload.auto_compact_window
    end
  end
end

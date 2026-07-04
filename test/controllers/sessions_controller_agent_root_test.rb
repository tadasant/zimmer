require "test_helper"

class SessionsControllerAgentRootTest < ActionDispatch::IntegrationTest
  # Test that subdirectory is correctly set based on agent root name selection
  test "should set subdirectory when selecting agent-orchestrator agent root" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator"
    }

    session = Session.last
    assert_equal "https://github.com/tadasant/zimmer-catalog.git", session.git_root
    assert_equal "agents/agent-orchestrator", session.subdirectory
    assert_equal "main", session.branch
    assert_equal "pulsemcp/agents/agent-orchestrator", session.agent_root_path
  end

  test "should set subdirectory when selecting agents agent root" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agents"
    }

    session = Session.last
    assert_equal "https://github.com/tadasant/zimmer-catalog.git", session.git_root
    assert_equal "agents", session.subdirectory
    assert_equal "main", session.branch
    assert_equal "pulsemcp/agents", session.agent_root_path
  end

  test "should set subdirectory for pulsemcp agent root (no subdirectory)" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "pulsemcp"
    }

    session = Session.last
    assert_equal "https://github.com/tadasant/zimmer-catalog.git", session.git_root
    assert_nil session.subdirectory
    assert_equal "main", session.branch
    assert_equal "pulsemcp", session.agent_root_path
  end

  test "should fallback to URL-based lookup when agent_root_name not provided" do
    # This tests backward compatibility
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      }
      # Note: no agent_root_name parameter
    }

    session = Session.last
    assert_equal "https://github.com/tadasant/zimmer-catalog.git", session.git_root
    # This will get the first matching agent root's subdirectory from the config
    # Currently pulsemcp-agentic-engineering is first among pulsemcp.git roots
    # (its subdirectory is "agentic-engineering-infra")
    assert_equal "agentic-engineering-infra", session.subdirectory
  end

  test "should handle custom URL without agent_root_name" do
    # When user provides a custom URL that's not in the config
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/user/custom-repo.git",
        mcp_servers: []
      }
    }

    session = Session.last
    assert_equal "https://github.com/user/custom-repo.git", session.git_root
    assert_nil session.subdirectory  # No matching config, so no subdirectory
    assert_equal "main", session.branch  # Defaults to main
    assert_equal "custom-repo", session.agent_root_path
  end

  test "should preserve explicitly set subdirectory even with agent_root_name" do
    # If user explicitly sets a subdirectory, it should be preserved
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        subdirectory: "custom-dir",
        mcp_servers: []
      },
      agent_root_name: "agents"
    }

    session = Session.last
    assert_equal "https://github.com/tadasant/zimmer-catalog.git", session.git_root
    assert_equal "custom-dir", session.subdirectory  # User's explicit choice preserved
    assert_equal "pulsemcp/custom-dir", session.agent_root_path
  end

  test "should preserve explicitly set branch even with agent_root_name" do
    # If user explicitly sets a branch, it should be preserved
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        branch: "develop",
        mcp_servers: []
      },
      agent_root_name: "agents"
    }

    session = Session.last
    assert_equal "https://github.com/tadasant/zimmer-catalog.git", session.git_root
    assert_equal "develop", session.branch  # User's explicit choice preserved
  end

  test "should handle missing agent root configuration gracefully" do
    # If agent_root_name is provided but not found in config
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/test/repo.git",
        mcp_servers: []
      },
      agent_root_name: "nonexistent"
    }

    session = Session.last
    assert_equal "https://github.com/test/repo.git", session.git_root
    assert_nil session.subdirectory  # No config found, no subdirectory set
    assert_equal "main", session.branch  # Defaults to main
  end

  # Test the scenario described in issue #283
  test "issue 283 - agents agent root should not get agent-orchestrator subdirectory" do
    # Simulate user selecting "Agents" agent root from dropdown
    # This should NOT set subdirectory to agent-orchestrator
    post sessions_url, params: {
      session: {
        prompt: "Test the root agents agent root",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agents"  # User selected "agents" not "agent-orchestrator"
    }

    session = Session.last

    # Verify the fix: agents root gets "agents" subdirectory (monorepo subdir), not agent-orchestrator
    assert_equal "https://github.com/tadasant/zimmer-catalog.git", session.git_root
    assert_equal "pulsemcp", session.agent_root_name
    assert_equal "agents", session.subdirectory, "Subdirectory should be 'agents' for the agents agent root"
    assert_equal "pulsemcp/agents", session.agent_root_path

    # This is the key assertion - ensuring we don't incorrectly set agent-orchestrator subdirectory
    refute_equal "agents/agent-orchestrator", session.subdirectory, "Should NOT have agents/agent-orchestrator subdirectory"
  end

  # ============================================================
  # Agent runtime resolution on create
  # ============================================================

  test "create defaults agent_runtime to claude_code when not provided" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator"
    }

    assert_equal "claude_code", Session.last.agent_runtime
  end

  test "create resolves agent_runtime from the agent_runtime param" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator",
      agent_runtime: "claude_code"
    }

    assert_equal "claude_code", Session.last.agent_runtime
  end

  test "create falls back to default runtime for an unregistered agent_runtime param" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator",
      agent_runtime: "aider"
    }

    assert_equal "claude_code", Session.last.agent_runtime
  end

  test "create persists a registered agent_runtime param" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator",
      agent_runtime: "codex"
    }

    assert_equal "codex", Session.last.agent_runtime
  end

  test "create stores a runtime-valid model in config" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator",
      model: "sonnet"
    }

    assert_equal "sonnet", Session.last.config["model"]
  end

  test "create rejects an out-of-catalog model and falls back to a valid one" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer-catalog.git",
        mcp_servers: []
      },
      agent_root_name: "agent-orchestrator",
      model: "gpt-5"
    }

    session = Session.last
    assert_not_equal "gpt-5", session.config["model"]
    assert_includes ModelCatalog.model_ids_for(session.agent_runtime), session.config["model"]
  end
end

require "test_helper"
require "mocha/minitest"

class SessionsControllerAgentRootTest < ActionDispatch::IntegrationTest
  # Since #67 every root Zimmer ships sits at the root of `tadasant/zimmer`, so
  # the catalog has no live example of a root scoped to a subdirectory. The
  # controller still honours one -- a self-hoster pointing a root at a monorepo
  # subdirectory is the case it exists for -- so the subdirectory tests below
  # stub a scoped root rather than asserting against a catalog entry that would
  # have to be resurrected to keep them passing.
  MONOREPO_URL = "https://github.com/tadasant/monorepo.git"

  def stub_scoped_root(name, subdirectory)
    root = AgentRootsConfig::AgentRoot.new(
      name, { "url" => MONOREPO_URL, "default_branch" => "main", "subdirectory" => subdirectory }
    )
    AgentRootsConfig.stubs(:find).returns(nil)
    AgentRootsConfig.stubs(:find).with(name).returns(root)
    root
  end

  # Test that subdirectory is correctly set based on agent root name selection
  test "should set subdirectory when selecting a root scoped to one" do
    stub_scoped_root("scoped-app", "apps/scoped-app")

    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: MONOREPO_URL,
        mcp_servers: []
      },
      agent_root_name: "scoped-app"
    }

    session = Session.last
    assert_equal MONOREPO_URL, session.git_root
    assert_equal "apps/scoped-app", session.subdirectory
    assert_equal "main", session.branch
    assert_equal "monorepo/apps/scoped-app", session.agent_root_path
  end

  test "should set no subdirectory for a root that declares none" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer.git",
        mcp_servers: []
      },
      agent_root_name: "zimmer"
    }

    session = Session.last
    assert_equal "https://github.com/tadasant/zimmer.git", session.git_root
    assert_nil session.subdirectory
    assert_equal "main", session.branch
    assert_equal "zimmer", session.agent_root_path
  end

  test "should fallback to URL-based lookup when agent_root_name not provided" do
    # This tests backward compatibility
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer.git",
        mcp_servers: []
      }
      # Note: no agent_root_name parameter
    }

    session = Session.last
    assert_equal "https://github.com/tadasant/zimmer.git", session.git_root
    # The URL lookup takes the first root at that URL. Every shipped root is at
    # this one, and none declares a subdirectory, so none is copied over.
    assert_nil session.subdirectory
    assert_equal "main", session.branch
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
    # If user explicitly sets a subdirectory, it should be preserved -- even when
    # the selected root declares one of its own.
    stub_scoped_root("scoped-app", "apps/scoped-app")

    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: MONOREPO_URL,
        subdirectory: "custom-dir",
        mcp_servers: []
      },
      agent_root_name: "scoped-app"
    }

    session = Session.last
    assert_equal MONOREPO_URL, session.git_root
    assert_equal "custom-dir", session.subdirectory  # User's explicit choice preserved
    assert_equal "monorepo/custom-dir", session.agent_root_path
  end

  test "should preserve explicitly set branch even with agent_root_name" do
    # If user explicitly sets a branch, it should be preserved
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer.git",
        branch: "develop",
        mcp_servers: []
      },
      agent_root_name: "zimmer"
    }

    session = Session.last
    assert_equal "https://github.com/tadasant/zimmer.git", session.git_root
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

  # Test the scenario described in issue pulsemcp/agents#283: when two roots share
  # a repo and one is scoped inside the other, the selected root's subdirectory is
  # the one that lands -- not its sibling's.
  test "issue 283 - the selected root's subdirectory is used, not a sibling root's" do
    stub_scoped_root("outer", "packages")

    post sessions_url, params: {
      session: {
        prompt: "Test the outer agent root",
        git_root: MONOREPO_URL,
        mcp_servers: []
      },
      agent_root_name: "outer"  # User selected "outer", not the nested "packages/inner"
    }

    session = Session.last

    assert_equal MONOREPO_URL, session.git_root
    assert_equal "monorepo", session.agent_root_name
    assert_equal "packages", session.subdirectory, "Subdirectory should be 'packages' for the outer agent root"
    assert_equal "monorepo/packages", session.agent_root_path

    # The key assertion - the nested sibling's subdirectory must not leak in.
    refute_equal "packages/inner", session.subdirectory, "Should NOT have the nested root's subdirectory"
  end

  # ============================================================
  # Agent runtime resolution on create
  # ============================================================

  test "create defaults agent_runtime to claude_code when not provided" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer.git",
        mcp_servers: []
      },
      agent_root_name: "zimmer"
    }

    assert_equal "claude_code", Session.last.agent_runtime
  end

  test "create resolves agent_runtime from the agent_runtime param" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer.git",
        mcp_servers: []
      },
      agent_root_name: "zimmer",
      agent_runtime: "claude_code"
    }

    assert_equal "claude_code", Session.last.agent_runtime
  end

  test "create falls back to default runtime for an unregistered agent_runtime param" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer.git",
        mcp_servers: []
      },
      agent_root_name: "zimmer",
      agent_runtime: "aider"
    }

    assert_equal "claude_code", Session.last.agent_runtime
  end

  test "create persists a registered agent_runtime param" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer.git",
        mcp_servers: []
      },
      agent_root_name: "zimmer",
      agent_runtime: "codex"
    }

    assert_equal "codex", Session.last.agent_runtime
  end

  test "create stores a runtime-valid model in config" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer.git",
        mcp_servers: []
      },
      agent_root_name: "zimmer",
      model: "sonnet"
    }

    assert_equal "sonnet", Session.last.config["model"]
  end

  test "create rejects an out-of-catalog model and falls back to a valid one" do
    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: "https://github.com/tadasant/zimmer.git",
        mcp_servers: []
      },
      agent_root_name: "zimmer",
      model: "gpt-5"
    }

    session = Session.last
    assert_not_equal "gpt-5", session.config["model"]
    assert_includes ModelCatalog.model_ids_for(session.agent_runtime), session.config["model"]
  end
end

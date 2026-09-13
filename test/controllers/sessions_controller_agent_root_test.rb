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

  def scoped_root(name, subdirectory, default_branch: "main")
    AgentRootsConfig::AgentRoot.new(
      name, { "url" => MONOREPO_URL, "default_branch" => default_branch, "subdirectory" => subdirectory }
    )
  end

  # `all` is the seam deliberately, not `find`. `find`, `find!`, `exists?`,
  # `default`, `user_invocable` and `find_for_session` all derive from it, and so
  # does the branch under test in half these cases -- the controller's URL
  # fallback is `AgentRootsConfig.all.find { |ar| ar.url == git_root }`. Stubbing
  # `find` alone would leave that fallback reading the real catalog, where
  # nothing sits at MONOREPO_URL, so the tests that exercise it would pass
  # whether or not the branch existed.
  #
  # The real catalog is captured first and kept, so a root this file does not
  # name still resolves. `AgentRootsConfig.all` must be read BEFORE `stubs(:all)`
  # installs the stub, or it returns nil into its own replacement.
  def stub_catalog_with(*extra_roots)
    catalog = AgentRootsConfig.all.to_a + extra_roots
    AgentRootsConfig.stubs(:all).returns(catalog)
    catalog
  end

  # Test that subdirectory is correctly set based on agent root name selection
  test "should set subdirectory when selecting a root scoped to one" do
    stub_catalog_with(scoped_root("scoped-app", "apps/scoped-app"))

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
    # This tests backward compatibility. The stubbed root declares a subdirectory
    # AND a non-default branch, so both assertions below fail if the URL-fallback
    # branch stops copying them.
    #
    # `branch: ""` is what the new-session form actually posts when the user
    # leaves the field empty, and it matters: the controller only fills the branch
    # in `if @session.branch.blank?`, and `sessions.branch` carries a column
    # default of "main", so omitting the key entirely would make the session
    # arrive already non-blank and the assertion would read the default rather
    # than the root's.
    stub_catalog_with(scoped_root("scoped-app", "apps/scoped-app", default_branch: "develop"))

    post sessions_url, params: {
      session: {
        prompt: "Test prompt",
        git_root: MONOREPO_URL,
        branch: "",
        mcp_servers: []
      }
      # Note: no agent_root_name parameter
    }

    session = Session.last
    assert_equal MONOREPO_URL, session.git_root
    assert_equal "apps/scoped-app", session.subdirectory
    assert_equal "develop", session.branch
  end

  # The URL fallback resolves a root like any other, so it records which one
  # (zimmer#454) — before, it filled in the branch and subdirectory and never
  # stamped the key.
  test "the URL fallback stamps the root it resolved as agent_root_key" do
    stub_catalog_with(scoped_root("scoped-app", "apps/scoped-app"))

    post sessions_url, params: {
      session: { prompt: "Test prompt", git_root: MONOREPO_URL, branch: "", mcp_servers: [] }
    }

    assert_equal "scoped-app", Session.last.metadata["agent_root_key"]
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
    stub_catalog_with(scoped_root("scoped-app", "apps/scoped-app"))

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
  # the one that lands -- not its sibling's. Both roots are in the stubbed catalog,
  # so the refute below can actually fail.
  test "issue 283 - the selected root's subdirectory is used, not a sibling root's" do
    stub_catalog_with(scoped_root("outer", "packages"), scoped_root("inner", "packages/inner"))

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

  test "create treats an unregistered agent_runtime param as unnamed and takes the root's runtime" do
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

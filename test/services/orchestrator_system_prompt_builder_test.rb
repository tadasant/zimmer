require "test_helper"

class OrchestratorSystemPromptBuilderTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:active_session)
    @session.update!(
      session_id: "test-session-uuid-123",
      repository_name: "test-repo",
      branch: "main",
      subdirectory: nil
    )

    # Pin the scratch base so the durable-scratch prompt line (and the byte-golden
    # snapshot below) is deterministic regardless of the runner's HOME/clones dir.
    # The value mirrors the natural production path (HOME=/home/rails).
    @original_scratch_dir = ENV["AGENT_SCRATCH_DIR"]
    ENV["AGENT_SCRATCH_DIR"] = "/home/rails/.zimmer/session-scratch"
  end

  teardown do
    if @original_scratch_dir.nil?
      ENV.delete("AGENT_SCRATCH_DIR")
    else
      ENV["AGENT_SCRATCH_DIR"] = @original_scratch_dir
    end
  end

  test "builds prompt with orchestrator context section" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "# Zimmer Context"
    assert_includes prompt, "You are facilitating an agent session within Zimmer"
    assert_includes prompt, "Environment: test"
    assert_includes prompt, "https://github.com/tadasant/zimmer-catalog"
  end

  test "builds prompt with session information" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "## Session Information"
    assert_includes prompt, "Session ID: #{@session.id}"
    assert_includes prompt, "Session URL: http://localhost:3000/sessions/#{@session.id}"
    assert_includes prompt, "Repository: test-repo"
    assert_includes prompt, "Branch: main"
  end

  test "includes working directory when clone_path provided" do
    prompt = OrchestratorSystemPromptBuilder.build(
      session: @session,
      clone_path: "/tmp/test-clone-path"
    )

    assert_includes prompt, "Working directory: /tmp/test-clone-path"
  end

  test "includes durable scratch directory note steering agents away from /tmp" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "Durable scratch directory"
    assert_includes prompt, "$AO_SESSION_SCRATCH_DIR"
    assert_includes prompt, SessionScratchDirectory.path_for(@session.id)
    assert_includes prompt, "Do NOT use /tmp for cross-step state"
  end

  test "includes subdirectory when present" do
    @session.update!(subdirectory: "packages/core")

    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "Subdirectory: packages/core"
  end

  test "excludes subdirectory when not present" do
    @session.update!(subdirectory: nil)

    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    refute_includes prompt, "Subdirectory:"
  end

  test "includes MCP servers section when servers configured" do
    # MCP servers are stored as string names that must exist in the catalog
    # Use the fixture values which should already have valid servers
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    # The active_session fixture has MCP servers configured
    if @session.mcp_servers.present?
      assert_includes prompt, "## MCP Servers"
    end
  end

  test "excludes MCP servers section when no servers configured" do
    @session.update!(mcp_servers: [])

    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    refute_includes prompt, "## MCP Servers"
  end

  test "includes operating principles section" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "## Operating Principles"
    assert_includes prompt, "These principles govern how every agent operates"
  end

  test "includes human-approved git changes principle" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "### 1. Human-Approved Git Changes"
    assert_includes prompt, "Pull requests are the primary human review gate"
    assert_includes prompt, "must NOT merge PRs on your own unless the user explicitly requests it"
  end

  test "includes agent root scope discipline principle" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "### 2. Agent Root Scope Discipline"
    assert_includes prompt, "only modify files within that subdirectory"
    assert_includes prompt, "mechanical reference-only changes"
    assert_includes prompt, "File a GitHub issue"
    assert_includes prompt, "stricter scope rules that take precedence"
  end

  test "includes remote execution environment principle" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "### 3. Remote Execution Environment"
    assert_includes prompt, "sessions run on remote servers, not on the user's local machine"
    assert_includes prompt, "has no access to the agent's filesystem"
    assert_includes prompt, "Bias toward inline content"
    assert_includes prompt, "show them directly in your conversation text"
    assert_includes prompt, "File paths as context, not delivery"
    assert_includes prompt, "Remote filesystem MCP servers are optional"
    assert_includes prompt, "Never instruct the user to open a local file"
    assert_includes prompt, "surface it in the conversation"
  end

  test "includes liberal MCP server usage principle" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "### 4. Liberal MCP Server Usage"
    assert_includes prompt, "Do not hesitate to use the tools you have been provisioned with"
    assert_includes prompt, "security-abusive"
  end

  test "principle 4 instructs agents to prefer MCP over CLI tooling" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "Prefer MCP over CLI tooling",
      "expected the prompt to explicitly call out the MCP-over-CLI preference"
    assert_includes prompt, "pre-configured with credentials",
      "expected the prompt to explain why MCP is preferred (pre-credentialed)"
    assert_includes prompt, "spawning sub-sessions",
      "expected the prompt to extend the MCP-over-CLI preference to sub-session provisioning"
  end

  test "includes feature branch discipline principle" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "### 5. Feature Branch Discipline"
    assert_includes prompt, "Always work on a feature branch, never directly on `main`, unless the user explicitly asks"
  end

  test "includes expected operations SLAs" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "### 6. Expected Operations"
    assert_includes prompt, "normal operational expectations"
    assert_includes prompt, "Session spawning"
    assert_includes prompt, "start running within about a minute"
    assert_includes prompt, "Transient failure recovery"
    assert_includes prompt, "Stuck sessions"
    assert_includes prompt, "Process shutdown"
    assert_includes prompt, "no extended grace period"
  end

  test "includes session lifecycle management principle" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "### 7. Session Lifecycle Management"
    assert_includes prompt, "Zimmer homepage shows sessions in \"needs_input\" state as the user's action queue"
    assert_includes prompt, "Do NOT archive a session if it contains an important message"
    assert_includes prompt, "don't leave sessions in \"needs_input\" if there's genuinely nothing for the user to do"
    assert_includes prompt, "goal or skill-level archiving instructions, follow those"
  end

  test "includes always-link-PRs-and-sessions principle" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "### 8. Always Link PRs and Zimmer Sessions"
    assert_includes prompt, "https://github.com/tadasant/zimmer-catalog/pull/",
      "expected the principle to show an example GitHub PR URL"
    assert_includes prompt, "https://zimmer.example.com/sessions/",
      "expected the principle to show an example Zimmer session URL"
    assert_includes prompt, "every time",
      "expected the principle to emphasize linking on every mention, not just first"
    assert_includes prompt, "mobile",
      "expected the rationale to mention mobile users (the motivating context)"
  end

  test "operating principles appear before guidelines in prompt" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    principles_index = prompt.index("## Operating Principles")
    guidelines_index = prompt.index("## Zimmer Guidelines")

    assert principles_index < guidelines_index,
      "Operating Principles should appear before Zimmer Guidelines"
  end

  test "includes guidelines section" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "## Zimmer Guidelines"
    assert_includes prompt, "session may have a goal"
    assert_includes prompt, "Your work is being tracked"
    assert_includes prompt, "CLAUDE.md instructions"
  end

  test "includes inline planning guideline that prohibits EnterPlanMode" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "NEVER use the `EnterPlanMode` or `ExitPlanMode` tools"
    assert_includes prompt, "Always plan inline"
    assert_includes prompt, "plan mode causes sessions to get stuck"
  end

  test "includes guideline prohibiting /schedule follow-up offers" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "Don't offer `/schedule` follow-ups",
      "expected the prompt to override the base Claude Code prompt's /schedule offer"
    assert_includes prompt, "overrides the base Claude Code prompt",
      "agent should know this overrides the base prompt's instruction"
  end

  test "/schedule guideline points at the Zimmer-native wake tools as alternatives" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "wake_me_up_when_session_changes_state",
      "expected wake_me_up_when_session_changes_state to be surfaced as an alternative to /schedule"
    assert_includes prompt, "wake_me_up_later",
      "expected wake_me_up_later to be surfaced as an alternative to /schedule"
    assert_includes prompt, "Spawn a fresh Zimmer session",
      "expected spawning a fresh Zimmer session to be surfaced as an alternative to /schedule"
    assert_includes prompt, "@latest",
      "expected the @latest MCP refresh insight to be surfaced so agents understand why a fresh session works"
  end

  test "includes remote filesystem MCP server guideline" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "remote filesystem MCP server is available, use it to share files with the user"
    assert_includes prompt, "see the Remote Execution Environment principle"
  end

  test "includes autonomy over clarifying questions guideline" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "avoid asking the user clarifying questions"
    assert_includes prompt, "make your best assumptions and prioritize autonomy"
  end

  test "names AskUserQuestion as blocked alongside the clarifying-questions guideline" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "`AskUserQuestion` tool is blocked at the tool layer",
      "expected the prompt to explicitly call out the now-blocked AskUserQuestion tool"
    assert_includes prompt, "interactive prompts stall autonomous sessions",
      "expected the prompt to explain why AskUserQuestion is blocked"
  end

  test "includes autonomous problem-solving guidance" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "## Autonomous Problem-Solving"
    assert_includes prompt, "figuring things out autonomously"
    assert_includes prompt, "missing secret, credential, or configuration"
    assert_includes prompt, "request user assistance promptly"
    # Verify the session URL is included in the blocker notification guidance
    assert_includes prompt, "user can see your session progress at http://localhost:3000/sessions/#{@session.id}"
  end

  test "handles session without optional fields" do
    # Note: branch is a required field in the Session model, so we can't set it to nil
    # We test other optional fields being nil
    @session.update!(
      session_id: nil,
      repository_name: nil,
      mcp_servers: []
    )

    # Should not raise
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "# Zimmer Context"
    # Session ID and URL are always present (using database ID)
    assert_includes prompt, "Session ID: #{@session.id}"
    assert_includes prompt, "Session URL:"
    refute_includes prompt, "Repository:"
    refute_includes prompt, "## MCP Servers"
  end

  test "includes dynamic skills and MCP servers guidance" do
    prompt = OrchestratorSystemPromptBuilder.build(session: @session)

    assert_includes prompt, "## Dynamic Skills and MCP Servers"
    assert_includes prompt, ".claude/skills/"
    assert_includes prompt, "copied from a centralized catalog"
    assert_includes prompt, ".mcp.json"
    assert_includes prompt, "Treat both as read-only runtime resources"
  end

  test "class method delegates to instance" do
    prompt1 = OrchestratorSystemPromptBuilder.build(session: @session, clone_path: "/test")

    builder = OrchestratorSystemPromptBuilder.new(session: @session, clone_path: "/test")
    prompt2 = builder.build

    assert_equal prompt1, prompt2
  end

  # ===== PER-RUNTIME SNAPSHOT TESTS =====
  #
  # The orchestrator system prompt is composed of runtime-agnostic sections plus
  # a per-runtime contribution (RuntimePromptContribution). These tests pin the
  # Claude output to a checked-in golden fixture so the per-runtime refactor
  # cannot silently change the prompt Claude sessions actually receive.

  GOLDEN_FIXTURE = "claude_orchestrator_system_prompt.txt"

  # A fully-deterministic session matching the values used to generate the
  # golden fixture. Built in-memory (not from a DB fixture) so the prompt is
  # byte-stable regardless of auto-assigned fixture IDs.
  def deterministic_session
    Session.new(
      id: 4242,
      prompt: "test",
      branch: "main",
      repository_name: "tadasant/zimmer-catalog",
      subdirectory: "agents/agent-orchestrator",
      mcp_servers: [ "agent-orchestrator-prod-sessions", "agent-orchestrator-prod-self-session" ],
      agent_runtime: "claude_code"
    )
  end

  test "Claude prompt is byte-identical to the golden snapshot (no runtime specified)" do
    golden = file_fixture(GOLDEN_FIXTURE).read

    prompt = OrchestratorSystemPromptBuilder.build(
      session: deterministic_session,
      clone_path: "/home/rails/clone/path"
    )

    assert_equal golden.bytesize, prompt.bytesize,
      "prompt byte length drifted from the golden snapshot"
    assert_equal golden.b, prompt.b,
      "default (Claude) prompt diverged from the golden snapshot — the per-runtime " \
      "refactor must not change the prompt Claude sessions receive"
  end

  test "explicit claude runtime produces the same byte-identical snapshot" do
    golden = file_fixture(GOLDEN_FIXTURE).read

    prompt = OrchestratorSystemPromptBuilder.build(
      session: deterministic_session,
      clone_path: "/home/rails/clone/path",
      runtime: "claude"
    )

    assert_equal golden.b, prompt.b
  end

  test "codex runtime drops Claude-specific tool guidance" do
    prompt = OrchestratorSystemPromptBuilder.build(
      session: deterministic_session,
      clone_path: "/home/rails/clone/path",
      runtime: "codex"
    )

    # Claude-specific tool guidance refers to tools Codex doesn't have.
    refute_includes prompt, "EnterPlanMode",
      "EnterPlanMode guidance is Claude-specific and should not leak to other runtimes"
    refute_includes prompt, "/schedule",
      "/schedule guidance is Claude-specific and should not leak to other runtimes"
    refute_includes prompt, "AskUserQuestion",
      "AskUserQuestion guidance is Claude-specific and should not leak to other runtimes"
  end

  test "codex runtime still includes the shared Zimmer principles" do
    prompt = OrchestratorSystemPromptBuilder.build(
      session: deterministic_session,
      clone_path: "/home/rails/clone/path",
      runtime: "codex"
    )

    # Runtime-agnostic content must remain for every runtime.
    assert_includes prompt, "## Operating Principles"
    assert_includes prompt, "### 1. Human-Approved Git Changes"
    assert_includes prompt, "## Zimmer Guidelines"
    assert_includes prompt, "avoid asking the user clarifying questions — make your best assumptions and prioritize autonomy."
    assert_includes prompt, "## Autonomous Problem-Solving"
    assert_includes prompt, "## Dynamic Skills and MCP Servers"
  end

  test "codex runtime swaps CLAUDE.md references for AGENTS.md" do
    prompt = OrchestratorSystemPromptBuilder.build(
      session: deterministic_session,
      clone_path: "/home/rails/clone/path",
      runtime: "codex"
    )

    assert_includes prompt, "following any AGENTS.md instructions in the repository"
    assert_includes prompt, "Domain-specific AGENTS.md files may impose stricter scope rules"
    refute_includes prompt, "CLAUDE.md",
      "Codex sessions read project instructions from AGENTS.md, not CLAUDE.md"
  end

  test "codex runtime includes its sandbox guidance and native resource paths" do
    prompt = OrchestratorSystemPromptBuilder.build(
      session: deterministic_session,
      clone_path: "/home/rails/clone/path",
      runtime: "codex"
    )

    assert_includes prompt, "Work within the Codex sandbox"
    assert_includes prompt, ".agents/skills/"
    assert_includes prompt, ".codex/config.toml"
    refute_includes prompt, ".claude/skills/"
  end

  CODEX_GOLDEN_FIXTURE = "codex_orchestrator_system_prompt.txt"

  test "Codex prompt is byte-identical to the golden snapshot" do
    golden = file_fixture(CODEX_GOLDEN_FIXTURE).read

    prompt = OrchestratorSystemPromptBuilder.build(
      session: codex_deterministic_session,
      clone_path: "/home/rails/clone/path",
      runtime: "codex"
    )

    assert_equal golden.bytesize, prompt.bytesize,
      "Codex prompt byte length drifted from the golden snapshot"
    assert_equal golden.b, prompt.b,
      "Codex prompt diverged from the golden snapshot"
  end

  def codex_deterministic_session
    session = deterministic_session
    session.agent_runtime = "codex"
    session
  end
end

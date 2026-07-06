# frozen_string_literal: true

require "test_helper"

# Tests for AgentsMdWriter — the prepare-time step that delivers the orchestrator
# system prompt to disk for runtimes that read it from a file (Codex's AGENTS.md)
# rather than a CLI flag. Exercises the writer directly with an in-memory session
# and the MockFileSystemAdapter, so there is no AIR CLI / Open3 / disk involved.
class AgentsMdWriterTest < ActiveSupport::TestCase
  WORKING_DIR = "/work/dir"
  TARGET = "/work/dir/AGENTS.md"

  # A fully in-memory Codex session (not a DB fixture) so the written content is
  # deterministic regardless of fixture IDs or catalog state.
  def codex_session
    Session.new(
      id: 4242,
      prompt: "test",
      branch: "main",
      repository_name: "tadasant/zimmer-catalog",
      subdirectory: "agents/agent-orchestrator",
      mcp_servers: [ "agent-orchestrator-prod-sessions" ],
      agent_runtime: "codex"
    )
  end

  setup do
    @fs = MockFileSystemAdapter.new
    @writer = AgentsMdWriter.new(
      session: codex_session,
      working_directory: WORKING_DIR,
      file_system: @fs
    )
  end

  test "filename and target_path resolve to AGENTS.md for codex" do
    assert_equal "AGENTS.md", @writer.filename
    assert_equal TARGET, @writer.target_path
  end

  test "fresh write creates AGENTS.md with the AO marker and codex orchestrator context" do
    path = @writer.write!

    assert_equal TARGET, path
    content = @fs.read(TARGET)

    assert content.start_with?(AgentsMdWriter::AO_SECTION_MARKER),
      "fresh write should lead with the AO section marker so re-runs can detect it"
    assert_includes content, "# Agent Orchestrator Context"
    assert_includes content, "## Operating Principles"
    # Codex-flavored: AGENTS.md references, not CLAUDE.md, and no Claude-only tools.
    assert_includes content, "following any AGENTS.md instructions in the repository"
    refute_includes content, "CLAUDE.md"
    refute_includes content, "EnterPlanMode"
    assert content.end_with?("\n"), "written file should end with a trailing newline"
  end

  test "appends below the marker when AGENTS.md already exists, preserving repo content" do
    @fs.write(TARGET, "# Repo AGENTS\n\nProject specific stuff.\n")

    @writer.write!
    content = @fs.read(TARGET)

    assert_includes content, "# Repo AGENTS"
    assert_includes content, "Project specific stuff."
    assert_includes content, "# Agent Orchestrator Context"
    assert content.index("# Repo AGENTS") < content.index(AgentsMdWriter::AO_SECTION_MARKER),
      "the repo's existing content should remain above the AO-managed section"
  end

  test "is idempotent across repeated prepares" do
    @writer.write!
    first = @fs.read(TARGET)

    @writer.write!
    second = @fs.read(TARGET)

    assert_equal first, second, "a second prepare must not change the file"
    assert_equal 1, second.scan(AgentsMdWriter::AO_SECTION_MARKER).length,
      "the AO marker should appear exactly once"
    assert_equal 1, second.scan("# Agent Orchestrator Context").length,
      "the orchestrator context should be written exactly once"
  end
end

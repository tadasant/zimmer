# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The population this refactor exists for: a session that HAS a clone but has
# never been spawned in, so `metadata["clone_path"]` is set and
# `metadata["working_directory"]` is not.
#
# Every converted call site used to read `metadata&.dig("working_directory")`
# with no fallback, get nil, and take an early-return path guarded by something
# spelled like `return unless working_directory.present?` — which reads as "this
# session has no clone yet" and is wrong for exactly this population. #183 and
# #187 were two instances of that shape, each fixed at its own call site.
#
# These are behaviour assertions, not rename assertions: before the sweep every
# one of them answered nil / [] / false. Session#working_directory answers the
# clone root instead, which is the correct directory for a session whose agent,
# when it runs, will run there.
class SessionDirectoryFallbackTest < ActiveSupport::TestCase
  setup do
    @clone_root = Dir.mktmpdir("session-directory-fallback")
    @session = sessions(:active_session)
    # A clone on disk, and nothing recorded about where an agent was spawned —
    # because none ever was.
    @session.update!(metadata: { "clone_path" => @clone_root })
  end

  teardown do
    FileUtils.remove_entry(@clone_root) if @clone_root && File.directory?(@clone_root)
  end

  test "Session#working_directory answers the clone root, and #clone_root names the other concept" do
    assert_equal @clone_root, @session.working_directory
    assert_equal @clone_root, @session.clone_root
  end

  # The premise every converted call site now rests on — "for a session that has
  # a clone but was never spawned in, the clone root is where its agent will run"
  # — is only true when the session declares no agent-root subdirectory. For one
  # that does, the bare clone root names the PARENT of where its agent runs, and
  # a caller that stats it finds a directory that exists and concludes the
  # session is ready to resume in it. So the fallback derives the answer the same
  # way GitCloneService does at spawn time.
  test "the fallback joins the session's subdirectory when it declares one" do
    @session.update!(subdirectory: "agents/agent-orchestrator")

    assert_equal File.join(@clone_root, "agents/agent-orchestrator"), @session.working_directory
    assert_equal @clone_root, @session.clone_root
  end

  # The join is not a claim that the path is on disk, and callers that stat it
  # must get "no" rather than a directory that happens to exist one level up.
  test "a subdirectory that is not in the tree yields a path that is not on disk" do
    @session.update!(subdirectory: "not-in-this-tree")

    assert_not File.directory?(@session.working_directory)
  end

  # `metadata` is a JSON column, so a non-String clone_path is representable, and
  # this accessor is called from render paths that must not raise over one.
  test "a malformed clone_path is handed back rather than joined" do
    @session.update!(subdirectory: "sub", metadata: { "clone_path" => { "clone_path" => "/tmp/x" } })

    assert_nothing_raised { @session.working_directory }
    assert_equal({ "clone_path" => "/tmp/x" }, @session.working_directory)
  end

  test "the two accessors diverge once a spawn records a working directory" do
    agent_dir = File.join(@clone_root, "agent-root")
    @session.update!(metadata: @session.metadata.merge("working_directory" => agent_dir))

    assert_equal agent_dir, @session.working_directory
    assert_equal @clone_root, @session.clone_root
  end

  test "an empty working_directory string does not shadow the clone root" do
    @session.update!(metadata: @session.metadata.merge("working_directory" => ""))

    assert_equal @clone_root, @session.working_directory
  end

  test "both accessors answer nil for a session with no clone at all" do
    @session.update!(metadata: {})

    assert_nil @session.working_directory
    assert_nil @session.clone_root
  end

  # The live example: the OAuth probe's guard. A session holding a clone it has
  # never been spawned in used to get `[]` from here — "nothing needs
  # authorizing" — because the guard read as "no clone to check tokens against".
  # The page and the spawn gate then disagreed about which servers were ready.
  test "McpOauthProbe checks credentials for a session with a clone it was never spawned in" do
    @session.stubs(:user_selected_mcp_servers).returns([ "notion" ])

    injector = mock("injector")
    injector.expects(:check_credentials_status).with().returns({}).at_least_once
    McpOauthCredentialInjector.expects(:new).with(@session, working_directory: @clone_root).returns(injector)

    assert_empty McpOauthProbe.new(@session).servers_needing_oauth
  end

  # The transcript poller: a nil here logged "No working_directory found" at
  # ERROR and returned, so the session's transcript never got read.
  test "TranscriptPollerService resolves a transcript directory for such a session" do
    poller = TranscriptPollerService.new(@session, file_system: MockFileSystemAdapter.new)

    assert_not_nil poller.send(:get_transcript_directory)
  end

  # The health monitor's retry gate: false here meant the operator's Retry click
  # was refused for a session whose clone is right there on disk.
  test "HealthMonitorService considers such a session retryable" do
    @session.update!(session_id: SecureRandom.uuid)

    assert HealthMonitorService.new.send(:can_retry_session?, @session)
  end

  # The clipboard on the session page used to read a third metadata key,
  # `full_clone_path`, whose value was always identical to `working_directory`.
  # It now asks the accessor, which answers the same string for a spawned session
  # and the clone root for this one.
  test "the session metadata partial's copy button carries the accessor's answer" do
    @session.update!(metadata: @session.metadata.merge("agent_root_key" => "zimmer"))

    rendered = ApplicationController.render(
      partial: "sessions/session_metadata",
      locals: { agent_session: @session }
    )

    assert_includes rendered, %(data-clipboard-value="#{@clone_root}")
  end
end

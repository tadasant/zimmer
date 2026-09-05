require "test_helper"
require "mocha/minitest"

# Companion to AtomicJsonMetadataTest, which pins the CONCERN. This file pins the
# CALL SITES: #70 is not "does the merge helper work" — that shipped in #260 — it is
# "does every writer to the row use it". Atomicity is a property of every writer to
# a row, not of one key, so a single surviving whole-column writer re-opens the hazard
# for keys it never names.
#
# Every test here is the same scenario. Another writer sets a key on the row; the site
# under test then writes from an object loaded before that happened. A whole-column
# read-modify-write erases the other writer's key. Each test asserts BOTH halves — the
# concurrent key survived AND the site's own keys landed — because a conversion that
# quietly writes nothing would pass the first assertion on its own.
#
# `interrupt_terminate_pid` and `pending_follow_up_prompt` are used as the concurrent
# keys throughout, because those are the two the consequence is stated in: a lost
# `pending_follow_up_prompt` is a lost user prompt, and a lost `interrupt_terminate_pid`
# is a "Send now" that terminates nothing.
class MetadataCallSiteAtomicityTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  CONCURRENT_KEY = "interrupt_terminate_pid"
  CONCURRENT_VALUE = 4242

  setup do
    Turbo::StreamsChannel.stubs(:broadcast_append_to)
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    Turbo::StreamsChannel.stubs(:broadcast_remove_to)
  end

  # A second connection-level writer setting a key this session's in-memory copy has
  # never seen. Returns nothing: the point is that the object under test does not know.
  def concurrent_write!(session, key: CONCURRENT_KEY, value: CONCURRENT_VALUE)
    Session.find(session.id).merge_metadata!(key => value)
  end

  def assert_concurrent_key_survived(session, key: CONCURRENT_KEY, value: CONCURRENT_VALUE)
    assert_equal value, session.reload.metadata[key],
      "the concurrently-written #{key} was erased — this call site is still a whole-column write"
  end

  # === TranscriptPollerService: the hottest writer in the app ===================

  # The batch that carries `transcript`, the metadata and `last_timeline_entry_at`.
  # It runs on every poll of a live turn, which is what makes it the site the issue
  # names first.
  #
  # The poller reloads immediately before the write. That NARROWS the window and does
  # not close it (AtomicJsonMetadata's own header says so), so the reload is stubbed
  # out here to place the interfering write inside the window deterministically —
  # a threaded test of a sub-millisecond window would not be reproducible.
  test "the poller's transcript batch keeps a key written between its reload and its write" do
    session = sessions(:running)
    session.update!(metadata: { "working_directory" => "/tmp/test-clone" }, transcript: nil)

    fs = MockFileSystemAdapter.new
    fs.stubs(:directory?).returns(true)
    fs.stubs(:glob).returns([ "/transcript/#{session.session_id}.jsonl" ])
    fs.stubs(:mtime).returns(Time.current)
    fs.stubs(:read).returns('{"type":"user","message":{"role":"user","content":"Hello"}}')

    concurrent_write!(session)
    session.stubs(:reload).returns(session)

    assert TranscriptPollerService.new(session, file_system: fs).poll_and_broadcast

    assert_concurrent_key_survived(Session.find(session.id))
    assert_equal 1, Session.find(session.id).metadata["broadcast_message_count"],
      "the poller's own key must still land"
  end

  # The metadata-only path taken while the runtime has not created its transcript
  # directory yet. `reload` stubbed for the reason the batch above gives: this
  # write reloaded first too, so the window to place the interfering write in is
  # the one between that read and the UPDATE.
  test "the poller's waiting-for-directory flag keeps a concurrently written key" do
    session = sessions(:running)
    session.update!(metadata: { "working_directory" => "/tmp/test-clone" })

    fs = MockFileSystemAdapter.new
    fs.stubs(:directory?).returns(false)

    concurrent_write!(session)
    session.stubs(:reload).returns(session)

    assert_nil TranscriptPollerService.new(session, file_system: fs).poll_and_broadcast

    assert_concurrent_key_survived(Session.find(session.id))
    assert_equal true, Session.find(session.id).metadata["transcript_waiting_logged"]
  end

  # === SessionStateMachine's AASM callbacks ====================================

  test "clearing paused_by on resume keeps a key written since the object was loaded" do
    session = sessions(:needs_input)
    session.update!(metadata: { "paused_by" => "user" })

    concurrent_write!(session)
    session.resume!

    assert_concurrent_key_survived(session)
    assert_nil session.reload.metadata["paused_by"], "paused_by must still be cleared"
  end

  test "the needs_input counter keeps a custom_metadata key written by another writer" do
    session = sessions(:running)
    session.update!(custom_metadata: {})
    Session.find(session.id).merge_custom_metadata!("github_pull_request_urls" => [ "https://github.com/o/r/pull/1" ])

    session.pause!

    reloaded = session.reload
    assert_equal [ "https://github.com/o/r/pull/1" ], reloaded.custom_metadata["github_pull_request_urls"],
      "the concurrently-written PR list was erased by the needs_input counter"
    assert_equal 1, reloaded.custom_metadata["needs_input_count"]
  end

  test "executing a pending sleep keeps a key written since the object was loaded" do
    session = sessions(:needs_input)
    session.update!(metadata: { "pending_sleep" => true })

    concurrent_write!(session)
    session.send(:execute_pending_sleep)

    assert_concurrent_key_survived(session)
    assert_nil session.reload.metadata["pending_sleep"]
    assert session.reload.waiting?
  end

  test "the lost-elicitation marker keeps a key written since the object was loaded" do
    session = sessions(:running)
    session.update!(metadata: {})

    concurrent_write!(session)
    assert session.record_lost_elicitation!(reason: "expired", broadcast: false)

    assert_concurrent_key_survived(session)
    assert_equal "expired", session.reload.metadata.dig("lost_elicitation", "reason")
  end

  # === The catalog-selection path ==============================================

  test "recording an explicitly-empty MCP list keeps a key written since the object was loaded" do
    session = sessions(:needs_input)
    session.update!(metadata: {}, mcp_servers: [])

    concurrent_write!(session)
    result = Sessions::UpdateCatalogSelection.call(
      session: session, attribute: :mcp_servers, values: [], actor: :api
    )

    assert result.ok, result.error
    assert_concurrent_key_survived(session)
    assert_equal true, session.reload.metadata[Session::EXPLICIT_EMPTY_MCP_SERVERS_KEY]
  end

  test "naming a non-empty MCP list drops only the explicit-empty marker" do
    session = sessions(:needs_input)
    session.update!(metadata: { Session::EXPLICIT_EMPTY_MCP_SERVERS_KEY => true })

    concurrent_write!(session)
    result = Sessions::UpdateCatalogSelection.call(
      session: session, attribute: :mcp_servers, values: [ "playwright-custom" ], actor: :api
    )
    assert result.ok, result.error

    assert_concurrent_key_survived(session)
    assert_nil session.reload.metadata[Session::EXPLICIT_EMPTY_MCP_SERVERS_KEY],
      "naming a list must retire the explicit-empty marker"
    assert_equal [ "playwright-custom" ], session.mcp_servers
  end

  # === Jobs ====================================================================

  test "the drain attempt counter keeps a key written since the object was loaded" do
    session = sessions(:needs_input)
    session.update!(metadata: {})
    job = EnqueuedMessageDrainJob.new

    concurrent_write!(session)
    assert_equal 1, job.send(:record_attempt, session)

    assert_concurrent_key_survived(session)
    assert_equal 1, session.reload.metadata[EnqueuedMessageDrainJob::ATTEMPTS_KEY]

    job.send(:clear_attempts, session.reload)
    assert_concurrent_key_survived(session)
    assert_nil session.reload.metadata[EnqueuedMessageDrainJob::ATTEMPTS_KEY]
  end

  test "applying a generated title keeps a key written since the object was loaded" do
    session = sessions(:needs_input)
    session.update!(metadata: { "auto_generated_title" => true })

    concurrent_write!(session)
    SessionTitleJob.new.send(:apply_title, session, "A better title", "inference")

    assert_concurrent_key_survived(session)
    reloaded = session.reload
    assert_equal "A better title", reloaded.title
    assert_nil reloaded.metadata["auto_generated_title"]
  end

  # === Services ================================================================

  test "the unarchive clone-path write keeps a key written since the object was loaded" do
    session = sessions(:archived)
    session.update!(metadata: { "failure_reason" => "spawn_failed", "process_pid" => 99 })

    concurrent_write!(session)
    service = UnarchiveSessionService.new(session: session)
    assert service.send(:update_session_metadata, clone_path: "/tmp/c", working_directory: "/tmp/c/sub")

    assert_concurrent_key_survived(session)
    reloaded = session.reload
    assert_equal "/tmp/c", reloaded.metadata["clone_path"]
    assert_equal "/tmp/c/sub", reloaded.metadata["working_directory"]
    assert_nil reloaded.metadata["failure_reason"], "stale retry keys must still be dropped"
    assert_nil reloaded.metadata["process_pid"]
  end

  # Like the poller, this one re-reads the row before writing. The reload is stubbed
  # out for the same reason and with the same meaning: it narrows the window, it does
  # not close it, and the test puts the interfering write inside it.
  test "flagging a running session for deferred sleep keeps a concurrently written key" do
    session = sessions(:running)
    session.update!(metadata: {})
    service = AuthOutageParkService.new(session)

    concurrent_write!(session)
    session.stubs(:reload).returns(session)

    service.send(:sleep_session!)

    assert_concurrent_key_survived(Session.find(session.id))
    assert_equal true, Session.find(session.id).metadata["pending_sleep"]
  end

  test "the MCP pause action keeps a key written since the object was loaded" do
    session = sessions(:running)
    session.update!(metadata: {})

    concurrent_write!(session)
    Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions")).send(:pause, session)

    assert_concurrent_key_survived(session)
    assert_equal "user", session.reload.metadata["paused_by"]
  end

  test "clearing a spot hold keeps a key written since the object was loaded" do
    session = sessions(:waiting)
    session.update!(metadata: SpotSessionHold::METADATA_KEYS.index_with { |_k| "x" })

    concurrent_write!(session)
    SpotSessionHold.clear(session)

    assert_concurrent_key_survived(session)
    reloaded = session.reload
    SpotSessionHold::METADATA_KEYS.each do |key|
      assert_nil reloaded.metadata[key], "#{key} must still be cleared"
    end
  end

  test "recording a terminal API error line keeps a key written since the object was loaded" do
    session = sessions(:running)
    session.update!(metadata: {})

    concurrent_write!(session)
    ProcessLifecycleManager.new(session: session).send(
      :remember_terminal_api_error_line, 42
    )

    assert_concurrent_key_survived(session)
    assert_equal 42, session.reload.metadata[ProcessLifecycleManager::TERMINAL_API_ERROR_LINE_KEY]
  end

  # This one re-finds the row itself, so the stale object is the one its own lookup
  # returns — the window is between that SELECT and the UPDATE.
  test "recording spawn credentials keeps a key written since its own lookup ran" do
    session = sessions(:running)
    session.update!(metadata: {})
    stale = Session.find(session.id)

    concurrent_write!(session)
    Session.stubs(:find_by).with(id: session.id).returns(stale)

    AuthRecoveryCoordinator.record_spawn_credentials!(
      session_id: session.id, account: nil, session_scoped: false
    )

    assert_concurrent_key_survived(session)
    assert_equal false, session.reload.metadata[AuthRecoveryCoordinator::CREDENTIAL_MODE_KEY]
  end

  # The model helper the catalog surfaces call, on its own: the persisted twin of
  # #record_explicit_mcp_servers.
  test "recording an explicit MCP list on a persisted session keeps a concurrent key" do
    session = sessions(:needs_input)
    session.update!(metadata: {})
    stale = Session.find(session.id)

    concurrent_write!(session)
    stale.record_explicit_mcp_servers!([])

    assert_concurrent_key_survived(session)
    assert_equal true, session.reload.metadata[Session::EXPLICIT_EMPTY_MCP_SERVERS_KEY]
  end

  # AgentSessionJob is the file the issue counts most of the residual in. This is one
  # of its 26 converted sites, chosen because it is reachable without a live process.
  test "the MCP retry park keeps a key written since the object was loaded" do
    session = sessions(:running)
    session.update!(metadata: {})
    job = AgentSessionJob.new
    job.stubs(:remove_running_loader)
    log_buffer = mock("log_buffer")
    log_buffer.stubs(:add)
    log_buffer.stubs(:flush)

    concurrent_write!(session)
    perform_enqueued_jobs(only: ->(_j) { false }) do
      job.send(:schedule_mcp_retry, session, [ { "name" => "github" } ], 0, log_buffer)
    end

    assert_concurrent_key_survived(session)
    reloaded = session.reload
    assert_equal "mcp_retry", reloaded.metadata["paused_by"]
    assert_equal [ { "name" => "github" } ], reloaded.metadata["mcp_failed_servers"]
  end
end

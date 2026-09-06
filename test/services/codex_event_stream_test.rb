# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CodexEventStreamTest < ActiveSupport::TestCase
  # Captured verbatim from `codex exec --json --dangerously-bypass-approvals-and-sandbox`
  # on codex-cli 0.146.0 (the version in the Zimmer base image), truncated in the
  # middle. Nothing here is invented: this is the shape the adapter now redirects
  # into codex_events.jsonl, and `thread.started` really is the first line — it is
  # printed before the model is contacted, which is why this run still names the
  # thread despite failing on a 401.
  REAL_STREAM = <<~JSONL
    {"type":"thread.started","thread_id":"01a07412-4d9a-78f0-aad9-2cde1bf7586e"}
    {"type":"turn.started"}
    {"type":"error","message":"Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: wss://api.openai.com/v1/responses, cf-ray: a3694825285fd15b-EWR)"}
    {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Falling back from WebSockets to HTTPS transport."}}
    {"type":"error","message":"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses"}
    {"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses"}}
  JSONL

  REAL_THREAD_ID = "01a07412-4d9a-78f0-aad9-2cde1bf7586e"

  setup do
    @working_dir = "/home/rails/.zimmer/clones/repo-main-abc"
    @file_system = MockFileSystemAdapter.new
    @stream = CodexEventStream.new(working_directory: @working_dir, file_system: @file_system)
    @path = File.join(@working_dir, "codex_events.jsonl")
  end

  # === path / availability ===

  test "path is the adapter's event log inside the working directory" do
    assert_equal @path, @stream.path
    assert_equal CodexRuntimeAdapter.event_log_path(@working_dir), @stream.path
  end

  test "a stream without a working directory has no path and is not available" do
    stream = CodexEventStream.new(working_directory: nil, file_system: @file_system)
    assert_nil stream.path
    refute_predicate stream, :available?
    assert_nil stream.thread_id
    assert_empty stream.events
  end

  test "a stream whose log has not been created yet is not available" do
    refute_predicate @stream, :available?
    assert_nil @stream.thread_id
    assert_empty @stream.events
  end

  # === thread_id: the whole point of consuming the stream ===

  test "thread_id is read from the real Codex event stream" do
    @file_system.write(@path, REAL_STREAM)

    assert_predicate @stream, :available?
    assert_equal REAL_THREAD_ID, @stream.thread_id
  end

  test "thread_id is the UUID that names the rollout codex exec resume targets" do
    # The invariant this whole change rests on, verified against codex-cli
    # 0.146.0: the stdout thread_id, the rollout filename UUID and the rollout's
    # own session_meta id are one value.
    @file_system.write(@path, REAL_STREAM)
    rollout_filename = "rollout-2026-09-06T00-15-51-#{REAL_THREAD_ID}.jsonl"
    session_meta = JSON.parse(
      %({"type":"session_meta","payload":{"session_id":"#{REAL_THREAD_ID}","id":"#{REAL_THREAD_ID}"}})
    )

    assert rollout_filename.end_with?("-#{@stream.thread_id}.jsonl")
    assert_equal @stream.thread_id, session_meta.dig("payload", "id")
  end

  test "thread_id is nil while the log exists but has been truncated for a new spawn" do
    # The adapter opens the log with "w" on every spawn. Between that truncation
    # and Codex printing thread.started the file is empty, and the answer must be
    # "not knowable yet" rather than a stale id.
    @file_system.write(@path, "")

    assert_nil @stream.thread_id
  end

  test "thread_id is nil while the first line is still half-flushed" do
    @file_system.write(@path, %({"type":"thread.st)) # no newline, no closing brace

    assert_nil @stream.thread_id
  end

  test "thread_id skips leading lines that carry no thread id" do
    @file_system.write(@path, <<~JSONL)
      {"type":"turn.started"}
      {"type":"thread.started","thread_id":"#{REAL_THREAD_ID}"}
    JSONL

    assert_equal REAL_THREAD_ID, @stream.thread_id
  end

  test "thread_id refuses a value that is not shaped like a UUID" do
    # session_id is uniquely indexed and is what every later resume targets, so a
    # non-UUID is dropped rather than persisted.
    @file_system.write(@path, %({"type":"thread.started","thread_id":"not-a-uuid"}\n))

    assert_nil @stream.thread_id
  end

  test "thread_id refuses a non-string thread id" do
    @file_system.write(@path, %({"type":"thread.started","thread_id":12345}\n))

    assert_nil @stream.thread_id
  end

  test "thread_id gives up after the scan limit rather than reading a whole turn" do
    # A stream that never names a thread must cost a bounded read: the poller
    # asks on every cycle and the log grows for the life of the turn.
    filler = ([ %({"type":"item.completed","item":{"id":"x"}}) ] * 200).join("\n")
    @file_system.write(@path, "#{filler}\n" + %({"type":"thread.started","thread_id":"#{REAL_THREAD_ID}"}\n))

    assert_nil @stream.thread_id,
      "thread_id must stop at THREAD_ID_SCAN_LIMIT lines, not scan the whole log"
  end

  test "thread_id is found at the edge of the scan limit" do
    filler = ([ %({"type":"turn.started"}) ] * (CodexEventStream::THREAD_ID_SCAN_LIMIT - 1)).join("\n")
    @file_system.write(@path, "#{filler}\n" + %({"type":"thread.started","thread_id":"#{REAL_THREAD_ID}"}\n))

    assert_equal REAL_THREAD_ID, @stream.thread_id
  end

  test "thread_id survives a log that cannot be read" do
    @file_system.write(@path, REAL_STREAM)
    @file_system.stubs(:each_line).raises(Errno::EACCES, "denied")

    assert_nil @stream.thread_id
  end

  # === events ===

  test "events parses every record of the real stream in order" do
    @file_system.write(@path, REAL_STREAM)

    events = @stream.events
    assert_equal 6, events.length
    assert_equal %w[thread.started turn.started error item.completed error turn.failed],
      events.map { |e| e["type"] }
    assert_equal REAL_THREAD_ID, events.first["thread_id"]
    assert_equal "item_0", events[3].dig("item", "id")
    assert_match(/401 Unauthorized/, events.last.dig("error", "message"))
  end

  test "events drops a half-flushed final line without dropping the rest" do
    @file_system.write(@path, REAL_STREAM + %({"type":"turn.comp))

    assert_equal 6, @stream.events.length
  end

  test "events drops blank lines and non-object records" do
    @file_system.write(@path, "\n[1,2,3]\n" + %({"type":"turn.started"}\n) + "\n")

    assert_equal [ { "type" => "turn.started" } ], @stream.events
  end
end

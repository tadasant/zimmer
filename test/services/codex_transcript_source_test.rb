# frozen_string_literal: true

require "test_helper"
require "zstd-ruby"

class CodexTranscriptSourceTest < ActiveSupport::TestCase
  setup do
    @original_codex_home = ENV["CODEX_HOME"]
    # Default the suite to the unset-CODEX_HOME case so path expectations are
    # deterministic; individual tests opt into an override where relevant.
    ENV.delete("CODEX_HOME")
    @session = sessions(:running)
    @file_system = MockFileSystemAdapter.new
    @source = CodexTranscriptSource.new(file_system: @file_system)
    @sessions_dir = File.join(Dir.home, ".codex", "sessions")
    @day_dir = File.join(@sessions_dir, "2026", "05", "29")
  end

  teardown do
    if @original_codex_home.nil?
      ENV.delete("CODEX_HOME")
    else
      ENV["CODEX_HOME"] = @original_codex_home
    end
  end

  # === resume_transcript_path ===

  test "resume_transcript_path returns nil (Codex opts out of single-file restore)" do
    # Codex rollouts are date-partitioned, UUID-named, and may be Zstandard-
    # compressed, so Zimmer cannot restore them by writing stored bytes to one path.
    # A nil result tells AgentSessionJob to skip the restore for Codex sessions.
    @session.update!(session_id: SecureRandom.uuid)
    assert_nil @source.resume_transcript_path(session: @session, working_directory: "/tmp/clone")
  end

  # === transcript_directory ===

  test "transcript_directory returns the Codex sessions base directory" do
    expected = File.join(Dir.home, ".codex", "sessions")
    assert_equal expected, @source.transcript_directory
  end

  test "transcript_directory honors the CODEX_HOME env override" do
    ENV["CODEX_HOME"] = "/srv/codex-state"
    assert_equal "/srv/codex-state/sessions", @source.transcript_directory
  end

  test "transcript_directory falls back to ~/.codex/sessions when CODEX_HOME is unset" do
    ENV.delete("CODEX_HOME")
    assert_equal File.join(Dir.home, ".codex", "sessions"), @source.transcript_directory
  end

  test "transcript_directory ignores the working_directory" do
    assert_equal @source.transcript_directory,
      @source.transcript_directory(working_directory: "/some/clone/path")
  end

  # === locate / find_main_transcript ===

  test "locate returns nil when the sessions directory does not exist" do
    assert_nil @source.locate(session: @session)
  end

  test "locate returns the rollout whose filename carries the session id" do
    @session.update!(session_id: "uuid-codex-1")
    @file_system.mkdir_p(@day_dir)
    main = "#{@day_dir}/rollout-2026-05-29T21-39-10-uuid-codex-1.jsonl"
    @file_system.write(main, '{"type":"session_meta"}')
    @file_system.write("#{@day_dir}/rollout-2026-05-29T20-00-00-other-uuid.jsonl", "{}")

    assert_equal main, @source.locate(session: @session)
  end

  test "find_main_transcript prefers the most recently modified variant for a session" do
    @session.update!(session_id: "uuid-codex-2")
    @file_system.mkdir_p(@day_dir)
    compressed = "#{@day_dir}/rollout-2026-05-29T10-00-00-uuid-codex-2.jsonl.zst"
    live = "#{@day_dir}/rollout-2026-05-29T11-00-00-uuid-codex-2.jsonl"
    @file_system.binwrite(compressed, "irrelevant")
    @file_system.write(live, "{}")
    @file_system.set_mtime(compressed, 1.hour.ago)
    @file_system.set_mtime(live, Time.current)

    assert_equal live, @source.find_main_transcript(transcript_directory: @sessions_dir, session: @session)
  end

  test "find_main_transcript matches a compressed .jsonl.zst rollout by session id" do
    @session.update!(session_id: "uuid-codex-3")
    @file_system.mkdir_p(@day_dir)
    compressed = "#{@day_dir}/rollout-2026-05-29T10-00-00-uuid-codex-3.jsonl.zst"
    @file_system.binwrite(compressed, "irrelevant")

    assert_equal compressed, @source.find_main_transcript(transcript_directory: @sessions_dir, session: @session)
  end

  test "find_main_transcript falls back to the most recent rollout when working directory is unknown" do
    # No working_directory in metadata (the `running` fixture has none) means we
    # cannot disambiguate by clone, so the legacy most-recent behavior applies.
    @session.update!(session_id: nil)
    @file_system.mkdir_p(@day_dir)
    older = "#{@day_dir}/rollout-2026-05-29T09-00-00-aaa.jsonl"
    newer = "#{@day_dir}/rollout-2026-05-29T10-00-00-bbb.jsonl"
    @file_system.write(older, "{}")
    @file_system.write(newer, "{}")
    @file_system.set_mtime(older, 2.hours.ago)
    @file_system.set_mtime(newer, Time.current)

    assert_equal newer, @source.find_main_transcript(transcript_directory: @sessions_dir, session: @session)
  end

  # === concurrent-session isolation (regression: cross-session contamination) ===
  #
  # Before a session's own Codex UUID is captured, the stored session_id is the
  # Zimmer-minted placeholder that never matches a rollout filename, so selection
  # falls back to the shared tree. Codex writes every session's rollout into the
  # same $CODEX_HOME tree, so the fallback must NOT cross clone boundaries.

  test "fallback selects the rollout whose recorded cwd matches this session's clone, not a newer foreign one" do
    # This is the exact shape of the production bug: a concurrent session's
    # rollout is the most recently modified file in the shared tree, but it
    # belongs to a different clone. The fallback must pick THIS session's older
    # rollout, never the newer foreign one.
    own_clone = "/home/rails/.zimmer/clones/pulsemcp-main-OWN/agents/agent-roots/token-spend-economics"
    foreign_clone = "/home/rails/.zimmer/clones/pulsemcp-main-FOREIGN/agents/agent-roots/2-prepare"
    @session.update!(session_id: SecureRandom.uuid, metadata: { "working_directory" => own_clone })
    @file_system.mkdir_p(@day_dir)

    own = "#{@day_dir}/rollout-2026-05-29T10-00-00-own-uuid.jsonl"
    foreign = "#{@day_dir}/rollout-2026-05-29T10-00-05-foreign-uuid.jsonl"
    @file_system.write(own, session_meta_line(cwd: own_clone))
    @file_system.write(foreign, session_meta_line(cwd: foreign_clone))
    @file_system.set_mtime(own, 1.minute.ago)
    @file_system.set_mtime(foreign, Time.current) # foreign is newer

    assert_equal own, @source.find_main_transcript(transcript_directory: @sessions_dir, session: @session)
  end

  test "fallback returns nil when only foreign-clone rollouts exist (this session's rollout not written yet)" do
    own_clone = "/home/rails/.zimmer/clones/pulsemcp-main-OWN/agents/agent-roots/token-spend-economics"
    foreign_clone = "/home/rails/.zimmer/clones/pulsemcp-main-FOREIGN/agents/agent-roots/2-prepare"
    @session.update!(session_id: SecureRandom.uuid, metadata: { "working_directory" => own_clone })
    @file_system.mkdir_p(@day_dir)

    foreign = "#{@day_dir}/rollout-2026-05-29T10-00-05-foreign-uuid.jsonl"
    @file_system.write(foreign, session_meta_line(cwd: foreign_clone))
    @file_system.set_mtime(foreign, Time.current)

    assert_nil @source.find_main_transcript(transcript_directory: @sessions_dir, session: @session)
  end

  test "fallback selects the most recent among this session's own rollouts" do
    # Within one clone there can be several rollouts (e.g. resume creates a new
    # file). Among matching-cwd rollouts the most-recently-modified wins.
    own_clone = "/home/rails/.zimmer/clones/pulsemcp-main-OWN/agents/agent-roots/token-spend-economics"
    @session.update!(session_id: SecureRandom.uuid, metadata: { "working_directory" => own_clone })
    @file_system.mkdir_p(@day_dir)

    older = "#{@day_dir}/rollout-2026-05-29T09-00-00-own-a.jsonl"
    newer = "#{@day_dir}/rollout-2026-05-29T10-00-00-own-b.jsonl"
    @file_system.write(older, session_meta_line(cwd: own_clone))
    @file_system.write(newer, session_meta_line(cwd: own_clone))
    @file_system.set_mtime(older, 2.hours.ago)
    @file_system.set_mtime(newer, Time.current)

    assert_equal newer, @source.find_main_transcript(transcript_directory: @sessions_dir, session: @session)
  end

  test "fallback handles a compressed foreign rollout without selecting it" do
    own_clone = "/home/rails/.zimmer/clones/pulsemcp-main-OWN/agents/agent-roots/token-spend-economics"
    foreign_clone = "/home/rails/.zimmer/clones/pulsemcp-main-FOREIGN/agents/agent-roots/2-prepare"
    @session.update!(session_id: SecureRandom.uuid, metadata: { "working_directory" => own_clone })
    @file_system.mkdir_p(@day_dir)

    own = "#{@day_dir}/rollout-2026-05-29T10-00-00-own-uuid.jsonl"
    foreign_zst = "#{@day_dir}/rollout-2026-05-29T10-00-05-foreign-uuid.jsonl.zst"
    @file_system.write(own, session_meta_line(cwd: own_clone))
    @file_system.binwrite(foreign_zst, Zstd.compress(session_meta_line(cwd: foreign_clone)))
    @file_system.set_mtime(own, 1.minute.ago)
    @file_system.set_mtime(foreign_zst, Time.current)

    assert_equal own, @source.find_main_transcript(transcript_directory: @sessions_dir, session: @session)
  end

  test "fallback skips a rollout with an unparseable first line rather than selecting it" do
    # A torn/garbage session_meta line must not cause a candidate to be picked.
    # The newer foreign candidate here is unreadable; selection must still land
    # on this session's own rollout (or nil), never the malformed file.
    own_clone = "/home/rails/.zimmer/clones/pulsemcp-main-OWN/agents/agent-roots/token-spend-economics"
    @session.update!(session_id: SecureRandom.uuid, metadata: { "working_directory" => own_clone })
    @file_system.mkdir_p(@day_dir)

    own = "#{@day_dir}/rollout-2026-05-29T10-00-00-own-uuid.jsonl"
    garbage = "#{@day_dir}/rollout-2026-05-29T10-00-05-garbage-uuid.jsonl"
    @file_system.write(own, session_meta_line(cwd: own_clone))
    @file_system.write(garbage, "this is not json\n")
    @file_system.set_mtime(own, 1.minute.ago)
    @file_system.set_mtime(garbage, Time.current) # garbage is newer

    assert_equal own, @source.find_main_transcript(transcript_directory: @sessions_dir, session: @session)
  end

  # === read (.jsonl and .zst round-trip) ===

  test "read returns the file contents verbatim for an uncompressed .jsonl rollout" do
    path = "#{@day_dir}/rollout-x.jsonl"
    @file_system.write(path, "{\"type\":\"session_meta\"}\n")

    assert_equal "{\"type\":\"session_meta\"}\n", @source.read(path)
  end

  test "read transparently decompresses a .zst rollout" do
    plaintext = File.read(file_fixture("codex_rollout.jsonl").to_s)
    compressed = Zstd.compress(plaintext)
    path = "#{@day_dir}/rollout-compressed.jsonl.zst"
    @file_system.binwrite(path, compressed)

    decoded = @source.read(path)

    assert_equal plaintext, decoded
    assert_equal Encoding::UTF_8, decoded.encoding
  end

  test "read decompresses a large .zst rollout via streaming without corruption" do
    # Build a payload larger than the streaming chunk size to exercise the
    # multi-chunk decode path.
    big_line = ({ "timestamp" => "2026-05-29T21:39:10.000Z", "type" => "response_item",
                  "payload" => { "type" => "message", "role" => "assistant",
                                 "content" => [ { "type" => "output_text", "text" => "x" * 2000 } ] } }).to_json
    plaintext = (([ big_line ] * 500).join("\n") + "\n")
    assert_operator plaintext.bytesize, :>, CodexTranscriptSource::ZST_CHUNK_BYTES
    path = "#{@day_dir}/rollout-big.jsonl.zst"
    @file_system.binwrite(path, Zstd.compress(plaintext))

    assert_equal plaintext, @source.read(path)
  end

  # === parse_events ===

  test "parse_events parses one JSON object per line and drops malformed lines" do
    serialized = "{\"type\":\"session_meta\"}\nnot json\n{\"type\":\"response_item\"}\n"

    assert_equal [ { "type" => "session_meta" }, { "type" => "response_item" } ],
      @source.parse_events(serialized)
  end

  test "parse_events returns empty array for blank content" do
    assert_equal [], @source.parse_events("")
    assert_equal [], @source.parse_events(nil)
  end

  test "parse_events skips a partially-flushed final line without logging at ERROR" do
    # The production false-positive page: a live `codex` process is mid-write on
    # a large rollout record, so the final line has no terminator yet and fails
    # JSON parsing. This is the common live-polling case and must NOT page —
    # the Zimmer error-logs alert fires on any single production .error line.
    partial = "{\"type\":\"session_meta\"}\n{\"type\":\"response_item\",\"payload\":{\"text\":\"abc"
    log = capture_log_output do
      assert_equal [ { "type" => "session_meta" } ], @source.parse_events(partial)
    end

    refute_match(/\bERROR\b/, log, "partial final line must not be logged at ERROR (it pages)")
    refute_match(/\bFATAL\b/, log, "partial final line must not be logged at FATAL")
    assert_match(/partially-flushed final rollout line/, log)
  end

  test "parse_events warns (never errors) on a malformed complete line" do
    # A line that carries its newline terminator but still fails to parse is a
    # genuine data oddity worth surfacing once — at .warn, never .error/page.
    serialized = "{\"type\":\"session_meta\"}\nnot json\n{\"type\":\"response_item\"}\n"
    log = capture_log_output do
      assert_equal [ { "type" => "session_meta" }, { "type" => "response_item" } ],
        @source.parse_events(serialized)
    end

    refute_match(/\bERROR\b/, log, "malformed complete line must not be logged at ERROR (it pages)")
    assert_match(/Dropping malformed rollout line/, log)
  end

  test "parse_events treats a corrupt unterminated final line as a partial flush" do
    # Deliberate blind spot: a corrupt complete record that is also the final
    # line of a file with no trailing newline is indistinguishable from an
    # in-progress flush, so it lands in the benign .info branch rather than
    # .warn. Pin that trade-off so a future change can't silently flip it back
    # to .error/paging. (Codex terminates complete records with a newline, so
    # this case is rare; erring toward non-paging is intended.)
    serialized = "{\"type\":\"session_meta\"}\nnot json"
    log = capture_log_output do
      assert_equal [ { "type" => "session_meta" } ], @source.parse_events(serialized)
    end

    refute_match(/\bERROR\b/, log, "corrupt unterminated final line must not page")
    refute_match(/\bFATAL\b/, log)
    assert_match(/partially-flushed final rollout line/, log)
  end

  test "read_events reads and parses the golden rollout fixture" do
    plaintext = File.read(file_fixture("codex_rollout.jsonl").to_s)
    path = "#{@day_dir}/rollout-2026-05-29T21-39-10-uuid.jsonl"
    @file_system.write(path, plaintext)

    events = @source.read_events(path)

    assert_equal "session_meta", events.first["type"]
    assert events.any? { |e| e["type"] == "response_item" }
    assert events.any? { |e| e["type"] == "compacted" }
  end

  # === discover_subagent_files / mcp_log_paths ===

  test "discover_subagent_files always returns an empty array" do
    assert_equal [], @source.discover_subagent_files(working_directory: "/anything")
    assert_equal [], @source.discover_subagent_files(working_directory: nil, session_id: "x")
  end

  test "mcp_log_paths always returns an empty array" do
    assert_equal [], @source.mcp_log_paths(working_directory: "/anything")
    assert_equal [], @source.mcp_log_paths(working_directory: nil)
  end

  private

  # Capture everything written to Rails.logger during the block as a String so
  # tests can assert on log level (e.g. that a benign parse failure never lands
  # at ERROR, which would page the Zimmer error-logs alert).
  def capture_log_output
    original_logger = Rails.logger
    log_output = StringIO.new
    Rails.logger = Logger.new(log_output)
    yield
    log_output.string
  ensure
    Rails.logger = original_logger
  end

  # A Codex rollout's first JSONL record: the `session_meta` line whose payload
  # carries the spawn `cwd` (and `id`). This is what #rollout_cwd reads to scope
  # the fallback to the session's own clone.
  def session_meta_line(cwd:, id: SecureRandom.uuid)
    JSON.generate(
      "timestamp" => "2026-05-29T10:00:00.000Z",
      "type" => "session_meta",
      "payload" => { "id" => id, "cwd" => cwd }
    ) + "\n"
  end
end

# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "json"

class TokenUsageIngestionServiceTest < ActiveSupport::TestCase
  def setup
    @root = Dir.mktmpdir("token_usage_test_")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  # --- helpers ---------------------------------------------------------------

  def write_transcript(dir, filename, lines)
    FileUtils.mkdir_p(File.join(@root, dir))
    File.write(
      File.join(@root, dir, filename),
      lines.map { |l| JSON.generate(l) }.join("\n") + "\n"
    )
  end

  def assistant_line(request_id:, uuid: SecureRandom.uuid, model: "claude-opus-5",
                     input: 10, output: 20, cache_read: 100, cache_creation: 50,
                     ephemeral_5m: 0, ephemeral_1h: 50, sidechain: false, parent: nil,
                     session_id: "sess-uuid", timestamp: "2026-08-15T10:00:00.000Z")
    {
      "type" => "assistant",
      "uuid" => uuid,
      "parentUuid" => parent,
      "requestId" => request_id,
      "sessionId" => session_id,
      "isSidechain" => sidechain,
      "timestamp" => timestamp,
      "message" => {
        "role" => "assistant",
        "model" => model,
        "usage" => {
          "input_tokens" => input,
          "output_tokens" => output,
          "cache_read_input_tokens" => cache_read,
          "cache_creation_input_tokens" => cache_creation,
          "cache_creation" => {
            "ephemeral_5m_input_tokens" => ephemeral_5m,
            "ephemeral_1h_input_tokens" => ephemeral_1h
          },
          "server_tool_use" => { "web_search_requests" => 0, "web_fetch_requests" => 0 }
        }
      }
    }
  end

  def clone_dir(basename = "zimmer-main-1786989710-abcdef12", subdir: "")
    "-home-rails--zimmer-clones-#{basename}#{subdir}"
  end

  def ingest = TokenUsageIngestionService.new(root: @root).call

  # --- the dedup invariant ---------------------------------------------------

  test "counts one row per requestId even when a call spans several assistant lines" do
    # This is the whole ballgame. One API response is written as several
    # assistant lines — a thinking block and a text block — and EVERY line
    # repeats the same usage object. Keying on uuid counts the usage twice.
    shared = { request_id: "req_same", input: 10, output: 20, cache_read: 100, cache_creation: 50 }
    write_transcript(clone_dir, "sess-uuid.jsonl", [
      assistant_line(uuid: "uuid-thinking", **shared),
      assistant_line(uuid: "uuid-text", **shared)
    ])

    result = ingest

    assert_equal 1, result.session_rows, "two lines of one API call must store one row"
    assert_equal 1, SessionTokenUsage.count
    assert_equal 10, SessionTokenUsage.sole.input_tokens
    assert_equal 100, SessionTokenUsage.sole.cache_read_tokens
  end

  test "deduplicates the same requestId across resumed transcript files" do
    # A resumed session replays its whole history into a new file.
    line = assistant_line(request_id: "req_replayed")
    write_transcript(clone_dir, "sess-one.jsonl", [ line ])
    write_transcript(clone_dir, "sess-two.jsonl", [ line ])

    ingest

    assert_equal 1, SessionTokenUsage.count
  end

  test "is idempotent across runs" do
    write_transcript(clone_dir, "sess-uuid.jsonl", [ assistant_line(request_id: "req_a") ])

    assert_equal 1, ingest.session_rows
    assert_equal 0, ingest.session_rows, "re-ingesting stored calls must add nothing"
    assert_equal 1, SessionTokenUsage.count
  end

  # --- what gets skipped -----------------------------------------------------

  test "skips synthetic models, which never reached the API" do
    write_transcript(clone_dir, "sess-uuid.jsonl", [
      assistant_line(request_id: "req_real"),
      assistant_line(request_id: "req_synth", model: "<synthetic>")
    ])

    ingest

    assert_equal 1, SessionTokenUsage.count
    assert_equal "claude-opus-5", SessionTokenUsage.sole.model
  end

  test "skips lines with no requestId rather than inventing a key" do
    line = assistant_line(request_id: "req_x")
    line.delete("requestId")
    write_transcript(clone_dir, "sess-uuid.jsonl", [ line ])

    ingest

    assert_equal 0, SessionTokenUsage.count
  end

  test "skips zero-usage lines and malformed json without failing the file" do
    FileUtils.mkdir_p(File.join(@root, clone_dir))
    File.write(File.join(@root, clone_dir, "sess-uuid.jsonl"), [
      "{ not json at all",
      JSON.generate(assistant_line(request_id: "req_zero", input: 0, output: 0,
                                   cache_read: 0, cache_creation: 0, ephemeral_1h: 0)),
      JSON.generate(assistant_line(request_id: "req_good"))
    ].join("\n"))

    ingest

    assert_equal [ "req_good" ], SessionTokenUsage.pluck(:request_id)
  end

  # --- routing and attribution ----------------------------------------------

  test "derives the agent root from the clone subdirectory" do
    write_transcript(
      clone_dir("tadasant-internal-main-1786987495-885ada2a",
                subdir: "-artifacts-agent-roots-issue-work-gate"),
      "sess-uuid.jsonl", [ assistant_line(request_id: "req_root") ]
    )

    ingest

    assert_equal "issue-work-gate", SessionTokenUsage.sole.agent_root
  end

  test "a clone with no subdirectory takes the repository as its root" do
    write_transcript(clone_dir("zimmer-main-1786989710-abcdef12"),
                     "sess-uuid.jsonl", [ assistant_line(request_id: "req_repo") ])

    ingest

    assert_equal "zimmer", SessionTokenUsage.sole.agent_root
  end

  test "records subagent calls separately from the main thread" do
    write_transcript(clone_dir, "sess-uuid.jsonl", [ assistant_line(request_id: "req_main") ])
    write_transcript(clone_dir, "agent-1.jsonl",
                     [ assistant_line(request_id: "req_sub", sidechain: true) ])

    ingest

    assert_equal 1, SessionTokenUsage.main_thread.count
    assert_equal 1, SessionTokenUsage.subagents.count
  end

  test "routes the cli status probe and headless inference to the ad hoc table" do
    write_transcript("-rails", "probe.jsonl",
                     [ assistant_line(request_id: "req_probe", model: "claude-opus-5") ])
    write_transcript("-tmp-headless-inference-20260815-6-abc123", "hl.jsonl",
                     [ assistant_line(request_id: "req_headless", model: "claude-haiku-4-5") ])

    result = ingest

    assert_equal 0, result.session_rows
    assert_equal 2, result.adhoc_rows
    assert_equal %w[cli_status_probe headless_inference].sort, AdhocTokenUsage.pluck(:source).sort
  end

  test "an unrecognised directory lands in the ad hoc table as unknown" do
    write_transcript("-some-other-place", "x.jsonl", [ assistant_line(request_id: "req_odd") ])

    ingest

    assert_equal "unknown", AdhocTokenUsage.sole.source
  end

  # --- joining back to sessions ---------------------------------------------

  test "attributes a transcript to its session by the runtime session id" do
    session = sessions(:active_session)
    session.update_column(:session_id, "runtime-uuid-1")
    write_transcript(clone_dir, "runtime-uuid-1.jsonl",
                     [ assistant_line(request_id: "req_join", session_id: "runtime-uuid-1") ])

    ingest

    assert_equal session.id, SessionTokenUsage.sole.session_id
  end

  test "attributes a subagent transcript by its clone directory" do
    # agent-*.jsonl carries no key into `sessions`, so the clone directory —
    # which is created per session — is what links it.
    session = sessions(:active_session)
    session.update_column(:metadata, { "clone_path" => "/home/rails/.zimmer/clones/zimmer-main-1786989710-abcdef12" })
    write_transcript(clone_dir, "agent-7.jsonl",
                     [ assistant_line(request_id: "req_sub_join", sidechain: true) ])

    ingest

    assert_equal session.id, SessionTokenUsage.sole.session_id
  end

  test "a forked session does not take its parent's spend" do
    # ForkSessionService copies the source session's transcript verbatim into the
    # FORK's clone directory under a new filename, and the copied lines keep the
    # parent's requestId AND sessionId. Attributing by file would hand the parent's
    # whole pre-fork spend to the fork, and then — first writer wins on request_id —
    # silently drop those rows when the parent's own file was scanned.
    parent = sessions(:active_session)
    parent.update_column(:session_id, "parent-runtime-uuid")
    fork = sessions(:archived)
    fork.update_column(:session_id, "fork-runtime-uuid")
    fork.update_column(:metadata, { "clone_path" => "/home/rails/.zimmer/clones/zimmer-main-1786989710-abcdef12" })

    # The fork's directory, holding a copy of the parent's line plus its own.
    write_transcript(clone_dir, "fork-runtime-uuid.jsonl", [
      assistant_line(request_id: "req_from_parent", session_id: "parent-runtime-uuid"),
      assistant_line(request_id: "req_from_fork", session_id: "fork-runtime-uuid")
    ])

    ingest

    assert_equal parent.id, SessionTokenUsage.find_by(request_id: "req_from_parent").session_id,
      "a line copied from the parent must stay the parent's spend"
    assert_equal fork.id, SessionTokenUsage.find_by(request_id: "req_from_fork").session_id
  end

  test "backfill scratch symlinks do not leave a dead transcript path" do
    write_transcript(clone_dir, "sess-uuid.jsonl", [ assistant_line(request_id: "req_path") ])

    Dir.mktmpdir do |scratch|
      File.symlink(File.join(@root, clone_dir), File.join(scratch, clone_dir))
      TokenUsageIngestionService.new(root: scratch).call
    end

    stored = SessionTokenUsage.sole.transcript_path
    assert File.exist?(stored), "stored transcript_path #{stored} should still resolve"
    assert_not stored.include?("token_usage_test_scratch"), "should not store the scratch path"
  end

  test "stores usage for a transcript with no matching session" do
    write_transcript(clone_dir, "orphan.jsonl", [ assistant_line(request_id: "req_orphan") ])

    ingest

    assert_equal 1, SessionTokenUsage.unattributed.count, "spend that happened is still spend"
  end

  # --- volumes ---------------------------------------------------------------

  test "keeps the cache creation ttl split, which cache pricing depends on" do
    write_transcript(clone_dir, "sess-uuid.jsonl", [
      assistant_line(request_id: "req_ttl", cache_creation: 300, ephemeral_5m: 100, ephemeral_1h: 200)
    ])

    ingest
    row = SessionTokenUsage.sole

    assert_equal 300, row.cache_creation_tokens
    assert_equal 100, row.cache_creation_5m_tokens
    assert_equal 200, row.cache_creation_1h_tokens
  end

  # --- context-feature attribution -------------------------------------------

  test "writes a feature row per detected feature, keyed so re-ingestion is free" do
    goal = "\n\nThe user has indicated the goal for this task is: ship it.\n\n" \
           "Hand back control to the user AS SOON as the goal is satisfied."
    write_transcript(clone_dir, "sess-uuid.jsonl", [
      { "type" => "user", "uuid" => "u1", "parentUuid" => nil, "sessionId" => "sess-uuid",
        "message" => { "role" => "user", "content" => "Do the work.#{goal}" } },
      assistant_line(request_id: "req_1", uuid: "a1", parent: "u1", cache_read: 0, cache_creation: 5_000)
    ])

    result = ingest

    features = TokenUsageFeature.pluck(:feature)
    assert_includes features, "goal"
    assert_includes features, "prompt"
    assert_equal features.length, result.feature_rows

    # Re-running must add nothing: idempotence is what makes a detector added later
    # backfillable over the transcripts still on disk.
    before = TokenUsageFeature.count
    assert_equal 0, ingest.feature_rows
    assert_equal before, TokenUsageFeature.count
  end

  test "feature rows carry the parent's axes so a rollup needs no join" do
    write_transcript(clone_dir, "sess-uuid.jsonl", [
      { "type" => "user", "uuid" => "u1", "parentUuid" => nil, "sessionId" => "sess-uuid",
        "message" => { "role" => "user", "content" => "Do the work." } },
      assistant_line(request_id: "req_1", uuid: "a1", parent: "u1", model: "claude-sonnet-5", cache_read: 0, cache_creation: 5_000)
    ])

    ingest
    row = TokenUsageFeature.first
    parent = SessionTokenUsage.find_by(request_id: row.request_id)

    assert_equal parent.agent_root, row.agent_root
    assert_equal "claude-sonnet-5", row.model
    assert_equal parent.called_at.to_i, row.called_at.to_i
    assert_equal parent.subagent, row.subagent
  end

  test "no feature row outlives the usage row it splits" do
    write_transcript(clone_dir, "sess-uuid.jsonl", [
      { "type" => "user", "uuid" => "u1", "parentUuid" => nil, "sessionId" => "sess-uuid",
        "message" => { "role" => "user", "content" => "Do the work." } },
      assistant_line(request_id: "req_1", uuid: "a1", parent: "u1", cache_read: 0, cache_creation: 5_000)
    ])
    ingest
    assert_operator TokenUsageFeature.count, :>, 0

    SessionTokenUsage.find_by(request_id: "req_1").destroy

    assert_equal 0, TokenUsageFeature.count, "the foreign key cascades"
  end

  test "attribution can be turned off without changing what the usage tables store" do
    write_transcript(clone_dir, "sess-uuid.jsonl", [
      { "type" => "user", "uuid" => "u1", "parentUuid" => nil, "sessionId" => "sess-uuid",
        "message" => { "role" => "user", "content" => "Do the work." } },
      assistant_line(request_id: "req_1", uuid: "a1", parent: "u1")
    ])

    result = TokenUsageIngestionService.new(root: @root, attribute_features: false).call

    assert_equal 1, result.session_rows
    assert_equal 0, result.feature_rows
    assert_equal 0, TokenUsageFeature.count
  end

  test "Zimmer's own claude -p calls get no feature attribution" do
    # The ad hoc population carries none of the context-management machinery this
    # measures, so scanning it for features would only cost time.
    write_transcript("-rails", "probe.jsonl", [ assistant_line(request_id: "req_probe") ])

    result = ingest

    assert_equal 1, result.adhoc_rows
    assert_equal 0, result.feature_rows
  end

  test "only scans files modified since the given time" do
    write_transcript(clone_dir, "old.jsonl", [ assistant_line(request_id: "req_old") ])
    File.utime(3.days.ago.to_time, 3.days.ago.to_time, File.join(@root, clone_dir, "old.jsonl"))
    write_transcript(clone_dir, "new.jsonl", [ assistant_line(request_id: "req_new") ])

    TokenUsageIngestionService.new(root: @root, modified_since: 1.day.ago).call

    assert_equal [ "req_new" ], SessionTokenUsage.pluck(:request_id)
  end
end

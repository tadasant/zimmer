# frozen_string_literal: true

require "test_helper"
require "json"
require "zstd-ruby"

class CodexTokenUsageIngestionServiceTest < ActiveSupport::TestCase
  CWD = "/home/rails/.zimmer/clones/zimmer-main-1786707822-b9f9960e/artifacts/agent-roots/pr-merge-gate"

  setup do
    @root = Dir.mktmpdir("codex-sessions")
  end

  teardown do
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # --- rollout builders ------------------------------------------------------
  #
  # Every shape below is copied from a real production rollout
  # (`~/.codex/sessions/2026/08/14/rollout-…-01a00016-….jsonl`, codex-cli 0.146.0)
  # with the prose stripped out. The envelope is `{timestamp, type, payload}`.

  def session_meta(uuid, cwd: CWD, timestamp: "2026-08-14T11:44:44.566Z")
    { "timestamp" => timestamp, "type" => "session_meta",
      "payload" => { "session_id" => uuid, "id" => uuid, "cwd" => cwd,
                     "originator" => "codex_exec", "cli_version" => "0.146.0",
                     "model_provider" => "openai" } }
  end

  def turn_context(model: "gpt-5.6-terra", cwd: CWD, timestamp: "2026-08-14T11:44:47.597Z")
    { "timestamp" => timestamp, "type" => "turn_context",
      "payload" => { "turn_id" => SecureRandom.uuid, "cwd" => cwd, "model" => model,
                     "approval_policy" => "never" } }
  end

  def thread_settings(model:, timestamp: "2026-08-14T11:44:47.000Z")
    { "timestamp" => timestamp, "type" => "event_msg",
      "payload" => { "type" => "thread_settings_applied",
                     "thread_settings" => { "model" => model, "model_provider_id" => "openai" } } }
  end

  # `total_token_usage` is cumulative for the rollout; `last_token_usage` is this
  # turn. Both are written, because the ingestor choosing between them is the
  # whole point.
  def token_count(timestamp:, input:, cached: 0, cache_write: 0, output: 0,
                  cumulative_input: nil, cumulative_output: nil)
    total = {
      "input_tokens" => cumulative_input || input, "cached_input_tokens" => cached,
      "cache_write_input_tokens" => cache_write, "output_tokens" => cumulative_output || output,
      "reasoning_output_tokens" => 0,
      "total_tokens" => (cumulative_input || input) + (cumulative_output || output)
    }
    last = {
      "input_tokens" => input, "cached_input_tokens" => cached,
      "cache_write_input_tokens" => cache_write, "output_tokens" => output,
      "reasoning_output_tokens" => 0, "total_tokens" => input + output
    }
    { "timestamp" => timestamp, "type" => "event_msg",
      "payload" => { "type" => "token_count",
                     "info" => { "total_token_usage" => total, "last_token_usage" => last,
                                 "model_context_window" => 258_400 } } }
  end

  def agent_message(text = "ok", timestamp: "2026-08-14T11:44:53.000Z")
    { "timestamp" => timestamp, "type" => "event_msg",
      "payload" => { "type" => "agent_message", "message" => text } }
  end

  # Writes a rollout into the date-partitioned tree, under the filename Codex
  # uses. `compressed: true` produces the `.jsonl.zst` a finished rollout becomes.
  def write_rollout(uuid, *events, date: "2026/08/14", stamp: "2026-08-14T11-44-44",
                    compressed: false, mtime: nil)
    dir = File.join(@root, date)
    FileUtils.mkdir_p(dir)
    body = events.map { |e| JSON.generate(e) }.join("\n") + "\n"

    path = File.join(dir, "rollout-#{stamp}-#{uuid}.jsonl")
    if compressed
      path += ".zst"
      File.binwrite(path, Zstd.compress(body))
    else
      File.write(path, body)
    end
    File.utime(mtime.to_time, mtime.to_time, path) if mtime
    path
  end

  def codex_session(uuid:, agent_root: "pr-merge-gate", clone_path: nil, **attrs)
    Session.create!(
      {
        title: "codex session",
        prompt: "do a thing",
        agent_runtime: "codex",
        git_root: "https://github.com/tadasant/zimmer.git",
        branch: "main",
        session_id: uuid,
        metadata: { "agent_root_key" => agent_root, "clone_path" => clone_path }.compact
      }.merge(attrs)
    )
  end

  def ingest(**kwargs) = CodexTokenUsageIngestionService.new(root: @root, **kwargs).call

  # --- what lands ------------------------------------------------------------

  test "writes one row per token_count event, keyed on the rollout uuid and the event timestamp" do
    uuid = SecureRandom.uuid
    session = codex_session(uuid: uuid)
    path = write_rollout(
      uuid,
      session_meta(uuid),
      turn_context,
      token_count(timestamp: "2026-08-14T11:44:54.291Z", input: 45_059, cached: 11_008, output: 184),
      agent_message,
      token_count(timestamp: "2026-08-14T11:45:10.100Z", input: 46_000, cached: 40_000, output: 200,
                  cumulative_input: 91_059, cumulative_output: 384)
    )

    result = ingest

    assert_equal 1, result.files_scanned
    assert_equal 2, result.session_rows
    assert_equal 0, result.skipped_events

    rows = SessionTokenUsage.where(agent_runtime: "codex").order(:called_at).to_a
    assert_equal [ "codex:#{uuid}:2026-08-14T11:44:54.291Z", "codex:#{uuid}:2026-08-14T11:45:10.100Z" ],
                 rows.map(&:request_id)

    first = rows.first
    # `input_tokens` is stored NET of the cached portion: Codex's prompt total
    # INCLUDES its cached part, and Zimmer prices the two at different rates.
    assert_equal 34_051, first.input_tokens
    assert_equal 11_008, first.cache_read_tokens
    assert_equal 184, first.output_tokens
    assert_equal 0, first.cache_creation_tokens
    assert_equal "gpt-5.6-terra", first.model
    assert_equal "codex", first.agent_runtime
    assert_equal uuid, first.runtime_session_id
    assert_equal session.id, first.session_id
    assert_equal "pr-merge-gate", first.agent_root
    assert_equal false, first.subagent
    assert_equal path, first.transcript_path
    assert_equal Time.zone.parse("2026-08-14T11:44:54.291Z"), first.called_at
  end

  # The delta, not the running total — and the assertion is that the two differ,
  # so a future change back to `total_token_usage` fails here rather than in
  # production accounting.
  test "records the turn's delta rather than the cumulative running total" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    write_rollout(
      uuid,
      session_meta(uuid), turn_context,
      token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10),
      token_count(timestamp: "2026-08-14T11:45:54.000Z", input: 120, output: 12,
                  cumulative_input: 220, cumulative_output: 22)
    )

    ingest

    assert_equal [ 100, 120 ], SessionTokenUsage.order(:called_at).pluck(:input_tokens)
    assert_equal 220, SessionTokenUsage.sum(:input_tokens)
  end

  # The reason the delta is the more complete reading, not merely the more
  # convenient one. Across a context compaction Codex leaves the cumulative
  # counter untouched while still reporting the summarization's own tokens as the
  # turn delta — so the running total ends SHORT of the sum of its own deltas.
  test "counts the compaction turn the cumulative counter drops" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    write_rollout(
      uuid,
      session_meta(uuid), turn_context,
      token_count(timestamp: "2026-08-14T11:53:41.395Z", input: 1_000, output: 100),
      # The compaction: `last` reports 300, `total` does not move.
      token_count(timestamp: "2026-08-14T11:54:19.034Z", input: 300, output: 0,
                  cumulative_input: 1_000, cumulative_output: 100),
      { "timestamp" => "2026-08-14T11:54:19.038Z", "type" => "event_msg",
        "payload" => { "type" => "context_compacted" } }
    )

    ingest

    assert_equal 2, SessionTokenUsage.count
    assert_equal 1_300, SessionTokenUsage.sum(:input_tokens),
                 "the compaction's own tokens are real spend the cumulative counter never adds"
  end

  test "skips an event whose volumes are all zero" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    write_rollout(
      uuid, session_meta(uuid), turn_context,
      token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 0, output: 0)
    )

    result = ingest

    assert_equal 0, result.session_rows
    assert_equal 0, SessionTokenUsage.count
  end

  # --- idempotency -----------------------------------------------------------

  # The failure this key exists to prevent is silent and denominated in money, so
  # it is asserted on totals rather than on a row count alone.
  test "re-ingesting the same rollout writes nothing and changes no total" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    write_rollout(
      uuid, session_meta(uuid), turn_context,
      token_count(timestamp: "2026-08-14T11:44:54.291Z", input: 45_059, cached: 11_008, output: 184),
      token_count(timestamp: "2026-08-14T11:45:54.291Z", input: 46_000, cached: 12_000, output: 200,
                  cumulative_input: 91_059, cumulative_output: 384)
    )

    first = ingest
    totals = -> { SessionTokenUsage.pick(Arel.sql("COUNT(*), SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens)")) }
    after_first = totals.call

    second = ingest

    assert_equal 2, first.session_rows
    assert_equal 0, second.session_rows, "a second pass must write no new rows"
    assert_equal after_first, totals.call
  end

  # A rollout is append-only, so re-reading a longer version of the same file
  # must write only the events that were added.
  test "a rollout that grew between sweeps contributes only its new events" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    events = [ session_meta(uuid), turn_context,
               token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10) ]
    write_rollout(uuid, *events)
    ingest

    write_rollout(uuid, *events,
                  token_count(timestamp: "2026-08-14T11:45:54.000Z", input: 120, output: 12,
                              cumulative_input: 220, cumulative_output: 22))
    result = ingest

    assert_equal 1, result.session_rows
    assert_equal 2, SessionTokenUsage.count
    assert_equal 220, SessionTokenUsage.sum(:input_tokens)
  end

  # The key is the event's own timestamp rather than its ordinal position for
  # exactly this reason: a line that failed to parse on one pass and parsed on
  # the next would shift every later ordinal and re-ingest the rest of the
  # rollout as new spend.
  test "a dropped line does not shift the keys of the events after it" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    good = [ session_meta(uuid), turn_context,
             token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10),
             token_count(timestamp: "2026-08-14T11:45:54.000Z", input: 120, output: 12) ]

    # Pass one sees a truncated middle record.
    dir = File.join(@root, "2026/08/14")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "rollout-2026-08-14T11-44-44-#{uuid}.jsonl")
    lines = good.map { |e| JSON.generate(e) }
    File.write(path, ([ lines[0], lines[1], '{"timestamp":"2026-08-14T11:44:54.000Z","type":"event_msg","payl',
                       lines[3] ].join("\n") + "\n"))
    first = ingest

    # Pass two sees the whole thing.
    File.write(path, lines.join("\n") + "\n")
    second = ingest

    assert_equal 1, first.session_rows
    assert_equal 1, second.session_rows, "only the previously unreadable event is new"
    assert_equal 2, SessionTokenUsage.count
  end

  test "two events sharing a millisecond get distinct keys, deterministically" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    write_rollout(
      uuid, session_meta(uuid), turn_context,
      token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10),
      token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 120, output: 12)
    )

    ingest
    keys = SessionTokenUsage.order(:request_id).pluck(:request_id)
    assert_equal [ "codex:#{uuid}:2026-08-14T11:44:54.000Z", "codex:#{uuid}:2026-08-14T11:44:54.000Z#1" ], keys

    assert_equal 0, ingest.session_rows
    assert_equal keys, SessionTokenUsage.order(:request_id).pluck(:request_id)
  end

  # --- compressed rollouts ---------------------------------------------------

  test "reads a finished .jsonl.zst rollout and keys it identically to the uncompressed one" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    events = [ session_meta(uuid), turn_context,
               token_count(timestamp: "2026-08-14T11:44:54.291Z", input: 45_059, cached: 11_008, output: 184) ]
    write_rollout(uuid, *events, compressed: true)

    result = ingest

    assert_equal 1, result.session_rows
    row = SessionTokenUsage.sole
    assert_equal "codex:#{uuid}:2026-08-14T11:44:54.291Z", row.request_id
    assert_equal 34_051, row.input_tokens
    assert row.transcript_path.end_with?(".jsonl.zst")
  end

  # A rollout is compressed in place while the uncompressed copy may still be on
  # disk, and CodexTranscriptSource reads whichever is newer. Ingestion reads
  # both and the key makes the overlap free.
  test "the compressed and uncompressed copies of one rollout do not double-count" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    events = [ session_meta(uuid), turn_context,
               token_count(timestamp: "2026-08-14T11:44:54.291Z", input: 45_059, cached: 11_008, output: 184) ]
    write_rollout(uuid, *events)
    write_rollout(uuid, *events, compressed: true)

    result = ingest

    assert_equal 2, result.files_scanned
    assert_equal 1, SessionTokenUsage.count
  end

  test "a corrupt .zst costs its own file and no other" do
    good_uuid = SecureRandom.uuid
    codex_session(uuid: good_uuid)
    write_rollout(good_uuid, session_meta(good_uuid), turn_context,
                  token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10))

    dir = File.join(@root, "2026/08/15")
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, "rollout-2026-08-15T00-00-00-#{SecureRandom.uuid}.jsonl.zst"), "not zstd at all")

    result = ingest

    assert_equal 2, result.files_scanned
    assert_equal 1, result.session_rows
  end

  # --- model attribution -----------------------------------------------------

  test "attributes each turn to the model in force when the model changes mid-rollout" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    write_rollout(
      uuid,
      session_meta(uuid),
      turn_context(model: "gpt-5.6-terra"),
      token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10),
      turn_context(model: "gpt-5.6-luna", timestamp: "2026-08-14T11:50:00.000Z"),
      token_count(timestamp: "2026-08-14T11:50:54.000Z", input: 120, output: 12)
    )

    ingest

    assert_equal %w[gpt-5.6-terra gpt-5.6-luna], SessionTokenUsage.order(:called_at).pluck(:model)
  end

  test "takes the model from thread_settings_applied when no turn_context has been seen" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    write_rollout(
      uuid,
      session_meta(uuid),
      thread_settings(model: "gpt-5.6-sol"),
      token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10)
    )

    ingest

    assert_equal "gpt-5.6-sol", SessionTokenUsage.sole.model
  end

  # `model` is NOT NULL and a wrong rate on real volume is worse than a visibly
  # missing row, so the event is dropped — and COUNTED, so an operator can see it
  # happened.
  test "skips a token_count event that arrives before any model has been named" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    write_rollout(
      uuid, session_meta(uuid),
      token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10)
    )

    result = ingest

    assert_equal 0, result.session_rows
    assert_equal 1, result.skipped_events
    assert_equal 0, SessionTokenUsage.count
  end

  # --- session attribution ---------------------------------------------------

  test "falls back to the clone path in the rollout's cwd when the uuid was never captured" do
    session = codex_session(uuid: SecureRandom.uuid, agent_root: "pr-merge-gate",
                            clone_path: "/home/rails/.zimmer/clones/zimmer-main-1786707822-b9f9960e")
    rollout_uuid = SecureRandom.uuid

    write_rollout(rollout_uuid, session_meta(rollout_uuid), turn_context,
                  token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10))

    ingest

    row = SessionTokenUsage.sole
    assert_equal session.id, row.session_id
    assert_equal "pr-merge-gate", row.agent_root
    assert_equal rollout_uuid, row.runtime_session_id, "the row still names the rollout it came from"
  end

  # Spend that happened is still spend. It lands unattributed rather than being
  # dropped — with the agent root the path already names, so it does not fall out
  # of the by-root rollup as well.
  test "stores a rollout whose session cannot be resolved, labelled by its cwd's agent root" do
    uuid = SecureRandom.uuid
    write_rollout(uuid, session_meta(uuid), turn_context,
                  token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10))

    ingest

    row = SessionTokenUsage.sole
    assert_nil row.session_id
    assert_equal "pr-merge-gate", row.agent_root
  end

  # --- scoping ---------------------------------------------------------------

  test "modified_since skips a rollout older than the window" do
    fresh = SecureRandom.uuid
    stale = SecureRandom.uuid
    write_rollout(fresh, session_meta(fresh), turn_context,
                  token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10))
    write_rollout(stale, session_meta(stale), turn_context,
                  token_count(timestamp: "2026-08-13T11:44:54.000Z", input: 999, output: 99),
                  date: "2026/08/13", stamp: "2026-08-13T11-44-44", mtime: 30.days.ago)

    result = ingest(modified_since: 2.hours.ago)

    assert_equal 1, result.files_scanned
    assert_equal [ fresh ], SessionTokenUsage.pluck(:runtime_session_id)
  end

  test "paths restricts the sweep to the files it names" do
    a = SecureRandom.uuid
    b = SecureRandom.uuid
    path_a = write_rollout(a, session_meta(a), turn_context,
                           token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10))
    write_rollout(b, session_meta(b), turn_context,
                  token_count(timestamp: "2026-08-14T12:44:54.000Z", input: 200, output: 20),
                  stamp: "2026-08-14T12-44-44")

    result = ingest(paths: [ path_a ])

    assert_equal 1, result.files_scanned
    assert_equal [ a ], SessionTokenUsage.pluck(:runtime_session_id)
  end

  test "a missing sessions tree is an empty run, not a raise" do
    result = CodexTokenUsageIngestionService.new(root: File.join(@root, "nope")).call

    assert_equal 0, result.files_scanned
    assert_equal 0, result.session_rows
  end

  test "rollout_paths returns both extensions, sorted, and defaults to CodexHome" do
    a = write_rollout(SecureRandom.uuid, session_meta(SecureRandom.uuid), date: "2026/08/13",
                      stamp: "2026-08-13T09-00-00")
    b = write_rollout(SecureRandom.uuid, session_meta(SecureRandom.uuid), compressed: true)

    assert_equal [ a, b ].sort, CodexTokenUsageIngestionService.rollout_paths(root: @root)
    assert_equal CodexHome.sessions_path, CodexTokenUsageIngestionService.default_root
  end

  # --- registry wiring -------------------------------------------------------

  test "the codex bundle resolves to this ingestor and the job sweeps it" do
    assert_equal CodexTokenUsageIngestionService, RuntimeRegistry.for("codex").usage_ingestor_class
    assert_includes RuntimeRegistry.usage_ingestor_classes, CodexTokenUsageIngestionService
  end

  # Codex is subscription-billed against a ChatGPT plan, not against the Anthropic
  # window the spot gate and the quota calibrator price. A Codex row in that
  # sample would drag the fleet-average burn rate toward zero, because its model
  # has no rate at all.
  test "codex rows are not quota-bearing" do
    uuid = SecureRandom.uuid
    codex_session(uuid: uuid)
    write_rollout(uuid, session_meta(uuid), turn_context,
                  token_count(timestamp: "2026-08-14T11:44:54.000Z", input: 100, output: 10))
    ingest

    assert_equal 1, SessionTokenUsage.count
    assert_equal 0, SessionTokenUsage.quota_bearing.count
  end
end

# frozen_string_literal: true

require "test_helper"
require "json"

class PiTokenUsageIngestionServiceTest < ActiveSupport::TestCase
  # --- helpers ---------------------------------------------------------------

  # An assistant entry shaped exactly as `pi 0.84.4` writes one through
  # OpenRouter, down to the `cost` sub-object it prices alongside the volumes.
  def assistant(id:, input: 10, output: 20, cache_read: 0, cache_write: 0,
                cache_write_1h: nil, provider: "openrouter",
                model: "anthropic/claude-opus-4.6",
                timestamp: "2026-09-06T14:54:04.324Z", cost: nil)
    usage = {
      "input" => input, "output" => output, "cacheRead" => cache_read,
      "cacheWrite" => cache_write, "reasoning" => 0,
      "totalTokens" => input + output + cache_read + cache_write
    }
    usage["cacheWrite1h"] = cache_write_1h if cache_write_1h
    usage["cost"] = cost if cost

    {
      "type" => "message", "id" => id, "parentId" => nil, "timestamp" => timestamp,
      "message" => {
        "role" => "assistant",
        "content" => [ { "type" => "text", "text" => "hi" } ],
        "api" => "openai-completions",
        "provider" => provider,
        "model" => model,
        "usage" => usage,
        "stopReason" => "stop"
      }
    }
  end

  def header(session_uuid, timestamp: "2026-09-06T14:53:52.949Z")
    { "type" => "session", "version" => 3, "id" => session_uuid,
      "timestamp" => timestamp, "cwd" => "/home/rails/.zimmer/clones/x" }
  end

  def transcript(*entries) = entries.map { |e| JSON.generate(e) }.join("\n") + "\n"

  def pi_session(session_uuid:, transcript:, agent_root: "zimmer", **attrs)
    Session.create!(
      {
        title: "pi session",
        prompt: "do a thing",
        agent_runtime: "pi",
        git_root: "https://github.com/tadasant/zimmer.git",
        branch: "main",
        session_id: session_uuid,
        transcript: transcript,
        metadata: { "agent_root_key" => agent_root }
      }.merge(attrs)
    )
  end

  def ingest(**kwargs) = PiTokenUsageIngestionService.new(**kwargs).call

  # --- what lands ------------------------------------------------------------

  test "writes one row per usage-bearing entry, keyed on session uuid and entry id" do
    uuid = SecureRandom.uuid
    session = pi_session(
      session_uuid: uuid,
      transcript: transcript(
        header(uuid),
        { "type" => "model_change", "id" => "a9a76d66", "provider" => "openrouter",
          "modelId" => "anthropic/claude-opus-4.6" },
        assistant(id: "1deaee4d", input: 3, output: 80, cache_write: 16_582),
        assistant(id: "bf702f48", input: 1, output: 270, cache_read: 16_582, cache_write: 186)
      )
    )

    result = ingest

    assert_equal 1, result.sessions_scanned
    assert_equal 2, result.session_rows

    rows = SessionTokenUsage.where(session_id: session.id).order(:request_id)
    assert_equal [ "pi:#{uuid}:1deaee4d", "pi:#{uuid}:bf702f48" ], rows.map(&:request_id)
    assert_equal [ "pi" ], rows.map(&:agent_runtime).uniq
    assert_equal [ "openrouter/anthropic/claude-opus-4.6" ], rows.map(&:model).uniq
    assert_equal [ "zimmer" ], rows.map(&:agent_root).uniq
    assert_equal [ uuid ], rows.map(&:runtime_session_id).uniq
    assert_equal [ false ], rows.map(&:subagent).uniq
  end

  test "maps Pi's usage object onto the four volume columns" do
    uuid = SecureRandom.uuid
    pi_session(
      session_uuid: uuid,
      transcript: transcript(header(uuid), assistant(id: "aaaaaaaa", input: 3, output: 80,
                                                     cache_read: 7, cache_write: 16_582))
    )

    ingest

    row = SessionTokenUsage.find_by!(request_id: "pi:#{uuid}:aaaaaaaa")
    assert_equal 3, row.input_tokens
    assert_equal 80, row.output_tokens
    assert_equal 7, row.cache_read_tokens
    assert_equal 16_582, row.cache_creation_tokens
    # A bare `cacheWrite` is a 5-minute write, which is what Pi's own cost math
    # charges it as. Recording it as a 1-hour write would price it at 2x base
    # input rather than the 1.25x the provider billed.
    assert_equal 16_582, row.cache_creation_5m_tokens
    assert_equal 0, row.cache_creation_1h_tokens
  end

  test "honours an explicit cacheWrite1h split" do
    uuid = SecureRandom.uuid
    pi_session(
      session_uuid: uuid,
      transcript: transcript(header(uuid), assistant(id: "bbbbbbbb", cache_write: 1000,
                                                     cache_write_1h: 400))
    )

    ingest

    row = SessionTokenUsage.find_by!(request_id: "pi:#{uuid}:bbbbbbbb")
    assert_equal 1000, row.cache_creation_tokens
    assert_equal 600, row.cache_creation_5m_tokens
    assert_equal 400, row.cache_creation_1h_tokens
  end

  # The claim the whole cost half rests on: Zimmer's list-price arithmetic
  # reproduces the cost OpenRouter charged and Pi recorded, for the Anthropic
  # models this deployment's Pi ModelCatalog offers.
  test "priced cost reproduces the cost Pi recorded alongside the volumes" do
    uuid = SecureRandom.uuid
    # Real numbers from production Pi session 15578 (opus-4.6 over OpenRouter).
    entry = assistant(
      id: "1deaee4d", input: 3, output: 80, cache_read: 0, cache_write: 16_582,
      cost: { "input" => 1.5e-05, "output" => 0.002, "cacheRead" => 0,
              "cacheWrite" => 0.1036375, "total" => 0.1056525 }
    )
    pi_session(session_uuid: uuid, transcript: transcript(header(uuid), entry))

    ingest

    row = SessionTokenUsage.find_by!(request_id: "pi:#{uuid}:1deaee4d")
    assert_in_delta 0.1056525, row.cost_usd, 1e-9
  end

  test "attributes a summary generation to the model in force when it ran" do
    uuid = SecureRandom.uuid
    pi_session(
      session_uuid: uuid,
      transcript: transcript(
        header(uuid),
        { "type" => "model_change", "id" => "a9a76d66", "provider" => "openrouter",
          "modelId" => "anthropic/claude-haiku-4.5" },
        # A compaction carries usage and no model of its own.
        { "type" => "compaction", "id" => "cccccccc", "timestamp" => "2026-09-06T15:00:00.000Z",
          "summary" => "…", "tokensBefore" => 50_000,
          "usage" => { "input" => 100, "output" => 200, "cacheRead" => 0, "cacheWrite" => 0 } }
      )
    )

    ingest

    row = SessionTokenUsage.find_by!(request_id: "pi:#{uuid}:cccccccc")
    assert_equal "openrouter/anthropic/claude-haiku-4.5", row.model
    assert_equal 200, row.output_tokens
  end

  test "never counts the assistant messages a compaction retains in its tail" do
    uuid = SecureRandom.uuid
    retained = assistant(id: "ignored1")["message"]
    pi_session(
      session_uuid: uuid,
      transcript: transcript(
        header(uuid),
        assistant(id: "dddddddd", input: 5, output: 5),
        { "type" => "compaction", "id" => "eeeeeeee", "timestamp" => "2026-09-06T15:00:00.000Z",
          "summary" => "…", "retainedTail" => [ retained ] }
      )
    )

    result = ingest

    # The compaction itself reports no usage, and the copy inside `retainedTail`
    # is not a second API call.
    assert_equal 1, result.session_rows
    assert_equal [ "pi:#{uuid}:dddddddd" ], SessionTokenUsage.pluck(:request_id)
  end

  # --- what is skipped -------------------------------------------------------

  test "skips zero-volume and unparseable entries without failing the sweep" do
    uuid = SecureRandom.uuid
    pi_session(
      session_uuid: uuid,
      transcript: [
        JSON.generate(header(uuid)),
        JSON.generate(assistant(id: "ffffffff", input: 0, output: 0)),
        "{not json",
        JSON.generate(assistant(id: "99999999", input: 1, output: 1))
      ].join("\n") + "\n"
    )

    result = ingest

    assert_equal 1, result.session_rows
    assert_equal 1, result.skipped_entries
    assert_equal [ "pi:#{uuid}:99999999" ], SessionTokenUsage.pluck(:request_id)
  end

  # A transcript is data, not a schema. One entry whose `usage` holds objects
  # where numbers belong must cost one entry — not every remaining session in the
  # run, which is what an exception escaping the per-line parse rescue would do.
  test "a malformed usage object costs one entry, not the sweep" do
    uuid = SecureRandom.uuid
    broken = assistant(id: "deadbeef")
    broken["message"]["usage"] = { "input" => { "nested" => 1 }, "output" => [ 2 ],
                                   "cacheRead" => "seven", "cacheWrite" => -5 }
    pi_session(
      session_uuid: uuid,
      transcript: transcript(header(uuid), broken, assistant(id: "cafebabe", input: 1, output: 1))
    )

    result = ingest

    # The broken entry's volumes all coerce to zero, so it is dropped as
    # zero-volume rather than raising — and the entry after it still lands.
    assert_equal 1, result.session_rows
    assert_equal [ "pi:#{uuid}:cafebabe" ], SessionTokenUsage.pluck(:request_id)
  end

  # `cacheWrite1h.clamp(0, cacheWrite)` inverts its own range on a negative
  # `cacheWrite`, which is an ArgumentError rather than a wrong number.
  test "a negative cache write is floored rather than raising" do
    uuid = SecureRandom.uuid
    entry = assistant(id: "aaaabbbb", input: 5, output: 5, cache_write: -100)
    pi_session(session_uuid: uuid, transcript: transcript(header(uuid), entry))

    ingest

    row = SessionTokenUsage.find_by!(request_id: "pi:#{uuid}:aaaabbbb")
    assert_equal 0, row.cache_creation_tokens
    assert_equal 0, row.cache_creation_5m_tokens
    assert_equal 0, row.cache_creation_1h_tokens
  end

  # An 8-hex entry id is nowhere near unique on its own, and `sessions.session_id`
  # IS nullable — AgentSessionJob clears it on recovery paths. A key with an empty
  # namespace would collapse every such session into one 32-bit space, which is
  # the collision the composite key exists to prevent.
  test "refuses a row it cannot namespace rather than writing a colliding key" do
    session = pi_session(session_uuid: SecureRandom.uuid,
                         transcript: transcript(assistant(id: "aaaaaaaa")))
    session.update_column(:session_id, nil)

    result = ingest

    assert_equal 0, result.session_rows
    assert_equal 1, result.skipped_entries
    assert_equal 0, SessionTokenUsage.count
  end

  test "leaves the other runtimes alone" do
    Session.create!(title: "claude", prompt: "x", agent_runtime: "claude_code",
                    git_root: "https://github.com/tadasant/zimmer.git", branch: "main",
                    session_id: SecureRandom.uuid,
                    transcript: transcript(header(SecureRandom.uuid), assistant(id: "aaaaaaaa")))

    assert_equal 0, ingest.sessions_scanned
    assert_equal 0, SessionTokenUsage.count
  end

  test "applies the lookback window to sessions, not to entries" do
    old = pi_session(session_uuid: SecureRandom.uuid,
                     transcript: transcript(header(SecureRandom.uuid), assistant(id: "aaaaaaaa")))
    old.update_column(:updated_at, 3.days.ago)

    fresh_uuid = SecureRandom.uuid
    pi_session(session_uuid: fresh_uuid,
               transcript: transcript(header(fresh_uuid), assistant(id: "bbbbbbbb")))

    result = ingest(modified_since: 2.hours.ago)

    assert_equal 1, result.sessions_scanned
    assert_equal [ "pi:#{fresh_uuid}:bbbbbbbb" ], SessionTokenUsage.pluck(:request_id)
  end

  test "session_ids narrows the sweep for the sliced historical task" do
    a = pi_session(session_uuid: SecureRandom.uuid,
                   transcript: transcript(header(SecureRandom.uuid), assistant(id: "aaaaaaaa")))
    pi_session(session_uuid: SecureRandom.uuid,
               transcript: transcript(header(SecureRandom.uuid), assistant(id: "bbbbbbbb")))

    result = ingest(session_ids: [ a.id ])

    assert_equal 1, result.sessions_scanned
    assert_equal 1, SessionTokenUsage.count
  end

  # --- idempotence and forks -------------------------------------------------

  test "re-ingesting the same transcript writes nothing the second time" do
    uuid = SecureRandom.uuid
    pi_session(session_uuid: uuid,
               transcript: transcript(header(uuid), assistant(id: "aaaaaaaa")))

    assert_equal 1, ingest.session_rows
    assert_equal 0, ingest.session_rows
    assert_equal 1, SessionTokenUsage.count
  end

  test "a fork's copied prefix does not double-count its source's spend" do
    source_uuid = SecureRandom.uuid
    shared = transcript(header(source_uuid), assistant(id: "aaaaaaaa"))
    source = pi_session(session_uuid: source_uuid, transcript: shared, agent_root: "zimmer")
    # ForkSessionService copies the source's transcript verbatim: same header id,
    # same entry ids, under a session of the fork's own.
    pi_session(session_uuid: SecureRandom.uuid, transcript: shared, agent_root: "pi-extensions")

    result = ingest

    assert_equal 2, result.sessions_scanned
    assert_equal 1, result.session_rows
    row = SessionTokenUsage.sole
    # And the one row it wrote belongs to the session that actually made the call.
    assert_equal source.id, row.session_id
    assert_equal "zimmer", row.agent_root
  end

  # --- registry wiring -------------------------------------------------------

  test "the pi bundle resolves to this ingestor and the job runs every registered one" do
    assert_equal PiTokenUsageIngestionService, RuntimeRegistry.for("pi").usage_ingestor_class
    assert_equal TokenUsageIngestionService, RuntimeRegistry.for("claude_code").usage_ingestor_class
    assert_includes RuntimeRegistry.usage_ingestor_classes, PiTokenUsageIngestionService
    # Codex has no ingestor yet, and the registry is where that is said.
    assert_nil RuntimeRegistry.for("codex").usage_ingestor_class
  end

  # ApplicationJob registers `discard_interrupt_quietly` and `retry_on
  # ActiveRecord::StatementTimeout`; a `rescue StandardError` inside `perform`
  # sees both first. Swallowing the interrupt would put an ERROR line — which
  # pages — on every deploy that lands mid-sweep.
  test "the job re-raises a deploy interrupt and a statement timeout rather than logging them" do
    [ GoodJob::InterruptError, ActiveRecord::StatementTimeout ].each do |error_class|
      TokenUsageIngestionService.stub(:new, ->(**) { raise error_class }) do
        assert_raises(error_class) { TokenUsageIngestionJob.new.perform }
      end
    end
  end

  test "the job sweeps Pi as well as Claude Code, and one failure does not stop the other" do
    uuid = SecureRandom.uuid
    pi_session(session_uuid: uuid,
               transcript: transcript(header(uuid), assistant(id: "aaaaaaaa")))

    TokenUsageIngestionService.stub(:new, ->(**) { raise "claude corpus unreadable" }) do
      results = TokenUsageIngestionJob.new.perform

      assert_equal 1, results.length
      assert_equal 1, results.first.session_rows
    end

    assert_equal 1, SessionTokenUsage.count
  end
end

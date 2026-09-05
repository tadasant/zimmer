# frozen_string_literal: true

require "test_helper"


class Mcp::Tools::GetSessionTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "returns session details and the transcript file hint instead of the transcript" do
    session = sessions(:archived)

    output = @tool.call("id" => session.id)

    assert_includes output, "## Session: #{session.title}"
    assert_includes output, "- **ID:** #{session.id}"
    assert_includes output, "- **Status:** archived"
    assert_includes output, "### Transcript File"
    assert_includes output, "`~/.claude/projects/*/#{session.session_id}.jsonl`"
    refute_includes output, "I've completed the task for you."
  end

  test "reports an empty queue as an explicit answer rather than an absent section" do
    output = @tool.call("id" => sessions(:running).id)

    assert_includes output, "### Queued Messages"
    assert_includes output, "Nothing is queued for this session"
  end

  test "reports pending queued messages with a count and truncated previews" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "Rebase onto main first", position: 1, status: "pending")
    session.enqueued_messages.create!(content: "b" * 400, position: 2, status: "pending")

    output = @tool.call("id" => session.id)

    assert_includes output, "### Queued Messages"
    assert_includes output, "- **Pending:** 2 messages queued for this session and not yet delivered."
    assert_includes output, "**Position 1**"
    assert_includes output, "Rebase onto main first"
    assert_includes output, "**Position 2**"
    # Truncated hard: the 120-char cut, not the 200-char one manage_enqueued_messages uses.
    assert_includes output, "#{'b' * 120}..."
    assert_not_includes output, "b" * 121
    assert_includes output, "anything you send now lands BEHIND them"
  end

  test "singularizes a one-message queue" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "Only one", position: 1, status: "pending")

    assert_includes @tool.call("id" => session.id), "- **Pending:** 1 message queued"
  end

  test "counts only pending messages, not delivered or retired ones" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "Still waiting", position: 1, status: "pending")
    session.enqueued_messages.create!(content: "Being delivered", position: 2, status: "processing")
    session.enqueued_messages.create!(content: "Never delivered", position: 3, status: "undelivered")
    session.enqueued_messages.create!(content: "Already delivered", position: 4, status: "sent")

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Pending:** 1 message queued"
    assert_includes output, "Still waiting"
    assert_not_includes output, "Being delivered"
    assert_not_includes output, "Never delivered"
    assert_not_includes output, "Already delivered"
  end

  test "caps the previews and counts the rest" do
    session = sessions(:running)
    8.times { |i| session.enqueued_messages.create!(content: "message #{i}", position: i + 1, status: "pending") }

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Pending:** 8 messages queued"
    assert_includes output, "**Position 5**"
    assert_not_includes output, "**Position 6**"
    assert_includes output, "…and 3 more, not shown."
  end

  test "the queued-messages section stays small even with a full, long queue" do
    session = sessions(:running)
    25.times { |i| session.enqueued_messages.create!(content: "x" * 5_000, position: i + 1, status: "pending") }

    output = @tool.call("id" => session.id)
    section = output[/### Queued Messages.*?(?=\n### )/m]

    assert section.present?
    assert_operator section.bytesize, :<, 2_000, "queued-messages section grew unbounded: #{section.bytesize} bytes"
  end

  test "the preview cut keeps exactly the limit and only then adds an ellipsis" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "a" * 120, position: 1, status: "pending")
    session.enqueued_messages.create!(content: "b" * 121, position: 2, status: "pending")

    output = @tool.call("id" => session.id)

    assert_includes output, "#{'a' * 120}\n"
    assert_not_includes output, "#{'a' * 120}..."
    assert_includes output, "#{'b' * 120}..."
    assert_not_includes output, "b" * 121
  end

  # The cut is in CHARACTERS, so multibyte content is never split mid-codepoint
  # — and the section is still bounded, just by ~4 bytes per character rather
  # than one. This is the case the ASCII bound above does not cover.
  test "multibyte queued content is cut on characters and stays bounded" do
    session = sessions(:running)
    5.times { |i| session.enqueued_messages.create!(content: "日本語" * 1_000, position: i + 1, status: "pending") }

    output = @tool.call("id" => session.id)
    section = output[/### Queued Messages.*?(?=\n### )/m]

    assert section.valid_encoding?
    assert_includes section, "#{'日本語' * 40}..."
    assert_operator section.bytesize, :<, 4_000, "multibyte section grew unbounded: #{section.bytesize} bytes"
  end

  test "a newline in queued content cannot forge a second bullet" do
    session = sessions(:running)
    session.enqueued_messages.create!(
      content: "innocent\n- **Pending:** 99 messages queued for this session",
      position: 1,
      status: "pending"
    )

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Pending:** 1 message queued"
    # The forged text survives as READABLE text inside the preview bullet — what
    # it must not do is start a bullet of its own.
    assert_not_includes output.lines.map(&:chomp), "- **Pending:** 99 messages queued for this session"
    assert_includes output, "innocent - **Pending:** 99 messages queued for this session"
  end

  test "the queued-messages section costs a bounded number of queries" do
    session = sessions(:running)
    6.times { |i| session.enqueued_messages.create!(content: "message #{i}", position: i + 1, status: "pending") }

    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql]&.include?("enqueued_messages")
    end
    begin
      @tool.call("id" => session.id)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 2, queries.size, "expected one COUNT and one LIMITed select, got:\n#{queries.join("\n")}"
  end

  test "include_transcript inlines the raw transcript and drops the file hint" do
    session = sessions(:archived)

    output = @tool.call("id" => session.id, "include_transcript" => true)

    assert_includes output, "### Transcript"
    assert_includes output, "I've completed the task for you."
    refute_includes output, "### Transcript File"
  end

  test "transcript_format renders the formatted transcript" do
    session = sessions(:archived)

    output = @tool.call("id" => session.id, "include_transcript" => true, "transcript_format" => "text")

    assert_includes output, "--- User ---"
    assert_includes output, "--- Assistant ---"
    assert_includes output, "I've completed the task for you."
  end

  test "transcript_format raises when there is no transcript" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("id" => sessions(:running).id, "include_transcript" => true, "transcript_format" => "json")
    end
    assert_match(/No transcript available/, error.message)
  end

  test "include_logs paginates the session logs" do
    session = sessions(:running)

    output = @tool.call("id" => session.id, "include_logs" => true)

    assert_includes output, "### Logs (#{session.logs.count} total, page 1 of 1)"
    assert_includes output, "**[INFO]**"
    assert_includes output, "Agent started successfully"

    paged = @tool.call("id" => session.id, "include_logs" => true, "logs_per_page" => 1)
    assert_includes paged, "*More logs available. Use logs_page=2 to see the next page.*"
  end

  test "include_subagent_transcripts reports an empty list" do
    output = @tool.call("id" => sessions(:running).id, "include_subagent_transcripts" => true)

    assert_includes output, "### Subagent Transcripts (0 total, page 1 of 0)"
    assert_includes output, "No subagent transcripts found."
  end

  test "session can be addressed by slug" do
    session = sessions(:running)
    session.update!(slug: "mcp-get-session-slug")

    output = @tool.call("id" => "mcp-get-session-slug")

    assert_includes output, "- **ID:** #{session.id}"
    assert_includes output, "- **Slug:** mcp-get-session-slug"
  end

  test "missing session raises a tool error" do
    assert_raises(Mcp::ToolError) { @tool.call("id" => 999_999) }
    assert_raises(Mcp::ToolError) { @tool.call({}) }
  end

  # An agent reading its own session has to be able to tell a deferred turn from a
  # stuck one — and, when the gate refused a WAKE rather than a first start, that
  # the prompt it was woken for is still coming.
  test "a spot session held before its next turn says so, and says the prompt survives" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_AT => 20.minutes.ago.utc.iso8601,
      SpotSessionHold::HELD_RETRY_AT => 40.minutes.from_now.utc.iso8601,
      SpotSessionHold::HELD_COUNT => 3,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "**Spot gate: next turn held (`at_utilization_limit`):**"
    assert_includes output, "- **Hold re-check:** Next check"
    assert_includes output, "- **Holds so far:** 3"
    assert_includes output, "The prompt that woke it is not lost"
  end

  # The detail above is a SNAPSHOT of what the gate said at `spot_hold_at`, and an
  # agent reading its own session had no way to tell. Session 7507 read back "5 of
  # 5 session slots taken" eleven hours after the gate had returned to
  # `within_limits` at 1 of 5 — the same fossil the session page showed, in the
  # same words, which is why both surfaces now render it from one object.
  test "a held session says how old the gate reading is, and names an overdue re-check" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionHold::HELD_AT => 11.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_RETRY_AT => 10.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_COUNT => 145,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **As of:** That was the gate's reading about 11 hours ago"
    assert_includes output, "not a live one"
    assert_includes output, "Its re-check was due about 10 hours ago"
    assert_includes output, "has not fired, so the ladder has stalled"
    refute_includes output, "Hold re-check:** Next check"
  end

  # These lines promise the spot-hold sweep will re-arm an overdue re-check, and
  # that sweep only touches sessions dormant in `waiting`. An archived session
  # keeps its hold record deliberately, so reading one back with that promise
  # attached would tell an agent something false about its own session.
  test "a session that is no longer waiting reads back no hold at all" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionHold::HELD_AT => 11.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_RETRY_AT => 10.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_COUNT => 145,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
    })
    assert_includes @tool.call("id" => session.id), "**Spot gate:"

    session.update_columns(status: Session.statuses[:archived])

    output = @tool.call("id" => session.id)

    refute_includes output, "**Spot gate:"
    refute_includes output, "spot-hold sweep re-arms it automatically"
  end

  test "a spot session held at the starting line does not claim a queued prompt" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 10 of 10 session slots taken.",
      SpotSessionHold::HELD_COUNT => 1,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "**Spot gate: start held (`fleet_at_cap`):**"
    refute_includes output, "The prompt that woke it is not lost"
  end

  # The pause branch is reached through the ranking now rather than rendered
  # unconditionally, so it needs positive coverage and not only the refutations
  # the multi-mechanism tests below make.
  test "a spot session paused mid-run by the ceiling reads back the pause" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionPause::PAUSED_AT => "2026-08-22T16:59:15Z",
      SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
      SpotSessionPause::PAUSED_DETAIL => "Pausing spot sessions: the 5-hour window's spot budget is spent.",
      SpotSessionPause::PAUSED_COUNT => 2
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Paused mid-run by the spot ceiling:** Pausing spot sessions:"
    assert_includes output, "- **Paused at:** 2026-08-22T16:59:15Z"
    assert_includes output, "- **Pauses so far:** 2"
    assert_includes output, "- **Resumes when:** the pool's utilization falls"
  end

  # The other shape that shares the pause record. Nothing interrupted this session,
  # so it must not be described as a casualty of the ceiling.
  test "a session parked in the spot queue deliberately reads back as deliberate" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionPause::PAUSED_AT => "2026-08-22T16:59:15Z",
      SpotSessionPause::PAUSED_REASON => SpotSessionPause::QUEUED_REASON,
      SpotSessionPause::PAUSED_DETAIL => "Parked in the spot queue on request.",
      SpotSessionPause::PAUSED_COUNT => 1
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Parked in the spot queue deliberately:**"
    refute_includes output, "- **Paused mid-run by the spot ceiling:**"
  end

  # A record with no parseable stamp still gets named, without an empty " from ."
  # where its timestamp would go.
  test "a superseded mechanism with no usable timestamp is named without one" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionPause::PAUSED_AT => "not a timestamp",
      SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
      SpotSessionPause::PAUSED_DETAIL => "Pausing spot sessions: the 5-hour window's spot budget is spent.",
      SpotSessionPause::PAUSED_COUNT => 2,
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => "2026-08-22T16:59:30Z"
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "**Also on the record, and not why it is waiting now:** a spot ceiling " \
                            "pause. It is older than the reason above."
  end

  # An auth-outage park has its own resume owner — the quota-recovery path, not
  # the spot gate — and until #642 it was the one dormancy this tool could not say
  # out loud. A session parked on an empty login pool read back nothing at all.
  test "an auth-outage park is rendered, and says what brings the session back" do
    session = sessions(:running)
    session.update!(status: :waiting, metadata: {
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => "2026-08-22T11:50:51Z",
      "auth_outage_pool_recovers_at" => 2.hours.from_now.utc.iso8601
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Parked for an auth outage (`quota_exhausted`):** every Claude Code " \
                            "account is over its quota"
    assert_includes output, "- **Parked at:** 2026-08-22T11:50:51Z"
    assert_includes output, "- **Resumes when:** the account pool recovers"
    assert_includes output, "- **Pool's earliest reset:**"
    assert_includes output, "Nothing fires at it."
  end

  # A failed login is a different sentence from an exhausted quota, and the two
  # want different things from a reader.
  test "an unrecoverable auth park names the login failure rather than a quota" do
    session = sessions(:running)
    session.update!(status: :waiting, metadata: {
      "auth_outage_reason" => AuthOutageParkService::AUTH_UNRECOVERABLE,
      "auth_outage_parked_at" => "2026-08-22T11:50:51Z"
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Parked for an auth outage (`auth_unrecoverable`):** the runtime reported"
    assert_includes output, "re-injecting credentials did not fix it."
    refute_includes output, "- **Pool's earliest reset:**"
  end

  # A spot session is woken by the ranked fleet wake in precedence order, not
  # simply "when the pool recovers" — promising it the next wake would overstate
  # what it gets, exactly as the session page's banner is careful not to.
  test "a parked spot session is told the fleet wake reaches it in precedence order" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, precedence: 640, metadata: {
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => "2026-08-22T11:50:51Z"
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "the ranked fleet wake reaches it in precedence order (currently 640)"
  end

  # Session 6808, as reported (#642): the headline named a start-hold whose own
  # re-check was two days in the past, while an auth-outage park a full day newer
  # sat beside it unrendered — pointing every reader at the spot gate when the
  # account pool was what this session was waiting on.
  test "an expired start-hold beside a newer outage park reads back the park" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionHold::HELD_AT => "2026-08-21T11:16:53Z",
      SpotSessionHold::HELD_RETRY_AT => "2026-08-21T12:18:21Z",
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_COUNT => 25,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START,
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => "2026-08-22T11:50:51Z"
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Parked for an auth outage (`quota_exhausted`):**"
    refute_includes output, "- **Spot gate: start held"
    # The hold is still named — it is a real record — but as superseded, and with
    # the reason the sweep is not coming for it. The old output promised the
    # opposite in the same breath.
    assert_includes output, "**Also on the record, and not why it is waiting now:** a spot-gate hold " \
                            "(`at_utilization_limit`) from 2026-08-21T11:16:53Z."
    assert_includes output, "nothing is coming to re-arm it"
    refute_includes output, "spot-hold sweep re-arms it automatically"
  end

  # Session 7503, as reported (#642): a ceiling pause fifteen seconds OLDER than
  # the park beside it. Fifteen seconds is still newer, and the two resume from
  # different places.
  test "a ceiling pause fifteen seconds older than the park reads back the park" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionPause::PAUSED_AT => "2026-08-22T16:59:15Z",
      SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
      SpotSessionPause::PAUSED_DETAIL => "Pausing spot sessions: the 5-hour window's spot budget is spent.",
      SpotSessionPause::PAUSED_COUNT => 2,
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => "2026-08-22T16:59:30Z"
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Parked for an auth outage (`quota_exhausted`):**"
    refute_includes output, "- **Paused mid-run by the spot ceiling:**"
    assert_includes output, "**Also on the record, and not why it is waiting now:** a spot ceiling pause " \
                            "from 2026-08-22T16:59:15Z. It is older than the reason above."
  end

  # Recency, not a pecking order. A park that has been sitting there since
  # yesterday does not outrank the hold the gate took this afternoon.
  test "a live hold taken after the park takes the headline back from it" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => 1.day.ago.utc.iso8601,
      SpotSessionHold::HELD_AT => 20.minutes.ago.utc.iso8601,
      SpotSessionHold::HELD_RETRY_AT => 40.minutes.from_now.utc.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_COUNT => 1,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Spot gate: start held (`fleet_at_cap`):**"
    assert_includes output, "- **Hold re-check:** Next check"
    refute_includes output, "- **Parked for an auth outage"
    assert_includes output, "**Also on the record, and not why it is waiting now:** an auth-outage park " \
                            "(`quota_exhausted`)"
  end
  # ==========================================================================
  # Payload size: what the default cuts, and how it says so (#652)
  # ==========================================================================

  # The whole point of the default. Everything a fleet-maintenance skill reads to
  # classify a waiting session is short, and none of it is behind `verbose`.
  test "the scheduling fields a classifier reads are never cut" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, prompt: "p" * 40_000, metadata: {
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => "2026-08-22T16:59:15Z",
      "active_follow_up_prompt" => "f" * 40_000
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Status:** waiting"
    assert_includes output, "- **Scheduling class:** spot"
    assert_includes output, "- **Precedence:** #{session.precedence}"
    assert_includes output, "- **Parked for an auth outage (`quota_exhausted`):**"
    assert_includes output, "- **Parked at:** 2026-08-22T16:59:15Z"
    assert_includes output, '"auth_outage_reason": "quota_exhausted"'
    assert output.length < 8_000, "classification read should be small, was #{output.length}"
  end

  test "a long prompt is cut to the documented budget and says how long it really is" do
    session = sessions(:running)
    session.update!(prompt: "p" * 40_000)
    limit = Mcp::Tools::GetSession::MAX_PROMPT_CHARS

    output = @tool.call("id" => session.id)

    assert_includes output, "#{'p' * limit}..."
    assert_not_includes output, "p" * (limit + 1)
    assert_includes output, "_Truncated: 1,000 of 40,000 characters shown. Pass `verbose: true` for the whole prompt._"
  end

  test "a short prompt is rendered whole with no truncation marker" do
    session = sessions(:running)
    session.update!(prompt: "ship it")

    output = @tool.call("id" => session.id)

    assert_includes output, "### Current Prompt\n```\nship it\n```"
    assert_not_includes output, "Truncated:"
  end

  test "verbose returns the prompt in full" do
    session = sessions(:running)
    session.update!(prompt: "p" * 40_000)

    output = @tool.call("id" => session.id, "verbose" => true)

    assert_includes output, "p" * 40_000
    assert_not_includes output, "Truncated:"
  end

  # Keys and structure are what a caller greps; only the values that are whole
  # prompts get cut, and each says so where it was cut.
  test "long metadata values are cut in place while every key survives" do
    session = sessions(:running)
    session.update!(metadata: {
      "spot_hold_reason" => "fleet_at_cap",
      "active_follow_up_prompt" => "f" * 9_000,
      "nested" => { "deep_prompt" => "d" * 9_000 }
    })
    limit = Mcp::Tools::GetSession::MAX_METADATA_VALUE_CHARS

    output = @tool.call("id" => session.id)

    assert_includes output, '"spot_hold_reason": "fleet_at_cap"'
    assert_includes output, '"active_follow_up_prompt"'
    assert_includes output, '"deep_prompt"'
    assert_includes output, "... [cut: 300 of 9,000 characters shown]"
    assert_includes output, "2 string values longer than #{limit} characters were cut"
    assert_not_includes output, "f" * (limit + 1)
  end

  test "verbose returns the metadata JSON as stored" do
    session = sessions(:running)
    session.update!(metadata: { "active_follow_up_prompt" => "f" * 9_000 })

    output = @tool.call("id" => session.id, "verbose" => true)

    assert_includes output, "f" * 9_000
    assert_not_includes output, "[cut:"
  end

  def provenance_pair
    router = Session.create!(title: "Route it", prompt: "route", agent_runtime: "claude_code",
                             git_root: "https://github.com/test/repo.git")
    worker = Session.create!(title: "Do it", prompt: "do", agent_runtime: "claude_code",
                             git_root: "https://github.com/test/repo.git", parent_session_id: router.id)
    [ router, worker ]
  end

  # The constraint the issue gate wrote down. The record may be summarised; it
  # may not be shortened in a way a reader cannot detect, because a gate reads it
  # to decide whether a human asked for something and is required to hold rather
  # than guess when it cannot tell.
  test "the human-message summary is self-describing rather than silently cut" do
    router, worker = provenance_pair
    HumanMessage.create!(session: worker, author: "tadasant", channel: HumanMessage::WEB_UI,
                         content: "h" * 4_000, occurred_at: 1.hour.ago)
    12.times do |i|
      HumanMessage.create!(session: router, author: "tadasant", channel: HumanMessage::WEB_UI,
                           content: "elsewhere #{i}", occurred_at: (50 - i).minutes.ago)
    end
    limit = Mcp::ProvenanceSections::SUMMARY_CONTENT_LIMIT
    per_origin = Mcp::ProvenanceSections::SUMMARY_ENTRIES_PER_ORIGIN

    output = @tool.call("id" => worker.id)

    # The counts are of the whole record, not of what was rendered.
    assert_includes output, "- **Authored in this session:** 1"
    assert_includes output, "- **Elsewhere in the hierarchy:** 12"
    # It says it is a summary, what it listed, and what it left out.
    assert_includes output, "**This is a summary of the record, not the record.**"
    assert_includes output, "Listed: all 1 authored HERE, and the newest #{per_origin} of 12 " \
                            "authored elsewhere — #{per_origin + 1} of 13 entries."
    assert_includes output, "_#{12 - per_origin} older entries not shown here"
    # And every cut entry carries its own real length and the call that undoes it.
    assert_includes output, "_Truncated: #{limit} of 4,000 characters shown. Full text: " \
                            "`get_session_provenance` on this session, or `get_session` with `verbose: true`._"
    assert_not_includes output, "h" * (limit + 1)
  end

  # The `here` half is what answers "did a human ask THIS session for this?", so
  # a chatty hierarchy must not push it off the list.
  test "every here entry is listed even when the hierarchy is full of elsewhere ones" do
    router, worker = provenance_pair
    30.times do |i|
      HumanMessage.create!(session: router, author: "tadasant", channel: HumanMessage::WEB_UI,
                           content: "elsewhere #{i}", occurred_at: (90 - i).minutes.ago)
    end
    HumanMessage.create!(session: worker, author: "tadasant", channel: HumanMessage::WEB_UI,
                         content: "the ask made here", occurred_at: 90.minutes.ago)

    output = @tool.call("id" => worker.id)

    assert_includes output, "the ask made here"
    assert_includes output, "Listed: all 1 authored HERE"
  end

  # A pointer that cannot deliver is the same failure as a silent cut, reached
  # from the other side. `get_session_provenance` lists the newest 25 — a cap the
  # record has always had — so on a longer record the summary must not send a
  # caller there for entries it will not get.
  test "the summary never points at a call that cannot return what it omitted" do
    router, worker = provenance_pair
    31.times do |i|
      HumanMessage.create!(session: router, author: "tadasant", channel: HumanMessage::WEB_UI,
                           content: "elsewhere #{i}", occurred_at: (120 - i).minutes.ago)
    end
    cap = Mcp::ProvenanceSections::MAX_HUMAN_MESSAGES

    output = @tool.call("id" => worker.id)

    assert_includes output, "`get_session_provenance` on this session returns the newest #{cap} in full, " \
                            "as does `get_session` with `verbose: true` — including every entry listed above."
    assert_includes output, "The 6 older than that window are on the record and counted above, but no " \
                            "MCP call returns them."
    assert_includes output, "26 older entries not shown here — counted above, and 20 of them are returned in " \
                            "full by `get_session_provenance`; the other 6 fall outside its newest-#{cap} " \
                            "window and no MCP call returns them."
    assert_not_includes output, "returns every entry, uncut"
  end

  # The pointer above is only true because the summary's selection is a subset of
  # the uncut rendering's. A `here` entry older than the newest 25 overall is the
  # case that would break it.
  test "an entry the summary lists is always one the uncut rendering lists" do
    router, worker = provenance_pair
    old_here = HumanMessage.create!(session: worker, author: "tadasant", channel: HumanMessage::WEB_UI,
                                    content: "the ask made here, long ago", occurred_at: 200.minutes.ago)
    40.times do |i|
      HumanMessage.create!(session: router, author: "tadasant", channel: HumanMessage::WEB_UI,
                           content: "elsewhere #{i}", occurred_at: (100 - i).minutes.ago)
    end

    summary = @tool.call("id" => worker.id)
    uncut = @tool.call("id" => worker.id, "verbose" => true)

    assert_includes summary, old_here.content
    assert_includes uncut, old_here.content, "the uncut rendering must be a superset of the summary"
  end

  # "Complete" is the strongest word this block has. It must not be read as
  # covering sessions the hierarchy walk never searched.
  test "a truncated hierarchy walk cannot be described as a complete record" do
    session = sessions(:running)
    HumanMessage.create!(session: session, author: "tadasant", channel: HumanMessage::WEB_UI,
                         content: "ship it", occurred_at: 1.hour.ago)
    truncated = SessionHierarchy.new(session)
    truncated.define_singleton_method(:truncated?) { true }
    truncated.define_singleton_method(:truncation_reason) { "walk cut" }
    session.define_singleton_method(:human_message_record) do
      SessionHumanMessages.new(self, hierarchy: truncated)
    end
    @tool.stub(:find_session, session) do
      output = @tool.call("id" => session.id)

      assert_includes output, "**Every entry the hierarchy walk reached is listed below, in full**"
      assert_not_includes output, "- **Complete:**"
    end
  end

  # Boundaries. `TextBudget.over?` is a strict `>`, so a value exactly at its
  # budget is rendered whole and claims no truncation.
  test "a value exactly at its budget is rendered whole and claims nothing" do
    session = sessions(:running)
    session.update!(
      prompt: "p" * Mcp::Tools::GetSession::MAX_PROMPT_CHARS,
      metadata: { "k" => "m" * Mcp::Tools::GetSession::MAX_METADATA_VALUE_CHARS }
    )
    HumanMessage.create!(session: session, author: "tadasant", channel: HumanMessage::WEB_UI,
                         content: "h" * Mcp::ProvenanceSections::SUMMARY_CONTENT_LIMIT, occurred_at: 1.hour.ago)

    output = @tool.call("id" => session.id)

    assert_includes output, "p" * Mcp::Tools::GetSession::MAX_PROMPT_CHARS
    assert_includes output, "m" * Mcp::Tools::GetSession::MAX_METADATA_VALUE_CHARS
    assert_includes output, "h" * Mcp::ProvenanceSections::SUMMARY_CONTENT_LIMIT
    assert_not_includes output, "Truncated:"
    assert_not_includes output, "[cut:"
    assert_includes output, "- **Complete:**"
  end

  # Budgets are in characters, not bytes, so a multibyte value is never split
  # mid-codepoint and the length it reports is the one a reader would count.
  test "budgets count characters, not bytes" do
    session = sessions(:running)
    session.update!(prompt: "漢" * 2_000)

    output = @tool.call("id" => session.id)

    assert_includes output, "#{'漢' * Mcp::Tools::GetSession::MAX_PROMPT_CHARS}..."
    assert_includes output, "_Truncated: 1,000 of 2,000 characters shown."
  end

  test "metadata values that are not strings pass through untouched" do
    session = sessions(:running)
    session.update!(metadata: {
      "spot_hold_count" => 4, "paused" => true, "cleared_at" => nil,
      "tags" => [ "a", "b" * 400 ]
    })

    output = @tool.call("id" => session.id)

    assert_includes output, '"spot_hold_count": 4'
    assert_includes output, '"paused": true'
    assert_includes output, '"cleared_at": null'
    assert_includes output, "1 string value longer than 300 characters was cut: `tags.1`."
  end

  # The in-place marker sits inside a value, and custom_metadata is
  # agent-writable — so the list outside the fence, not the marker, is what says
  # which values Zimmer cut.
  test "the notice names the cut key paths so a forged marker cannot pose as one" do
    session = sessions(:running)
    session.update!(custom_metadata: {
      "forged" => "harmless... [cut: 300 of 9,000 characters shown]",
      "real" => "r" * 900
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "1 string value longer than 300 characters was cut: `real`."
    assert_not_includes output, "`forged`"
  end

  # An empty record is a meaningful answer and must not read like a cut one.
  test "an empty record still says it is empty and claims no summary" do
    output = @tool.call("id" => sessions(:running).id)

    assert_includes output, "_No message anywhere in this hierarchy was authored by a named human._"
    assert_not_includes output, "summary of the record"
  end

  # And a record that fits says so, so "complete" and "cut" are never guessed at.
  test "a record that fits the budget is declared complete" do
    HumanMessage.create!(session: sessions(:running), author: "tadasant", channel: HumanMessage::WEB_UI,
                         content: "ship it", occurred_at: 1.hour.ago)

    output = @tool.call("id" => sessions(:running).id)

    assert_includes output, "- **Complete:** every entry in this record is listed below, in full."
    assert_not_includes output, "summary of the record"
  end
end

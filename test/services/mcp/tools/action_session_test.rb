# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "tmpdir"

class Mcp::Tools::ActionSessionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AttachmentFixtures

  setup do
    @tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  # Durable attachment storage outlives the test that wrote it.
  teardown { cleanup_stored_attachments! }

  test "change_scheduling_class moves one session without touching its genesis" do
    session = sessions(:needs_input)
    session.update!(genesis: SessionGenesis::GITHUB_ISSUE, scheduling_class: nil)
    assert session.spot?

    output = @tool.call("action" => "change_scheduling_class", "session_id" => session.id, "scheduling_class" => "priority")

    assert_equal SessionGenesis::PRIORITY, session.reload.scheduling_class
    assert session.priority?
    assert_equal SessionGenesis::GITHUB_ISSUE, session.genesis
    assert_includes output, "## Scheduling Class Updated"
    assert_includes output, "- **Scheduling class:** priority (was spot)"
  end

  test "change_scheduling_class with null returns the session to derived" do
    session = sessions(:needs_input)
    session.update!(genesis: SessionGenesis::GITHUB_ISSUE, scheduling_class: SessionGenesis::PRIORITY)

    @tool.call("action" => "change_scheduling_class", "session_id" => session.id, "scheduling_class" => nil)

    assert_nil session.reload.scheduling_class
    assert session.spot?, "back to what github_issue derives"
  end

  test "change_scheduling_class requires the parameter" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_scheduling_class", "session_id" => sessions(:needs_input).id)
    end
    assert_match(/"scheduling_class" parameter is required/, error.message)
  end

  test "change_scheduling_class rejects an unknown class" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_scheduling_class", "session_id" => sessions(:needs_input).id, "scheduling_class" => "whenever")
    end
    assert_match(/Unknown scheduling_class/, error.message)
  end

  # --- precedence -------------------------------------------------------------

  test "change_precedence sets the rank and reports the move" do
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 10)

    output = @tool.call("action" => "change_precedence", "session_id" => session.id, "precedence" => 900)

    assert_equal 900, session.reload.precedence
    assert_includes output, "## Precedence Updated"
    assert_includes output, "- **Precedence:** 900 (was 10)"
  end

  # A priority session carries a rank it does not currently use. Saying so beats
  # letting an agent think it has just changed when the session starts.
  test "change_precedence on a priority session says the rank is not gating it" do
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::PRIORITY)

    output = @tool.call("action" => "change_precedence", "session_id" => session.id, "precedence" => 5)

    assert_includes output, "this session is priority"
  end

  test "change_precedence requires the parameter" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_precedence", "session_id" => sessions(:needs_input).id)
    end
    assert_match(/"precedence" parameter is required/, error.message)
  end

  test "change_precedence rejects a non-integer" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_precedence", "session_id" => sessions(:needs_input).id,
        "precedence" => "urgent")
    end
    assert_match(/precedence must be an integer/, error.message)
  end

  # A demotion that does not also place the session leaves it wherever its old
  # rank puts it, which is usually the bottom — so one call can do both.
  test "change_scheduling_class can place the session in the same call" do
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::PRIORITY, precedence: 0)

    output = @tool.call("action" => "change_scheduling_class", "session_id" => session.id,
      "scheduling_class" => "spot", "precedence" => 4242)

    session.reload
    assert session.spot?
    assert_equal 4242, session.precedence
    assert_includes output, "- **Precedence:** 4242 (was 0)"
  end

  test "the precedence description states the absolute scale" do
    description = Mcp::Tools::ActionSession.input_schema.to_h.dig(:properties, :precedence, :description)

    assert_match(/absolute scale/i, description)
    assert_match(/100000 comes before 50/, description)
  end

  # --- place --------------------------------------------------------------------

  test "change_precedence with place top_of_spot lands the session above the current top" do
    top = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 400)
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 0)

    output = @tool.call("action" => "change_precedence", "session_id" => session.id,
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)

    session.reload
    assert_equal 400 + SessionPrecedence::SLOT_GAP, session.precedence
    assert_operator session.precedence, :>, top.precedence, "it heads the queue it was placed into"
    assert_equal session, Session.where(id: [ top.id, session.id ]).ranked.first
    assert_includes output, "- **Precedence:** #{session.precedence} (was 0)"
  end

  # The reason the value is resolved server-side rather than read and passed
  # back: a top that has since been archived is not the top any more, and a
  # caller working from a stale read would inflate the scale by 90,000.
  test "change_precedence with place top_of_spot reads the live queue, not a stale top" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 90_000, status: :archived)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 20)
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 0)

    @tool.call("action" => "change_precedence", "session_id" => session.id,
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)

    assert_equal 20 + SessionPrecedence::SLOT_GAP, session.reload.precedence
  end

  # A session already on top must not be measured against itself, or repeating
  # the call would walk it SLOT_GAP higher every time. Same exclusion the Ranked
  # view's demote button applies. The runner-up at 100 is what makes this test
  # able to tell a correct exclusion from a fall-through to the nothing-queued
  # branch, which would answer DEFAULT + SLOT_GAP whatever else is queued.
  test "place top_of_spot does not measure a session against itself" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 100)
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 50)

    @tool.call("action" => "change_precedence", "session_id" => session.id,
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)
    assert_equal 105, session.reload.precedence

    @tool.call("action" => "change_precedence", "session_id" => session.id,
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)

    assert_equal 105, session.reload.precedence, "a repeat placement is a no-op, not a ratchet"
  end

  # The other half of the self-exclusion: excluding the session stops the ratchet
  # upward, and flooring the result at the rank it already holds stops the
  # overshoot downward. Without the floor this session would be rewritten from
  # 1000 to 15 — still the head of the SPOT queue, but now beneath the priority
  # session carrying 500, which would outrank it on a later demotion.
  test "place top_of_spot never lowers the rank of a session already on top" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 10)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::PRIORITY, precedence: 500)
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 1_000)

    @tool.call("action" => "change_precedence", "session_id" => session.id,
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)

    assert_equal 1_000, session.reload.precedence
  end

  # The floor must not turn into a "never moves" rule: a session below the top
  # still gets placed above it.
  test "place top_of_spot still raises a session that is not on top" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 800)
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 1)

    @tool.call("action" => "change_precedence", "session_id" => session.id,
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)

    assert_equal 805, session.reload.precedence
  end

  test "change_scheduling_class can demote a session straight to the head of the queue" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 120)
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::PRIORITY, precedence: 0)

    output = @tool.call("action" => "change_scheduling_class", "session_id" => session.id,
      "scheduling_class" => "spot", "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)

    session.reload
    assert session.spot?
    assert_equal 120 + SessionPrecedence::SLOT_GAP, session.precedence
    assert_includes output, "- **Precedence:** 125 (was 0)"
    assert_includes session.logs.pluck(:content), "Precedence set via MCP to 125 (was 0)"
  end

  # A placement applies whichever class the session is being moved to. Precedence
  # is carried on a priority session too, and is what a later demotion lands on,
  # so a caller that names a placement on a promotion means it — unlike the
  # Ranked view's demote button, which only ever sends one on a demotion.
  test "change_scheduling_class honours place on a promotion as well as a demotion" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 60)
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 0)

    @tool.call("action" => "change_scheduling_class", "session_id" => session.id,
      "scheduling_class" => "priority", "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)

    session.reload
    assert session.priority?
    assert_equal 65, session.precedence, "the rank it will land on if it is demoted again"
  end

  # `place` wins over an explicitly-null `precedence` rather than tripping the
  # mutual-exclusion check: a null is the argument left out, not a value.
  test "place alongside an explicitly null precedence is the placement, not an error" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 200)
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 0)

    @tool.call("action" => "change_precedence", "session_id" => session.id,
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT, "precedence" => nil)

    assert_equal 205, session.reload.precedence
  end

  test "change_precedence still requires one of the two, and names both" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_precedence", "session_id" => sessions(:needs_input).id)
    end

    assert_match(/"precedence" parameter is required/, error.message)
    assert_match(/top_of_spot/, error.message)
  end

  test "place and precedence together are a tool error" do
    session = sessions(:needs_input)
    session.update!(precedence: 7)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_precedence", "session_id" => session.id,
        "place" => SessionPrecedence::PLACE_TOP_OF_SPOT, "precedence" => 50)
    end

    assert_match(/mutually exclusive/, error.message)
    assert_equal 7, session.reload.precedence, "and nothing moved"
  end

  test "an unknown place is a tool error" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_precedence", "session_id" => sessions(:needs_input).id,
        "place" => "bottom_of_spot")
    end

    assert_match(/Unknown place/, error.message)
  end

  # Passing neither leaves a demotion exactly where it was before the argument
  # existed: on whatever rank the session already carried.
  test "change_scheduling_class without place or precedence leaves the rank alone" do
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::PRIORITY, precedence: 33)

    @tool.call("action" => "change_scheduling_class", "session_id" => session.id,
      "scheduling_class" => "spot")

    assert_equal 33, session.reload.precedence
  end

  test "the place argument is advertised on the schema and says when to use it" do
    place = Mcp::Tools::ActionSession.input_schema.to_h.dig(:properties, :place)

    assert_equal [ SessionPrecedence::PLACE_TOP_OF_SPOT ], place[:enum]
    assert_match(/head of the spot queue/i, place[:description])
    assert_match(/mutually exclusive/i, place[:description])
  end

  # The prose every agent reads before ranking work: it must no longer teach the
  # racy two-call recipe the symbolic form replaces.
  test "the precedence description points at the placement instead of a read-then-write" do
    description = Mcp::Tools::ActionSession.input_schema.to_h.dig(:properties, :precedence, :description)

    assert_match(/top_of_spot/, description)
    refute_match(/read the current top with quick_search_sessions and pass a few points above it/, description)
  end

  test "rejects an unknown action" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "self_destruct", "session_id" => sessions(:needs_input).id) }
    assert_match(/Unknown action/, error.message)
  end

  test "requires session_id for session-scoped actions" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "pause") }
    assert_match(/"session_id" parameter is required/, error.message)
  end

  test "follow_up sends the prompt immediately to an idle session" do
    session = sessions(:needs_input)

    result = nil
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Keep going" ]) do
      result = @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Keep going")
    end

    assert_includes result, "## Follow-up Sent"
    assert_includes result, "- **Message:** Follow-up prompt sent"
    assert_equal "running", session.reload.status
    assert_equal "Keep going", session.prompt
  end

  test "follow_up queues the prompt for a running session" do
    session = sessions(:running)

    result = assert_difference "session.enqueued_messages.count", 1 do
      @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Queued work")
    end

    assert_includes result, "## Follow-up Sent"
    assert_includes result, "Message queued (session is running)"
    assert_equal "running", session.reload.status
  end

  test "follow_up requires a prompt" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "follow_up", "session_id" => sessions(:needs_input).id) }
    assert_match(/"prompt" parameter is required/, error.message)
  end

  # A follow_up goal must behave the same on all three delivery branches — sent
  # directly, queued, or interrupted in — matching POST /api/v1/sessions/:id/follow_up.
  test "follow_up applies a goal when it sends the prompt immediately" do
    session = sessions(:needs_input)
    session.update!(goal: "old condition")

    @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Keep going", "goal" => "new condition")

    assert_equal "new condition", session.reload.goal
  end

  test "follow_up preserves the session goal when the goal is omitted" do
    session = sessions(:needs_input)
    session.update!(goal: "existing goal")

    @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "No goal change")

    assert_equal "existing goal", session.reload.goal
  end

  test "follow_up preserves the session goal when the goal is blank" do
    session = sessions(:waiting)
    session.update!(goal: "existing goal")

    @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Blank goal", "goal" => "  ")

    assert_equal "existing goal", session.reload.goal
  end

  test "follow_up applies the goal when force_immediate interrupts a running session" do
    session = sessions(:running)
    session.update!(goal: "old condition")

    @tool.call(
      "action" => "follow_up",
      "session_id" => session.id,
      "prompt" => "Urgent work",
      "goal" => "new condition",
      "force_immediate" => true
    )

    assert_equal "new condition", session.reload.goal
  end

  test "follow_up carries the goal on the message it queues for a running session" do
    session = sessions(:running)

    @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Queued work", "goal" => "PR is merged")

    assert_equal "PR is merged", session.enqueued_messages.last.goal
  end

  test "follow_up leaves the queued message's goal empty when none is given" do
    session = sessions(:running)
    session.update!(goal: "existing goal")

    @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Queued work")

    assert_nil session.enqueued_messages.last.goal
    assert_equal "existing goal", session.reload.goal
  end

  test "follow_up logs a goal change" do
    session = sessions(:needs_input)
    session.update!(goal: "old condition")

    @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Goal changed", "goal" => "new condition")

    assert_equal 1, session.logs.where(content: "Goal updated from follow-up").count
  end

  test "follow_up does not log when the goal is unchanged" do
    session = sessions(:needs_input)
    session.update!(goal: "same goal")

    @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Goal unchanged", "goal" => "same goal")

    assert_equal 0, session.logs.where(content: "Goal updated from follow-up").count
    assert_equal "same goal", session.reload.goal
  end

  test "follow_up rejects a goal that is too long without sending the prompt" do
    session = sessions(:needs_input)
    session.update!(goal: "existing goal")

    error = nil
    assert_no_enqueued_jobs only: AgentSessionJob do
      error = assert_raises(Mcp::ToolError) do
        @tool.call(
          "action" => "follow_up",
          "session_id" => session.id,
          "prompt" => "Keep going",
          "goal" => "x" * (Session::GOAL_MAX_LENGTH + 1)
        )
      end
    end

    assert_match(/goal is too long/, error.message)
    session.reload
    assert_equal "existing goal", session.goal
    assert_equal "needs_input", session.status
  end

  test "the goal parameter documents its follow_up behavior in the tool schema" do
    properties = Mcp::Tools::ActionSession.to_h.deep_symbolize_keys.dig(:inputSchema, :properties)

    assert properties[:goal].present?, "action_session should accept a goal parameter"
    assert_match(/follow_up/, properties[:goal][:description])
  end

  test "pause pauses a running session and marks it user-paused" do
    session = sessions(:running)

    result = @tool.call("action" => "pause", "session_id" => session.id)

    assert_includes result, "## Session Paused"
    session.reload
    assert_equal "needs_input", session.status
    assert_equal "user", session.metadata["paused_by"]
  end

  test "pause refuses a session that is not running" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "pause", "session_id" => sessions(:needs_input).id) }
    assert_match(/not running/, error.message)
  end

  test "archive archives a session" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "archive", "session_id" => session.id)

    assert_includes result, "## Session Archived"
    assert_includes result, "- **New Status:** archived"
    assert_equal "archived", session.reload.status
    assert session.archived_at.present?
  end

  test "archive records a declared caller as the actor on the archived session" do
    session = sessions(:needs_input)

    @tool.call("action" => "archive", "session_id" => session.id, "acting_session_id" => 5225)

    line = session.reload.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_equal "[State Machine] Session moved to trash by session #5225 via the MCP API", line
  end

  test "archive records an undeclared caller as undeclared rather than inventing one" do
    session = sessions(:needs_input)

    @tool.call("action" => "archive", "session_id" => session.id)

    line = session.reload.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_equal "[State Machine] Session moved to trash by an undeclared MCP API caller", line
  end

  test "archive ignores an acting_session_id that is not a session id" do
    session = sessions(:needs_input)

    @tool.call("action" => "archive", "session_id" => session.id, "acting_session_id" => "not-an-id")

    line = session.reload.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_equal "[State Machine] Session moved to trash by an undeclared MCP API caller", line
  end

  test "archive refuses an already archived session" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive", "session_id" => sessions(:archived).id) }
    assert_match(/cannot be trashed/, error.message)
  end

  # The incident this refusal exists for: an agent finishes a task, self-archives,
  # and the message that arrived mid-turn is dropped by the archive itself —
  # AgentSessionJob terminates the process instead of pausing and draining the
  # queue (production session 6073).
  test "archive refuses a running session that still has messages queued" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "add the onion back", position: 1, status: "pending")

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive", "session_id" => session.id) }

    assert_match(/Cannot archive session #{session.id}/, error.message)
    assert_includes error.message, "1 queued message has not been delivered"
    assert_includes error.message, "add the onion back"
    assert_includes error.message, "Do not archive"
    assert_includes error.message, "\"force\": true"
    assert_equal "running", session.reload.status, "the refusal must not half-archive"
    assert_equal "pending", session.enqueued_messages.sole.status,
      "the message is still going to be delivered, so it stays pending"
  end

  # `force` is what lets the refusal cover every state without turning it into a
  # trap, so it has to actually work — and the discard still has to be recorded.
  test "archive with force goes through and still records the discard" do
    session = sessions(:running)
    queued = session.enqueued_messages.create!(content: "deliberately discarded", position: 1, status: "pending")

    result = @tool.call("action" => "archive", "session_id" => session.id, "force" => true)

    assert_includes result, "- **New Status:** archived"
    assert_equal "archived", session.reload.status
    assert_equal "undelivered", queued.reload.status, "a forced discard is still retired, not left pending"
    line = session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_includes line, "1 queued message was never delivered"
    assert_includes line, "deliberately discarded"
  end

  test "archive ignores a force that is not truthy" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")

    assert_raises(Mcp::ToolError) do
      @tool.call("action" => "archive", "session_id" => session.id, "force" => false)
    end
    assert_equal "running", session.reload.status
  end

  test "archive goes through once the queue has drained" do
    session = sessions(:running)
    message = session.enqueued_messages.create!(content: "add the onion back", position: 1, status: "pending")
    assert_raises(Mcp::ToolError) { @tool.call("action" => "archive", "session_id" => session.id) }

    message.destroy!

    @tool.call("action" => "archive", "session_id" => session.id)
    assert_equal "archived", session.reload.status
  end

  # A waiting session has a turn ahead of it too — EnqueuedMessageProcessorService
  # accepts `waiting` — so exempting it would lose messages that were going to
  # be delivered.
  test "archive refuses a waiting session that still has messages queued" do
    session = sessions(:waiting)
    session.enqueued_messages.create!(content: "queued before it started", position: 1, status: "pending")

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive", "session_id" => session.id) }

    assert_match(/Cannot archive session #{session.id}/, error.message)
    assert_equal "waiting", session.reload.status
    assert_equal "pending", session.enqueued_messages.sole.status
  end

  # Every state that can archive is covered, needs_input included. Nothing drains
  # a needs_input queue, which makes the discard there certain rather than merely
  # likely; `force` is what keeps a certain discard from being a trap.
  test "archive refuses a needs_input session that still has messages queued" do
    session = sessions(:needs_input)
    session.enqueued_messages.create!(content: "never sent", position: 1, status: "pending")

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive", "session_id" => session.id) }

    assert_match(/Cannot archive session #{session.id}/, error.message)
    assert_equal "needs_input", session.reload.status
  end

  test "archive refuses a failed session that still has messages queued" do
    session = sessions(:failed)
    session.enqueued_messages.create!(content: "never sent", position: 1, status: "pending")

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive", "session_id" => session.id) }

    assert_match(/Cannot archive session #{session.id}/, error.message)
    assert_equal "failed", session.reload.status
  end

  # The un-archivable trap the refusal would otherwise be: nothing will ever
  # drain a needs_input queue, so force has to be the way out.
  test "archive with force clears a needs_input session nothing would ever drain" do
    session = sessions(:needs_input)
    queued = session.enqueued_messages.create!(content: "never sent", position: 1, status: "pending")

    @tool.call("action" => "archive", "session_id" => session.id, "force" => true)

    assert_equal "archived", session.reload.status
    assert_equal "undelivered", queued.reload.status
  end

  test "bulk_archive reports the sessions it skipped for a queued message" do
    running_with_queue = sessions(:running)
    running_with_queue.enqueued_messages.create!(content: "add the onion back", position: 1, status: "pending")
    archivable = sessions(:needs_input)

    result = @tool.call("action" => "bulk_archive", "session_ids" => [ running_with_queue.id, archivable.id ])

    assert_includes result, "- **Archived:** 1"
    assert_includes result, "Session #{running_with_queue.id}: Cannot archive session #{running_with_queue.id}"
    assert_equal "running", running_with_queue.reload.status
    assert_equal "archived", archivable.reload.status
  end

  # One flag for the batch, not per session — the argument has nowhere to carry
  # a per-session choice, and the description says so.
  test "bulk_archive with force archives the whole batch and retires their queues" do
    running_with_queue = sessions(:running)
    queued = running_with_queue.enqueued_messages.create!(content: "discarded in bulk", position: 1, status: "pending")
    archivable = sessions(:needs_input)

    result = @tool.call(
      "action" => "bulk_archive",
      "session_ids" => [ running_with_queue.id, archivable.id ],
      "force" => true
    )

    assert_includes result, "- **Archived:** 2"
    assert_equal "archived", running_with_queue.reload.status
    assert_equal "undelivered", queued.reload.status
  end

  test "change_mcp_servers replaces the session's servers" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "change_mcp_servers", "session_id" => session.id, "mcp_servers" => [ "context7" ])

    assert_includes result, "## MCP Servers Updated"
    assert_includes result, "- **MCP Servers:** context7"
    assert_equal [ "context7" ], session.reload.mcp_servers
  end

  # Clearing the list already returned "(none)" before this fix, and then the job
  # started and McpServerBackfill restored the root's defaults. Recording the
  # choice is what makes the cleared list survive to job start.
  test "change_mcp_servers records an emptied list as a deliberate none" do
    session = sessions(:needs_input)
    session.update!(mcp_servers: [ "context7" ])

    result = @tool.call("action" => "change_mcp_servers", "session_id" => session.id, "mcp_servers" => [])

    assert_includes result, "## MCP Servers Updated"
    assert_equal [], session.reload.mcp_servers
    assert session.mcp_servers_explicitly_empty?
  end

  test "change_mcp_servers clears the deliberate-none flag when servers are added back" do
    session = sessions(:needs_input)
    @tool.call("action" => "change_mcp_servers", "session_id" => session.id, "mcp_servers" => [])
    assert session.reload.mcp_servers_explicitly_empty?

    @tool.call("action" => "change_mcp_servers", "session_id" => session.id, "mcp_servers" => [ "context7" ])

    refute session.reload.mcp_servers_explicitly_empty?
  end

  test "change_mcp_servers rejects servers outside the catalog" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_mcp_servers", "session_id" => sessions(:needs_input).id, "mcp_servers" => [ "not-a-server" ])
    end
    assert_match(/Invalid MCP servers/, error.message)
  end

  test "change_mcp_servers is refused on a restricted connection" do
    restricted = Mcp::Tools::ActionSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "zimmer")
    )

    error = assert_raises(Mcp::ToolError) do
      restricted.call("action" => "change_mcp_servers", "session_id" => sessions(:needs_input).id, "mcp_servers" => [ "context7" ])
    end
    assert_match(/not allowed when this connection is restricted/, error.message)
    assert_equal [], sessions(:needs_input).reload.mcp_servers
  end

  test "change_model updates the model and rejects models outside the runtime catalog" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "change_model", "session_id" => session.id, "model" => "fable")
    assert_includes result, "## Model Updated"
    assert_includes result, "- **Model:** fable"
    assert_equal "fable", session.reload.config["model"]

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_model", "session_id" => session.id, "model" => "gpt-imaginary")
    end
    assert_match(/is not valid for runtime/, error.message)
  end

  test "change_model accepts GPT 5.6 models for Codex sessions" do
    session = sessions(:needs_input)
    session.update!(agent_runtime: "codex", config: { "model" => "gpt-5.5" })

    result = @tool.call("action" => "change_model", "session_id" => session.id, "model" => "gpt-5.6-terra")

    assert_includes result, "## Model Updated"
    assert_includes result, "- **Model:** gpt-5.6-terra"
    assert_equal "gpt-5.6-terra", session.reload.config["model"]

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_model", "session_id" => session.id, "model" => "fable")
    end
    assert_match(/is not valid for runtime codex/, error.message)
  end

  # --- Catalog list fields (skills / hooks / plugins) -----------------------

  test "change_skills replaces the session's catalog skills" do
    session = sessions(:needs_input)
    session.update!(catalog_skills: [ "sync-docs" ])

    result = @tool.call("action" => "change_skills", "session_id" => session.id, "skills" => [ "zimmer-run-tests" ])

    assert_includes result, "## Skills Updated"
    assert_includes result, "- **Skills:** zimmer-run-tests"
    # Replace, not merge: sync-docs is gone.
    assert_equal [ "zimmer-run-tests" ], session.reload.catalog_skills
  end

  test "change_skills rejects unknown skill IDs and lists valid options" do
    session = sessions(:needs_input)
    session.update!(catalog_skills: [ "sync-docs" ])

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_skills", "session_id" => session.id, "skills" => [ "zimmer-run-tests", "not-a-skill" ])
    end

    assert_match(/Invalid skills: not-a-skill/, error.message)
    assert_match(/Valid skills:/, error.message)
    assert_match(/sync-docs/, error.message)
    # The invalid value must not have been persisted.
    assert_equal [ "sync-docs" ], session.reload.catalog_skills
  end

  test "change_skills requires the skills parameter" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "change_skills", "session_id" => sessions(:needs_input).id) }
    assert_match(/"skills" parameter is required/, error.message)
  end

  test "change_hooks replaces the session's catalog hooks" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "change_hooks", "session_id" => session.id, "hooks" => [ "git-push-ci-reminder" ])

    assert_includes result, "## Hooks Updated"
    assert_equal [ "git-push-ci-reminder" ], session.reload.catalog_hooks
  end

  test "change_hooks rejects unknown hook IDs" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_hooks", "session_id" => sessions(:needs_input).id, "hooks" => [ "not-a-hook" ])
    end
    assert_match(/Invalid hooks: not-a-hook/, error.message)
  end

  test "change_hooks requires the hooks parameter" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "change_hooks", "session_id" => sessions(:needs_input).id) }
    assert_match(/"hooks" parameter is required/, error.message)
  end

  test "change_plugins replaces the session's catalog plugins" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "change_plugins", "session_id" => session.id, "plugins" => [ "ci-workflow" ])

    assert_includes result, "## Plugins Updated"
    assert_equal [ "ci-workflow" ], session.reload.catalog_plugins
  end

  test "change_plugins rejects unknown plugin IDs" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_plugins", "session_id" => sessions(:needs_input).id, "plugins" => [ "not-a-plugin" ])
    end
    assert_match(/Invalid plugins: not-a-plugin/, error.message)
  end

  test "change_plugins is refused on a restricted connection" do
    restricted = Mcp::Tools::ActionSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "zimmer")
    )

    error = assert_raises(Mcp::ToolError) do
      restricted.call("action" => "change_plugins", "session_id" => sessions(:needs_input).id, "plugins" => [ "ci-workflow" ])
    end
    assert_match(/not allowed when this connection is restricted/, error.message)
    assert_equal [], sessions(:needs_input).reload.catalog_plugins
  end

  test "change_skills is allowed on a restricted connection (skills are not locked)" do
    restricted = Mcp::Tools::ActionSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "zimmer")
    )
    session = sessions(:needs_input)

    result = restricted.call("action" => "change_skills", "session_id" => session.id, "skills" => [ "zimmer-run-tests" ])
    assert_includes result, "## Skills Updated"
    assert_equal [ "zimmer-run-tests" ], session.reload.catalog_skills
  end

  test "change_skills clears the list when given an empty array" do
    session = sessions(:needs_input)
    session.update!(catalog_skills: [ "sync-docs" ])

    result = @tool.call("action" => "change_skills", "session_id" => session.id, "skills" => [])

    assert_includes result, "- **Skills:** (none)"
    assert_equal [], session.reload.catalog_skills
  end

  # --- goal / auto_compact_window / category / blocked / push ---------------

  test "change_goal sets and clears the goal" do
    session = sessions(:needs_input)

    set_result = @tool.call("action" => "change_goal", "session_id" => session.id, "goal" => "Ship the PR")
    assert_includes set_result, "## Goal Updated"
    assert_includes set_result, "- **Goal:** Ship the PR"
    assert_equal "Ship the PR", session.reload.goal

    clear_result = @tool.call("action" => "change_goal", "session_id" => session.id, "goal" => "")
    assert_includes clear_result, "- **Goal:** (none)"
    assert_nil session.reload.goal
  end

  test "change_goal requires the goal parameter" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "change_goal", "session_id" => sessions(:needs_input).id) }
    assert_match(/"goal" parameter is required/, error.message)
  end

  test "change_goal rejects an over-length goal" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_goal", "session_id" => sessions(:needs_input).id, "goal" => "x" * (Session::GOAL_MAX_LENGTH + 1))
    end
    assert_match(/Goal is too long/, error.message)
  end

  test "change_auto_compact_window updates the window and rejects invalid values" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "change_auto_compact_window", "session_id" => session.id, "auto_compact_window" => 1_000_000)
    assert_includes result, "## Context Window Updated"
    assert_includes result, "- **Auto-compact Window:** 1000000 tokens"
    assert_equal 1_000_000, session.reload.auto_compact_window

    too_big = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_auto_compact_window", "session_id" => session.id, "auto_compact_window" => 9_999_999)
    end
    assert_match(/must be between 1 and/, too_big.message)

    not_int = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_auto_compact_window", "session_id" => session.id, "auto_compact_window" => "lots")
    end
    assert_match(/must be a positive integer/, not_int.message)

    # 0 fails the /\A\d+\z/-then-bounds path (it parses but is out of range).
    zero = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_auto_compact_window", "session_id" => session.id, "auto_compact_window" => 0)
    end
    assert_match(/must be between 1 and/, zero.message)
  end

  test "change_category assigns and clears the organizational category" do
    session = sessions(:needs_input)
    category = Category.create!(name: "Infra")

    assign = @tool.call("action" => "change_category", "session_id" => session.id, "category_id" => category.id)
    assert_includes assign, "## Category Updated"
    assert_includes assign, "- **Category:** Infra"
    assert_equal category.id, session.reload.category_id

    clear = @tool.call("action" => "change_category", "session_id" => session.id, "category_id" => nil)
    assert_includes clear, "- **Category:** (uncategorized)"
    assert_nil session.reload.category_id
  end

  test "change_category rejects an unknown category" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_category", "session_id" => sessions(:needs_input).id, "category_id" => 999_999)
    end
    assert_match(/Category #999999 not found/, error.message)
  end

  test "change_category requires the category_id key" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "change_category", "session_id" => sessions(:needs_input).id) }
    assert_match(/"category_id" parameter is required/, error.message)
  end

  test "toggle_push_notifications flips the push flag" do
    session = sessions(:needs_input)
    session.update!(push_notifications_enabled: false)

    result = @tool.call("action" => "toggle_push_notifications", "session_id" => session.id)

    assert_includes result, "- **Push Notifications:** Enabled"
    assert session.reload.push_notifications_enabled
  end

  test "set_heartbeat toggles the heartbeat and sets the interval" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "set_heartbeat", "session_id" => session.id, "enabled" => true, "interval_seconds" => 120)

    assert_includes result, "## Heartbeat Updated"
    assert_includes result, "- **Heartbeat Enabled:** Yes"
    assert_includes result, "- **Interval:** 120 seconds"
    session.reload
    assert session.heartbeat_enabled
    assert_equal 120, session.heartbeat_interval_seconds
  end

  test "set_heartbeat requires at least one setting and a valid interval" do
    session = sessions(:needs_input)

    missing = assert_raises(Mcp::ToolError) { @tool.call("action" => "set_heartbeat", "session_id" => session.id) }
    assert_match(/at least one of/, missing.message)

    out_of_range = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "set_heartbeat", "session_id" => session.id, "interval_seconds" => 5)
    end
    assert_match(/must be between/, out_of_range.message)
  end

  test "update_notes and update_title write to the session" do
    session = sessions(:needs_input)

    notes_result = @tool.call("action" => "update_notes", "session_id" => session.id, "session_notes" => "Blocked on review")
    assert_includes notes_result, "## Session Notes Updated"
    assert_equal "Blocked on review", session.reload.session_notes
    assert session.session_notes_updated_at.present?

    title_result = @tool.call("action" => "update_title", "session_id" => session.id, "title" => "New title")
    assert_includes title_result, "## Session Title Updated"
    assert_equal "New title", session.reload.title
  end

  test "update_notes and update_title require their parameter" do
    session = sessions(:needs_input)

    notes_error = assert_raises(Mcp::ToolError) { @tool.call("action" => "update_notes", "session_id" => session.id) }
    assert_match(/"session_notes" parameter is required/, notes_error.message)

    title_error = assert_raises(Mcp::ToolError) { @tool.call("action" => "update_title", "session_id" => session.id) }
    assert_match(/"title" parameter is required/, title_error.message)
  end

  test "toggle_favorite flips the favorited flag" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "toggle_favorite", "session_id" => session.id)

    assert_includes result, "- **Favorited:** Yes"
    assert session.reload.favorited
  end

  test "bulk_archive archives the given sessions and reports failures" do
    archivable = sessions(:needs_input)
    already_archived = sessions(:archived)

    result = @tool.call("action" => "bulk_archive", "session_ids" => [ archivable.id, already_archived.id ])

    assert_includes result, "## Bulk Archive Complete"
    assert_includes result, "- **Archived:** 1"
    assert_equal "archived", archivable.reload.status
  end

  test "bulk_archive records the actor on each session it archives" do
    archivable = sessions(:needs_input)

    @tool.call("action" => "bulk_archive", "session_ids" => [ archivable.id ], "acting_session_id" => 5225)

    line = archivable.reload.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_equal "[State Machine] Session moved to trash by session #5225 via the MCP API (bulk)", line
  end

  test "bulk_archive requires session_ids" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "bulk_archive", "session_ids" => []) }
    assert_match(/"session_ids" parameter is required/, error.message)
  end

  test "fork requires a message_index" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "fork", "session_id" => sessions(:with_transcript).id) }
    assert_match(/"message_index" parameter is required/, error.message)
  end

  test "refresh reports when the session has no clone path" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "refresh", "session_id" => sessions(:needs_input).id) }
    assert_match(/No clone path/, error.message)
  end

  test "refresh_all reports its counters and needs no session_id" do
    result = @tool.call("action" => "refresh_all")

    assert_includes result, "## All Sessions Refreshed"
    assert_includes result, "- **Restarted:**"
    assert_includes result, "- **Errors:** 0"
  end

  # Parity with POST /api/v1/sessions/refresh_all (#80): the tool reported a
  # hardcoded "Refreshed: 0" no matter how many transcripts it re-read.
  test "refresh_all counts the sessions whose transcripts it re-read" do
    session = sessions(:running)
    Session.where.not(id: session.id).update_all(status: Session.statuses[:archived])

    fresh = [
      { type: "user", message: { role: "user", content: "one" } },
      { type: "assistant", message: { role: "assistant", content: "two" } }
    ].map { |e| JSON.generate(e) }.join("\n")

    Dir.mktmpdir do |dir|
      file = File.join(dir, "main.jsonl")
      File.write(file, fresh)

      @tool.stubs(:transcript_directory).returns(dir)
      TranscriptFileLocator.stubs(:find_main_transcript).returns(file)

      result = @tool.call("action" => "refresh_all")

      assert_includes result, "- **Refreshed:** 1"
      assert_equal fresh, session.reload.transcript
      assert_equal 2, session.metadata["broadcast_message_count"]
    end
  end

  test "refresh_all reports zero refreshed when nothing is readable from disk" do
    session = sessions(:running)
    Session.where.not(id: session.id).update_all(status: Session.statuses[:archived])

    @tool.stubs(:transcript_directory).returns(nil)

    assert_includes @tool.call("action" => "refresh_all"), "- **Refreshed:** 0"
    assert_nil session.reload.transcript
  end

  test "refresh_all does not count a transcript identical to the stored one" do
    session = sessions(:running)
    Session.where.not(id: session.id).update_all(status: Session.statuses[:archived])

    stored = JSON.generate({ type: "user", message: { role: "user", content: "unchanged" } })
    session.update!(transcript: stored)

    Dir.mktmpdir do |dir|
      file = File.join(dir, "main.jsonl")
      File.write(file, stored)

      @tool.stubs(:transcript_directory).returns(dir)
      TranscriptFileLocator.stubs(:find_main_transcript).returns(file)

      assert_no_difference "session.logs.count" do
        assert_includes @tool.call("action" => "refresh_all"), "- **Refreshed:** 0"
      end
    end
  end

  # Readable content is staged on disk on purpose: without the restarted_ids
  # guard this session WOULD be re-read, so the test fails if the guard goes.
  test "refresh_all does not re-read a session it just restarted" do
    failed = sessions(:failed)
    Session.where.not(id: failed.id).update_all(status: Session.statuses[:archived])

    Dir.mktmpdir do |dir|
      file = File.join(dir, "main.jsonl")
      File.write(file, JSON.generate({ type: "user", message: { role: "user", content: "from disk" } }))

      @tool.stubs(:transcript_directory).returns(dir)
      TranscriptFileLocator.stubs(:find_main_transcript).returns(file)

      result = @tool.call("action" => "refresh_all")

      assert_includes result, "- **Restarted:** 1"
      assert_includes result, "- **Refreshed:** 0"
      assert_nil failed.reload.transcript, "the restarted session's transcript must be left for its new job"
    end
  end
  # Parking a session in the spot queue from MCP: an agent that has no
  # time worth naming can park itself in the queue instead of inventing one.
  test "pause_into_spot_queue parks a session with no wake trigger" do
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::PRIORITY)

    output = assert_no_difference "Trigger.count" do
      @tool.call("action" => "pause_into_spot_queue", "session_id" => session.id)
    end

    assert_includes output, "Parked In The Spot Queue"
    assert_includes output, "precedence #{session.precedence}"
    session.reload
    assert session.waiting?
    assert session.spot?, "a priority session cannot sit in the queue"
    assert SpotSessionPause.queued_by_user?(session)
    assert_not session.awaiting_scheduled_wake?
  end

  test "pause_into_spot_queue keeps a resume prompt for the sweep" do
    session = sessions(:needs_input)

    @tool.call("action" => "pause_into_spot_queue", "session_id" => session.id, "prompt" => "Pick the migration back up")

    assert_equal "Pick the migration back up", session.reload.metadata[SpotSessionPause::QUEUED_PROMPT]
  end

  # The gate the web UI enforces, enforced here too: a `waiting` session with no
  # session_id has never started — it is queued for spawn, not asleep.
  test "pause_into_spot_queue refuses a session that has never started" do
    queued = sessions(:waiting)
    assert_nil queued.session_id

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "pause_into_spot_queue", "session_id" => queued.id)
    end

    assert_match(/cannot be put in the spot queue/, error.message)
    assert_nil (queued.reload.metadata || {})[SpotSessionPause::PAUSED_REASON]
  end

  test "pause_into_spot_queue refuses a session that cannot be slept" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "pause_into_spot_queue", "session_id" => sessions(:archived).id)
    end

    assert_match(/cannot be put in the spot queue/, error.message)
  end

  # The default on a RUNNING session stays "sleeps when the turn ends", and that
  # is not an oversight: the commonest caller of this tool is a session parking
  # ITSELF, which cannot terminate the process waiting on this very call.
  test "pause_into_spot_queue leaves a running session's turn alone by default" do
    session = sessions(:running)

    output = @tool.call("action" => "pause_into_spot_queue", "session_id" => session.id)

    assert_includes output, "sleeps when the current turn ends"
    session.reload
    assert session.running?
    assert_equal true, session.metadata["pending_sleep"]
  end

  # ...and the web UI's behaviour is reachable for a caller driving somebody
  # else's running session, which is the surface the UI actually is.
  test "pause_into_spot_queue with halt stops the turn the way the web UI does" do
    session = sessions(:running)

    output = @tool.call("action" => "pause_into_spot_queue", "session_id" => session.id, "halt" => true)

    assert_includes output, "its turn was stopped"
    assert_not_includes output, "sleeps when the current turn ends"
    session.reload
    assert session.waiting?
    assert_nil session.metadata["pending_sleep"]
    assert SpotSessionPause.queued_by_user?(session)
  end

  test "halt is inert on a session that was not running" do
    session = sessions(:needs_input)

    output = @tool.call("action" => "pause_into_spot_queue", "session_id" => session.id, "halt" => true)

    assert_not_includes output, "its turn was stopped"
    assert session.reload.waiting?
  end

  # The self-management surface deliberately does not advertise it: a session
  # halting itself would kill the process waiting for the reply.
  # The narrowed schema is advertisement; this is the refusal. The action body is
  # inherited whole and reads args["halt"] directly, and no schema sets
  # additionalProperties: false — so a self-session caller passing the flag anyway
  # must not end up terminating the process waiting for the reply.
  test "the self-session variant refuses halt even when it is passed anyway" do
    session = sessions(:running)
    tool = Mcp::Tools::SelfSessionActionSession.new(context: Mcp::Context.new(tool_groups: "self_session"))

    output = tool.call("action" => "pause_into_spot_queue", "session_id" => session.id, "halt" => true)

    assert_includes output, "sleeps when the current turn ends"
    assert_not_includes output, "its turn was stopped"
    session.reload
    assert session.running?, "a session must not be able to halt itself through this surface"
    assert_equal true, session.metadata["pending_sleep"]
  end

  test "the self-session variant does not offer halt" do
    self_properties = Mcp::Tools::SelfSessionActionSession.input_schema.to_h[:properties].keys.map(&:to_s)
    assert_not_includes self_properties, "halt"
    assert_includes Mcp::Tools::ActionSession.input_schema.to_h[:properties].keys.map(&:to_s), "halt"
  end

  # --- restart from scratch ---------------------------------------------------
  #
  # `restart` re-runs the whole setup pipeline when setup never completed, and it
  # is the start path the fleet-maintenance skill drives after a quota recovery.
  # AgentSessionJob receives images and files ONLY as job arguments, so enqueuing
  # bare re-ran the original prompt with the screenshot silently missing (#746).

  def failed_before_setup_session
    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "here is the screenshot, fix this",
      status: :failed, metadata: { "failure_reason" => "git_clone_failed" }
    )
  end

  test "restart from scratch enqueues the replacement turn carrying the stored attachments" do
    session = failed_before_setup_session
    image = store_image_for(session)
    file = store_file_for(session, filename: "notes.txt", content: "read me")

    output = @tool.call("action" => "restart", "session_id" => session.id)

    assert_includes output, "Session restarted from scratch"
    assert_enqueued_with(
      job: AgentSessionJob,
      args: [
        session.id, nil,
        {
          images: [ { path: image[:path], media_type: "image/png" } ],
          files: [ { path: file[:path], original_filename: "notes.txt", size: "read me".bytesize } ]
        }
      ]
    )
    assert session.logs.where("content LIKE ?", "%carrying 1 image and 1 file%").exists?
  end

  # This path is taken when something has ALREADY gone wrong, and the fleet sweep
  # drives it unattended. A storage tree that cannot be read must cost the
  # attachments, never the restart.
  test "restart from scratch still restarts when the attachment storage cannot be read" do
    session = failed_before_setup_session
    store_image_for(session)

    output = nil
    ImageStorageService.stub(:stored_for, ->(*) { raise Errno::EACCES, "storage" }) do
      assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
        output = @tool.call("action" => "restart", "session_id" => session.id)
      end
    end

    assert_includes output, "Session restarted from scratch"
    assert_equal "running", session.reload.status
  end
end

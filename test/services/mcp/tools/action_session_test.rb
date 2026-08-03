# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "tmpdir"

class Mcp::Tools::ActionSessionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
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

  test "archive refuses an already archived session" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive", "session_id" => sessions(:archived).id) }
    assert_match(/cannot be trashed/, error.message)
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

  test "set_blocked sets and clears the blocked-by relationship" do
    session = sessions(:needs_input)
    blocker = sessions(:running)

    blocked = @tool.call("action" => "set_blocked", "session_id" => session.id, "blocked_by_session_id" => blocker.id)
    assert_includes blocked, "## Blocked-by Updated"
    assert_includes blocked, "- **Blocked By:** ##{blocker.id}"
    assert_equal blocker.id, session.reload.blocked_by_session_id

    cleared = @tool.call("action" => "set_blocked", "session_id" => session.id, "blocked_by_session_id" => nil)
    assert_includes cleared, "- **Blocked By:** (none)"
    assert_nil session.reload.blocked_by_session_id
  end

  test "set_blocked refuses to block a session by itself" do
    session = sessions(:needs_input)
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "set_blocked", "session_id" => session.id, "blocked_by_session_id" => session.id)
    end
    assert_match(/cannot be blocked by itself/, error.message)
  end

  test "set_blocked rejects a non-existent blocker session" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "set_blocked", "session_id" => sessions(:needs_input).id, "blocked_by_session_id" => 999_999)
    end
    assert_match(/Session #999999 not found/, error.message)
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
end

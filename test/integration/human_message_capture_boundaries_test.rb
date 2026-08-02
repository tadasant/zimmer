# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The crux of the feature: which input boundaries record a human, and
# — more importantly — which do not.
#
# Every case below arrives at the agent as a `user`-role turn. Most of them
# travel the SAME delivery path (Session#deliver_follow_up!, EnqueuedMessage,
# Sessions::InterruptService). The only thing separating "Tadas asked for this"
# from "an agent asked for this" is the authenticated actor at the boundary, so
# that is what these tests pin down. A regression here would be silent and
# dangerous: it would launder automation into authorization.
class HumanMessageCaptureBoundariesTest < ActionDispatch::IntegrationTest
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    BroadcastService.any_instance.stubs(:optimistic_user_message)
    AgentSessionJob.stubs(:enqueue_new_session).returns(stub(job_id: "job-1"))
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(stub(job_id: "job-2"))

    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
    @mcp_headers = {
      "X-API-Key" => @api_key,
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
  end

  teardown do
    ENV.delete("API_KEYS")
    Mocha::Mockery.instance.teardown
  end

  def idle_session
    @idle_session ||= Session.create!(
      agent_runtime: "claude_code",
      prompt: "initial",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )
  end

  def human_messages(session)
    session.human_messages.chronological
  end

  def mcp_call(tool, arguments)
    post "/mcp",
         params: {
           jsonrpc: "2.0", id: 1, method: "tools/call",
           params: { name: tool, arguments: arguments }
         }.to_json,
         headers: @mcp_headers
  end

  # ==========================================================================
  # MUST capture — a named human at the boundary
  # ==========================================================================

  test "a session Tadas creates in the web UI records his prompt" do
    assert_difference("HumanMessage.count", 1) do
      post sessions_url, params: {
        session: {
          agent_runtime: "claude_code",
          prompt: "Refactor the billing service",
          git_root: "https://github.com/test/repo.git",
          branch: "main"
        }
      }
    end

    event = HumanMessage.order(:id).last
    assert_equal "tadasant", event.author
    assert_equal HumanMessage::WEB_UI, event.channel
    assert_equal "Refactor the billing service", event.content
    assert_equal "web_ui.new_session", event.entry_point
  end

  test "a clone-only session records nothing until a human types something" do
    assert_no_difference("HumanMessage.count") do
      post sessions_url, params: {
        session: {
          agent_runtime: "claude_code",
          prompt: "",
          git_root: "https://github.com/test/repo.git",
          branch: "main"
        }
      }
    end
  end

  test "a quick router session Tadas starts himself records his prompt" do
    assert_difference("HumanMessage.count", 1) do
      post quick_prompt_sessions_url, params: { prompt: "Who owns the deploy runbook?" }
    end

    event = HumanMessage.order(:id).last
    assert_equal "tadasant", event.author
    assert_equal "Who owns the deploy runbook?", event.content
    assert_equal "web_ui.quick_prompt", event.entry_point
  end

  # The page-context block wrapped around the prompt is written by Zimmer, not
  # by the human — only what the human typed is recorded.
  test "the chat bubble records the human's words, not the page-context wrapper" do
    assert_difference("HumanMessage.count", 1) do
      post chat_bubble_sessions_url, params: {
        prompt: "What is this session doing?",
        page_context: "SOME MACHINE-WRITTEN PAGE CONTEXT",
        current_url: "https://zimmer.example/sessions/1"
      }
    end

    event = HumanMessage.order(:id).last
    assert_equal "What is this session doing?", event.content
    refute_includes event.content, "MACHINE-WRITTEN"
  end

  test "a follow-up Tadas types in the web UI is recorded" do
    session = idle_session

    assert_difference("HumanMessage.count", 1) do
      post follow_up_session_url(session), params: { follow_up_prompt: "also update the docs" }
    end

    event = human_messages(session).last
    assert_equal "tadasant", event.author
    assert_equal "also update the docs", event.content
    assert_equal "web_ui.follow_up", event.entry_point
  end

  test "a web UI follow-up redirected to the queue is still recorded" do
    session = sessions(:running)

    assert_difference("HumanMessage.count", 1) do
      post follow_up_session_url(session), params: { follow_up_prompt: "queue this one" }
    end

    assert_equal "web_ui.follow_up_queued", human_messages(session).last.entry_point
  end

  # An edit is a second thing the human said. The record keeps both: the original
  # was genuinely typed, and the edit is what the agent will actually receive.
  test "editing a queued message in the web UI is recorded too" do
    session = sessions(:running)
    post session_enqueued_messages_url(session), params: { content: "first draft" }
    message = session.enqueued_messages.order(:id).last

    assert_difference("HumanMessage.count", 1) do
      patch session_enqueued_message_url(session, message), params: { content: "what I actually meant" }
    end

    recorded = human_messages(session).last
    assert_equal "what I actually meant", recorded.content
    assert_equal "web_ui.enqueued_message_edited", recorded.entry_point
    assert_equal "what I actually meant", message.reload.content
  end

  test "a message Tadas enqueues in the web UI is recorded when he types it" do
    session = sessions(:running)

    assert_difference("HumanMessage.count", 1) do
      post session_enqueued_messages_url(session), params: { content: "and then deploy" }
    end

    event = human_messages(session).last
    assert_equal "and then deploy", event.content
    assert_equal "web_ui.enqueued_message", event.entry_point
  end

  # ==========================================================================
  # MUST NOT capture — the boundary establishes an API key, not a person
  # ==========================================================================

  # The single most important distinction in the feature. Same session, same
  # action name, same delivery path — one is Tadas, one is another agent.
  test "an agent-issued follow_up over MCP records nothing, unlike the human-issued one" do
    session = idle_session

    assert_difference("HumanMessage.count", 1) do
      post follow_up_session_url(session), params: { follow_up_prompt: "human turn" }
    end

    session.update!(status: :needs_input)

    assert_no_difference("HumanMessage.count") do
      mcp_call("action_session", {
        "session_id" => session.id, "action" => "follow_up", "prompt" => "agent turn"
      })
    end
    assert_response :success

    contents = human_messages(session).map(&:content)
    assert_equal [ "human turn" ], contents
  end

  test "an agent-issued force_immediate follow_up over MCP records nothing" do
    session = sessions(:running)

    assert_no_difference("HumanMessage.count") do
      mcp_call("action_session", {
        "session_id" => session.id, "action" => "follow_up",
        "prompt" => "barge in", "force_immediate" => true
      })
    end
  end

  test "an agent queueing a message over MCP records nothing" do
    session = sessions(:running)

    assert_no_difference("HumanMessage.count") do
      mcp_call("manage_enqueued_messages", {
        "session_id" => session.id, "action" => "create", "content" => "agent-queued"
      })
    end
    assert_response :success
    assert session.enqueued_messages.where(content: "agent-queued").exists?,
           "the message must still be delivered — only the human-message record is withheld"
  end

  test "an agent send_now over MCP records nothing" do
    session = sessions(:running)

    assert_no_difference("HumanMessage.count") do
      mcp_call("manage_enqueued_messages", {
        "session_id" => session.id, "action" => "send_now", "content" => "agent send_now"
      })
    end
  end

  # A router holding a human's words is still a machine when it composes the
  # downstream prompt.
  test "a router-written downstream session prompt records nothing" do
    assert_no_difference("HumanMessage.count") do
      mcp_call("start_session", {
        "agent_root" => "zimmer",
        "prompt" => "Tadas asked for the billing refactor — go do it"
      })
    end
    assert_response :success
  end

  test "a follow_up through the REST API records nothing" do
    session = idle_session

    assert_no_difference("HumanMessage.count") do
      post "/api/v1/sessions/#{session.id}/follow_up",
           params: { prompt: "api turn" }.to_json,
           headers: { "X-API-Key" => @api_key, "Content-Type" => "application/json" }
    end
    assert_response :success
  end

  # ==========================================================================
  # MUST NOT capture — intra-session machinery
  # ==========================================================================

  test "a scheduled wake-up the session scheduled for itself records nothing" do
    session = idle_session
    trigger = triggers(:new_slack_trigger)
    trigger.update!(reuse_session: true, last_session_id: session.id)

    assert_no_difference("HumanMessage.count") do
      trigger.create_session!(prompt: "Time to check on that PR")
    end

    # deliver_follow_up! stamps the prompt into metadata and enqueues the job; it
    # does not write the `prompt` column, so that is what "delivered" looks like.
    assert_equal "Time to check on that PR", session.reload.metadata["pending_follow_up_prompt"],
                 "the wake-up must still be delivered — only the human-message record is withheld"
  end

  test "a heartbeat nudge records nothing" do
    session = idle_session

    assert_no_difference("HumanMessage.count") do
      session.deliver_follow_up!(AutomatedPrompts::HEARTBEAT, stamp_pending_prompt: false)
    end
  end

  test "an automated resumption prompt records nothing" do
    session = idle_session

    assert_no_difference("HumanMessage.count") do
      session.deliver_follow_up!(AutomatedPrompts::SYSTEM_RECOVERY)
    end
  end

  # The trap: `attribution` on a polled GitHub comment frequently reads
  # `tadasant`, because every agent in the fleet pushes through that one shared
  # GitHub account. It establishes no human author.
  test "a polled GitHub comment records nothing even when attributed to tadasant" do
    session = idle_session
    session.merge_custom_metadata!(
      "github_comments" => [ { "body" => "please merge this", "attribution" => "tadasant" } ]
    )

    assert_no_difference("HumanMessage.count") do
      session.deliver_follow_up!("New PR comment from tadasant: please merge this")
    end
    assert_empty human_messages(session)
  end

  # ==========================================================================
  # Slack — resolved from the user identity, never assumed
  # ==========================================================================

  test "a Slack message from a mapped human records that human's own words" do
    users(:juliehazz).update!(slack_user_ids: %w[U07JULIE])
    session = idle_session

    event = HumanMessageCapture.record_slack_message(
      session: session,
      slack_user_id: "U07JULIE",
      content: "the rest should all be actioned",
      entry_point: "slack.channel_message",
      slack_channel: "general",
      slack_permalink: "https://slack.example/p1"
    )

    assert_equal "juliehazz", event.author
    assert_equal HumanMessage::SLACK, event.channel
    assert_equal "the rest should all be actioned", event.content
    assert_equal "general", event.slack_channel_name
    assert_equal "https://slack.example/p1", event.slack_permalink
  end

  # The trigger's prompt_template is machine-written. Only the human's own
  # message text is human-authored.
  test "a Slack trigger records the human message, not the rendered prompt template" do
    users(:tadasant).update!(slack_user_ids: %w[U01TADAS])
    session = idle_session
    trigger = triggers(:new_slack_trigger)
    trigger.update!(prompt_template: "MACHINE PREAMBLE — act on this message: {{text}}")
    rendered = trigger.interpolate_prompt(text: "please bump the version")

    HumanMessageCapture.record_slack_message(
      session: session,
      slack_user_id: "U01TADAS",
      content: "please bump the version",
      entry_point: "slack.channel_message"
    )

    event = human_messages(session).last
    assert_equal "please bump the version", event.content
    refute_includes event.content, "MACHINE PREAMBLE"
    assert_includes rendered, "MACHINE PREAMBLE"
  end

  # `user_allowed?` means "may fire this trigger" — not "is Tadas or Julie".
  test "a Slack message from an unmapped user records nothing" do
    users(:tadasant).update!(slack_user_ids: %w[U01TADAS])
    session = idle_session

    assert_no_difference("HumanMessage.count") do
      HumanMessageCapture.record_slack_message(
        session: session,
        slack_user_id: "U99SOMEONE_ELSE",
        content: "hello from a stranger",
        entry_point: "slack.channel_message"
      )
    end
  end

  test "an unconfigured deployment attributes no Slack message to anyone" do
    session = idle_session

    assert_no_difference("HumanMessage.count") do
      HumanMessageCapture.record_slack_message(
        session: session,
        slack_user_id: "U01TADAS",
        content: "hi",
        entry_point: "slack.channel_message"
      )
    end
  end

  # ==========================================================================
  # Capture is observational — it must never break message delivery
  # ==========================================================================

  test "a capture failure does not break the follow-up it describes" do
    session = idle_session
    HumanMessage.any_instance.stubs(:save!).raises(ActiveRecord::StatementInvalid, "boom")

    assert_no_difference("HumanMessage.count") do
      post follow_up_session_url(session), params: { follow_up_prompt: "still has to land" }
    end

    assert_equal "still has to land", session.reload.metadata["pending_follow_up_prompt"]
  end

  # A REAL database error, not a Ruby-level stub: in PostgreSQL a failed
  # statement aborts the enclosing transaction, and rescuing the Ruby exception
  # does not un-abort it. Without the savepoint in HumanMessageCapture, the write
  # after the failed capture below raises PG::InFailedSqlTransaction — i.e. a
  # capture failure would take down the delivery it was only meant to describe.
  test "a capture failure inside an open transaction does not poison it" do
    session = idle_session
    other = sessions(:running)

    # A genuine database-level failure, not a Ruby-level stub: the session row is
    # deleted out from under a still-"persisted?" object, so the INSERT violates
    # the human_messages → sessions foreign key inside PostgreSQL itself.
    Session.where(id: session.id).delete_all

    ActiveRecord::Base.transaction(requires_new: true) do
      assert_nil HumanMessageCapture.record_web_ui_message(
        session: session, content: "boom", entry_point: "web_ui.follow_up"
      )

      # The caller's transaction must still be usable. Without the savepoint
      # this raises PG::InFailedSqlTransaction.
      other.logs.create!(content: "delivery continued", level: "info")
    end

    assert other.logs.exists?(content: "delivery continued")
  end

  test "a blank message records nothing" do
    session = idle_session

    assert_nil HumanMessageCapture.record_web_ui_message(
      session: session, content: "   ", entry_point: "web_ui.follow_up"
    )
  end
end

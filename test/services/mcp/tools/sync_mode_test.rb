# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# `sync: true` on the three tools that send a prompt into a session. The wait
# itself is Sessions::SyncReplyTest's subject; this covers that each tool sends
# exactly what it sent before, then waits on the right turn and renders it.
class Mcp::Tools::SyncModeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { Sessions::SyncReply.reset_semaphore! }
  teardown { Sessions::SyncReply.reset_semaphore! }

  def context(**options)
    Mcp::Context.new(tool_groups: "sessions", **options)
  end

  def user_line(text)
    { type: "user", message: { role: "user", content: text } }.to_json
  end

  def assistant_line(text)
    { type: "assistant", message: { role: "assistant", content: [ { type: "text", text: text } ] } }.to_json
  end

  # Plays the worker: once `find` returns a session, write its turn and pause it.
  def finish_turn_later(reply:, prompt:, status: :needs_input, child_title: nil, &find)
    Thread.new do
      session = nil
      50.times do
        session = find.call
        break if session

        sleep 0.05
      end
      sleep 0.2
      lines = session.transcript.to_s.lines.map(&:chomp).reject(&:empty?)
      session.transcript = "#{(lines + [ user_line(prompt), assistant_line(reply) ]).join("\n")}\n"
      session.save!
      create_session(parent_session_id: session.id, title: child_title, status: :waiting) if child_title
      count = session.needs_input_transition_count + 1
      session.update!(status: status, custom_metadata: (session.custom_metadata || {}).merge("needs_input_count" => count))
    end
  end

  # --- quick_router ------------------------------------------------------------

  test "quick_router with sync returns the router's reply and the session it started, not waited on" do
    before = Session.maximum(:id).to_i
    worker = finish_turn_later(reply: "Started a session to fix it.", prompt: "fix the login bug",
                               child_title: "Fix login bug") do
      Session.where("id > ?", before).order(:id).first
    end

    result = Mcp::Tools::QuickRouter.new(context: context).call("prompt" => "fix the login bug", "sync" => true)
    worker.join

    router = Session.where("id > ?", before).order(:id).first
    child = Session.find_by(parent_session_id: router.id)
    assert_includes result, "## Quick Router reply"
    assert_includes result, "- **ID:** #{router.id}"
    assert_includes result, "/sessions/#{router.id}"
    assert_includes result, "- **Status:** needs_input"
    assert_includes result, "### Reply\n\nStarted a session to fix it."
    assert_includes result, "### Sessions it started"
    assert_includes result, "##{child.id} Fix login bug — waiting — "
    assert_includes result, "this call did not wait for them"
  end

  test "quick_router with sync that runs out of time hands back the session to poll" do
    result = Mcp::Tools::QuickRouter.new(context: context)
      .call("prompt" => "a long job", "sync" => true, "sync_timeout_seconds" => 1)

    session = Session.order(:id).last
    assert_includes result, "- **ID:** #{session.id}"
    assert_includes result, "Still working — this call stopped waiting"
    assert_includes result, "### What it has said so far\n\n_Nothing yet._"
    assert_includes result, "call `get_session` with id `#{session.id}`"
  end

  test "quick_router refuses a bad sync timeout before starting anything" do
    assert_no_difference "Session.count" do
      error = assert_raises(Mcp::ToolError) do
        Mcp::Tools::QuickRouter.new(context: context)
          .call("prompt" => "x", "sync" => true, "sync_timeout_seconds" => "whenever")
      end
      assert_includes error.message, "sync_timeout_seconds"
    end
  end

  test "quick_router without sync is unchanged" do
    Sessions::SyncReply.any_instance.expects(:wait).never

    result = Mcp::Tools::QuickRouter.new(context: context).call("prompt" => "hello", "sync" => false)

    assert_includes result, "## Quick Router session started"
  end

  test "a sync call over the wait cap still sends the prompt and returns at once" do
    Sessions::SyncReply.reset_semaphore!(0)

    result = nil
    assert_enqueued_with(job: AgentSessionJob) do
      result = Mcp::Tools::QuickRouter.new(context: context).call("prompt" => "hello", "sync" => true)
    end

    assert_includes result, "Not waited on"
    assert_includes result, "The prompt was sent all the same"
  end

  test "a wait that fails after the prompt was sent still hands back the session" do
    Sessions::SyncReply.any_instance.stubs(:wait).raises(ActiveRecord::ConnectionTimeoutError)

    result = Mcp::Tools::QuickRouter.new(context: context(base_url: "https://zimmer.example"))
      .call("prompt" => "hello", "sync" => true)

    session = Session.order(:id).last
    assert_includes result, "- **ID:** #{session.id}"
    assert_includes result, "https://zimmer.example/sessions/#{session.id}"
    assert_includes result, "the wait failed (ActiveRecord::ConnectionTimeoutError)"
  end

  # --- action_session follow_up -----------------------------------------------

  test "follow_up with sync to an idle session returns that turn's reply, not the previous one" do
    session = create_session(status: :needs_input, prompt: "first")
    session.transcript = "#{[ user_line('first'), assistant_line('old answer') ].join("\n")}\n"
    session.custom_metadata = { "needs_input_count" => 1 }
    session.save!

    worker = finish_turn_later(reply: "new answer", prompt: "second") { Session.find(session.id) }
    result = Mcp::Tools::ActionSession.new(context: context)
      .call("action" => "follow_up", "session_id" => session.id, "prompt" => "second", "sync" => true)
    worker.join

    assert_includes result, "## Follow-up Sent"
    assert_includes result, "### Reply\n\nnew answer"
    refute_includes result, "old answer"
  end

  test "follow_up with sync to a running session waits through the turn ahead of it" do
    session = create_session(status: :running, prompt: "earlier")
    session.update!(custom_metadata: { "needs_input_count" => 2 })

    worker = Thread.new do
      message = nil
      50.times do
        message = EnqueuedMessage.find_by(session_id: session.id)
        break if message

        sleep 0.05
      end
      s = Session.find(session.id)
      # The turn ahead ends; its pause is not our answer.
      s.transcript = "#{[ user_line('earlier'), assistant_line('earlier answer') ].join("\n")}\n"
      s.save!
      s.update!(status: :needs_input, custom_metadata: { "needs_input_count" => 3 })
      sleep 0.3
      # The queue drains into our turn.
      message.destroy!
      s.update!(status: :running)
      sleep 0.3
      s.transcript = "#{[ user_line('earlier'), assistant_line('earlier answer'), user_line('queued q'),
                          assistant_line('queued answer') ].join("\n")}\n"
      s.save!
      s.update!(status: :needs_input, custom_metadata: { "needs_input_count" => 4 })
    end

    result = Mcp::Tools::ActionSession.new(context: context)
      .call("action" => "follow_up", "session_id" => session.id, "prompt" => "queued q", "sync" => true)
    worker.join

    assert_includes result, "Message queued"
    assert_includes result, "### Reply\n\nqueued answer"
    refute_includes result, "earlier answer"
  end

  test "follow_up refuses to sync-wait on the calling session itself" do
    session = create_session(status: :running)

    assert_no_difference "EnqueuedMessage.count" do
      error = assert_raises(Mcp::ToolError) do
        Mcp::Tools::ActionSession.new(context: context(session_id: session.id.to_s))
          .call("action" => "follow_up", "session_id" => session.id, "prompt" => "hi", "sync" => true)
      end
      assert_includes error.message, "cannot wait on your own session"
    end
  end

  test "action_session advertises sync on its schema" do
    properties = Mcp::Tools::ActionSession.input_schema.to_h[:properties]

    assert_equal "boolean", properties.dig(:sync, :type)
    assert_equal "number", properties.dig(:sync_timeout_seconds, :type)
    assert_includes Mcp::Tools::ActionSession.description, "\"sync\": true"
  end

  # --- start_session ----------------------------------------------------------

  test "start_session with sync and a prompt appends the reply to the usual result" do
    before = Session.maximum(:id).to_i
    worker = finish_turn_later(reply: "all done", prompt: "Fix the thing") do
      Session.where("id > ?", before).order(:id).first
    end

    result = Mcp::Tools::StartSession.new(context: context)
      .call("agent_root" => "zimmer", "prompt" => "Fix the thing", "title" => "Fix the thing", "sync" => true)
    worker.join

    assert_includes result, "## Session Started Successfully"
    assert_includes result, "## Reply"
    assert_includes result, "### Reply\n\nall done"
  end

  test "start_session refuses sync without a prompt, before creating anything" do
    assert_no_difference "Session.count" do
      error = assert_raises(Mcp::ToolError) do
        Mcp::Tools::StartSession.new(context: context).call("agent_root" => "zimmer", "sync" => true)
      end
      assert_includes error.message, "needs a prompt"
    end
  end
end

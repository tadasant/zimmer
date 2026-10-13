# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

module Sessions
  class SyncReplyTest < ActiveSupport::TestCase
    setup do
      SyncReply.reset_semaphore!
    end

    teardown do
      SyncReply.reset_semaphore!
    end

    def user_line(text)
      { type: "user", message: { role: "user", content: text } }.to_json
    end

    def assistant_line(text)
      { type: "assistant", message: { role: "assistant", content: [ { type: "text", text: text } ] } }.to_json
    end

    def tool_call_line
      { type: "assistant", message: { role: "assistant",
                                      content: [ { type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } } ] } }.to_json
    end

    def with_transcript(session, *lines)
      session.transcript = "#{lines.join("\n")}\n"
      session.save!
      session
    end

    # The turn ends as AgentSessionJob ends it: the transcript has the reply and
    # the pause has bumped the counter in the same write as the status.
    def end_turn!(session, status: :needs_input, **attributes)
      count = session.reload.needs_input_transition_count + 1
      session.update!(status: status, custom_metadata: (session.custom_metadata || {}).merge("needs_input_count" => count),
                      **attributes)
    end

    test "returns the reply of the turn the prompt started once the session rests in needs_input" do
      session = create_session(status: :waiting, prompt: "say pong")
      waiter = SyncReply.first_turn(session, prompt: "say pong")
      with_transcript(session, user_line("say pong"), tool_call_line, assistant_line("thinking out loud"),
                      assistant_line("pong"))
      end_turn!(session)

      result = waiter.wait(timeout: 2)

      assert_equal :needs_input, result.outcome
      assert result.finished?
      assert_equal "pong", result.reply
      assert_equal "needs_input", result.session.status
    end

    # The real state machine, not a hand-written status: `pause!` is what
    # AgentSessionJob calls when a turn ends, and its counter bump is the signal.
    test "a real pause! ends the wait" do
      session = create_session(status: :running, prompt: "say pong")
      waiter = SyncReply.first_turn(session, prompt: "say pong")
      with_transcript(session, user_line("say pong"), assistant_line("pong"))
      session.reload.pause!

      result = waiter.wait(timeout: 2)

      assert_equal :needs_input, result.outcome
      assert_equal "pong", result.reply
    end

    test "never returns an earlier turn's reply for a follow-up" do
      session = create_session(status: :needs_input, prompt: "first")
      with_transcript(session, user_line("first"), assistant_line("old answer"))
      session.update!(custom_metadata: { "needs_input_count" => 1 })

      waiter = SyncReply.direct(session.reload, prompt: "second question")
      session.update!(status: :waiting)

      # Still mid-turn: a re-read finds the old count, and the old reply is not ours.
      result = waiter.wait(timeout: 0.2)
      assert_equal :timed_out, result.outcome
      assert_nil result.reply

      with_transcript(session.reload, user_line("first"), assistant_line("old answer"),
                      user_line("second question"), assistant_line("new answer"))
      end_turn!(session)

      result = waiter.wait(timeout: 2)
      assert_equal :needs_input, result.outcome
      assert_equal "new answer", result.reply
    end

    test "stops at the next user message, so a later turn's reply is not returned" do
      session = create_session(status: :waiting, prompt: "mine")
      waiter = SyncReply.first_turn(session, prompt: "mine")
      with_transcript(session, user_line("mine"), assistant_line("my answer"),
                      user_line("someone else's queued message"), assistant_line("their answer"))
      end_turn!(session, status: :running)

      result = waiter.wait(timeout: 2)

      assert_equal :moved_on, result.outcome
      assert_equal "my answer", result.reply
    end

    test "a session that archives itself straight from running is finished without a pause" do
      session = create_session(status: :running, prompt: "do it")
      waiter = SyncReply.first_turn(session, prompt: "do it")
      with_transcript(session, user_line("do it"), assistant_line("done, archiving"))
      session.update!(status: :archived)

      result = waiter.wait(timeout: 2)

      assert_equal :archived, result.outcome
      assert_equal "done, archiving", result.reply
    end

    test "a failed session ends the wait" do
      session = create_session(status: :running, prompt: "do it")
      waiter = SyncReply.first_turn(session, prompt: "do it")
      session.update!(status: :failed)

      result = waiter.wait(timeout: 2)

      assert_equal :failed, result.outcome
      assert_nil result.reply
    end

    test "a session that goes to sleep on a wake-up has answered" do
      session = create_session(status: :running, prompt: "check later")
      waiter = SyncReply.first_turn(session, prompt: "check later")
      with_transcript(session, user_line("check later"), assistant_line("sleeping until 9"))
      end_turn!(session, status: :waiting)
      Session.any_instance.stubs(:armed_one_time_wake?).returns(true)

      result = waiter.wait(timeout: 2)

      assert_equal :asleep, result.outcome
      assert_equal "sleeping until 9", result.reply
    end

    test "a recovery pause is not the end of the turn" do
      session = create_session(status: :running, prompt: "long job")
      waiter = SyncReply.first_turn(session, prompt: "long job")
      end_turn!(session, metadata: { "paused_by" => "recovery" })

      assert_equal :timed_out, waiter.wait(timeout: 0.2).outcome

      session.update!(status: :running, metadata: {})
      with_transcript(session.reload, user_line("long job"), assistant_line("finished after the restart"))
      end_turn!(session)

      result = waiter.wait(timeout: 2)
      assert_equal :needs_input, result.outcome
      assert_equal "finished after the restart", result.reply
    end

    # `block_on_elicitation` bumps the pause count like any pause, so the blocked
    # check has to come before "rests in needs_input".
    test "a session blocked on an approval request returns what it has said" do
      session = create_session(status: :running, prompt: "send it")
      waiter = SyncReply.first_turn(session, prompt: "send it")
      with_transcript(session, user_line("send it"), assistant_line("asking for approval"))
      end_turn!(session)
      Session.any_instance.stubs(:blocked_on_elicitation?).returns(true)

      result = waiter.wait(timeout: 2)

      assert_equal :blocked_on_elicitation, result.outcome
      assert_equal "asking for approval", result.reply
    end

    test "lists the sessions it started and does not wait on them" do
      router = create_session(status: :running, prompt: "fix the bug")
      waiter = SyncReply.first_turn(router, prompt: "fix the bug")
      child = create_session(status: :running, prompt: "the actual fix", parent_session_id: router.id, title: "Fix bug")
      with_transcript(router, user_line("fix the bug"), assistant_line("Started session #{child.id} to fix it."))
      end_turn!(router)

      result = waiter.wait(timeout: 2)

      assert_equal :needs_input, result.outcome
      assert_equal [ child.id ], result.children.map(&:id)
      assert_equal "running", result.children.first.status
    end

    test "times out with the partial state, and keeps the session running" do
      session = create_session(status: :running, prompt: "slow")
      waiter = SyncReply.first_turn(session, prompt: "slow")
      with_transcript(session, user_line("slow"), assistant_line("working on it"))

      result = waiter.wait(timeout: 0.3)

      assert_equal :timed_out, result.outcome
      refute result.finished?
      assert_equal "working on it", result.reply
      assert_equal "running", result.session.status
      assert_operator result.elapsed_seconds, :>=, 0.3
    end

    test "a queued prompt is waited on through the turn ahead of it" do
      session = create_session(status: :running, prompt: "earlier work")
      session.update!(custom_metadata: { "needs_input_count" => 3 })
      with_transcript(session, user_line("earlier work"))
      message = session.enqueued_messages.create!(content: "queued question", position: 1, status: "pending")
      waiter = SyncReply.queued(session, prompt: "queued question", enqueued_message: message,
                                transcript_index: session.transcript_line_count)

      # The turn ahead ends and pauses before the queue drains. Not our answer.
      with_transcript(session.reload, user_line("earlier work"), assistant_line("earlier answer"))
      end_turn!(session)
      result = waiter.wait(timeout: 0.2)
      assert_equal :timed_out, result.outcome
      assert_equal 1, result.queued_position
      assert_nil result.reply

      # Delivered: the row leaves the queue and the turn starts.
      message.destroy!
      session.update!(status: :running)
      assert_equal :timed_out, waiter.wait(timeout: 0.2).outcome

      with_transcript(session.reload, user_line("earlier work"), assistant_line("earlier answer"),
                      user_line("queued question"), assistant_line("queued answer"))
      end_turn!(session)

      result = waiter.wait(timeout: 2)
      assert_equal :needs_input, result.outcome
      assert_equal "queued answer", result.reply
    end

    test "a queued prompt marked undelivered ends the wait" do
      session = create_session(status: :running, prompt: "earlier")
      message = session.enqueued_messages.create!(content: "never sent", position: 1, status: "pending")
      waiter = SyncReply.queued(session, prompt: "never sent", enqueued_message: message, transcript_index: 0)
      message.update_columns(status: "undelivered")

      assert_equal :undelivered, waiter.wait(timeout: 2).outcome
    end

    test "wakes on the session's status change rather than the backstop" do
      session = create_session(status: :running, prompt: "quick")
      waiter = SyncReply.first_turn(session, prompt: "quick")

      finisher = Thread.new do
        sleep 0.3
        end_turn!(Session.find(session.id))
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = waiter.wait(timeout: 10)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      finisher.join

      assert_equal :needs_input, result.outcome
      assert_operator elapsed, :<, SyncReply::BACKSTOP_SECONDS,
                      "a status change should end the wait without waiting out the #{SyncReply::BACKSTOP_SECONDS}s backstop"
    end

    test "a status change rings the session's turn signal" do
      session = create_session(status: :running)
      rung = Thread::Queue.new
      unsubscribe = TurnSignal.subscribe(session.id) { rung << true }

      session.update!(status: :needs_input)

      assert rung.pop(timeout: 2), "expected a ring on #{TurnSignal.stream_name(session.id)}"
    ensure
      unsubscribe&.call
    end

    test "a call over the concurrency cap is not waited on" do
      SyncReply.reset_semaphore!(0)
      session = create_session(status: :running, prompt: "x")
      waiter = SyncReply.first_turn(session, prompt: "x")

      result = SyncReply.with_slot { flunk "must not wait without a slot" } || waiter.over_capacity

      assert_equal :over_capacity, result.outcome
      refute result.finished?
    end

    test "the timeout is clamped to what the transport tolerates" do
      assert_equal 55, SyncReply::DEFAULT_TIMEOUT_SECONDS
      assert_equal SyncReply::DEFAULT_TIMEOUT_SECONDS, SyncReply.timeout_from(nil)
      assert_equal SyncReply::MAX_TIMEOUT_SECONDS, SyncReply.timeout_from(600)
      assert_equal 30.0, SyncReply.timeout_from("30")
      assert_raises(ArgumentError) { SyncReply.timeout_from("soon") }
      assert_raises(ArgumentError) { SyncReply.timeout_from(-1) }
    end

    # The enqueued-message handoff ends a turn without pausing: no count bump,
    # and the session goes straight on to the next turn.
    test "a turn handed straight to a queued message is over when the next turn begins" do
      session = create_session(status: :running, prompt: "mine")
      waiter = SyncReply.first_turn(session, prompt: "mine")
      with_transcript(session, user_line("mine"), assistant_line("my answer"))
      assert_equal :timed_out, waiter.wait(timeout: 0.2).outcome

      with_transcript(session.reload, user_line("mine"), assistant_line("my answer"), user_line("the queued one"))
      session.update!(status: :waiting)

      result = waiter.wait(timeout: 2)
      assert_equal :moved_on, result.outcome
      assert_equal "my answer", result.reply
    end

    test "a recovery nudge continues the turn rather than ending it" do
      session = create_session(status: :running, prompt: "long job")
      waiter = SyncReply.first_turn(session, prompt: "long job")
      with_transcript(session, user_line("long job"), assistant_line("halfway"),
                      user_line(AutomatedPrompts.system_recovery), assistant_line("done after the restart"))
      end_turn!(session)

      result = waiter.wait(timeout: 2)
      assert_equal :needs_input, result.outcome
      assert_equal "done after the restart", result.reply
    end

    test "a turn parked before it ran is stood down, not answered" do
      session = create_session(status: :waiting, prompt: "do it")
      waiter = SyncReply.first_turn(session, prompt: "do it")
      end_turn!(session, metadata: { "auth_outage_reason" => "pool_empty" })

      result = waiter.wait(timeout: 2)
      assert_equal :stood_down, result.outcome
      assert_nil result.reply
    end

    test "a session put to sleep with no wake and no turn coming is asleep, not moved on" do
      session = create_session(status: :running, prompt: "later")
      waiter = SyncReply.first_turn(session, prompt: "later")
      with_transcript(session, user_line("later"), assistant_line("parking in the spot queue"))
      end_turn!(session, status: :waiting)
      Sessions::LiveTurn.stubs(:coming?).returns(false)

      assert_equal :asleep, waiter.wait(timeout: 2).outcome
    end

    test "a queued prompt noticed late still finds its own turn" do
      session = create_session(status: :running, prompt: "earlier")
      with_transcript(session, user_line("earlier"))
      floor = session.transcript_line_count
      message = session.enqueued_messages.create!(content: "queued question", position: 1, status: "pending")
      waiter = SyncReply.queued(session, prompt: "queued question", enqueued_message: message, transcript_index: floor)

      # By the first look the queue has drained, our turn has run, and its pause
      # is already counted — the baseline is read after it.
      message.destroy!
      with_transcript(session.reload, user_line("earlier"), assistant_line("earlier answer"),
                      user_line("queued question"), assistant_line("queued answer"))
      assert_equal :timed_out, waiter.wait(timeout: 0.2).outcome

      with_transcript(session.reload, user_line("earlier"), assistant_line("earlier answer"),
                      user_line("queued question"), assistant_line("queued answer"), user_line("next"))
      session.update!(status: :running)

      result = waiter.wait(timeout: 2)
      assert_equal :moved_on, result.outcome
      assert_equal "queued answer", result.reply
    end

    test "a queued prompt removed from the queue is undelivered, not answered by someone else's turn" do
      session = create_session(status: :running, prompt: "earlier")
      session.update!(custom_metadata: { "needs_input_count" => 1 })
      message = session.enqueued_messages.create!(content: "cancelled one", position: 1, status: "pending")
      waiter = SyncReply.queued(session, prompt: "cancelled one", enqueued_message: message, transcript_index: 0)

      message.destroy!
      assert_equal :timed_out, waiter.wait(timeout: 0.2).outcome
      with_transcript(session.reload, user_line("earlier"), assistant_line("earlier answer"))
      end_turn!(session)

      result = waiter.wait(timeout: 2)
      assert_equal :undelivered, result.outcome
      assert_nil result.reply
    end

    test "a replayed first-turn wait still lists the sessions the original call's turn started" do
      router = create_session(status: :running, prompt: "fix it", created_at: 2.minutes.ago)
      child = create_session(status: :running, parent_session_id: router.id, created_at: 1.minute.ago)
      waiter = SyncReply.first_turn(router, prompt: "fix it")
      end_turn!(router)

      assert_equal [ child.id ], waiter.wait(timeout: 2).children.map(&:id)
    end

    test "cuts a very long reply from the front" do
      session = create_session(status: :running, prompt: "essay")
      waiter = SyncReply.first_turn(session, prompt: "essay")
      with_transcript(session, user_line("essay"), assistant_line("#{'a' * SyncReply::REPLY_MAX_CHARS}THE END"))
      end_turn!(session)

      result = waiter.wait(timeout: 2)

      assert result.reply_truncated
      assert result.reply.end_with?("THE END")
      assert_operator result.reply.length, :<=, SyncReply::REPLY_MAX_CHARS + 1
    end
  end
end

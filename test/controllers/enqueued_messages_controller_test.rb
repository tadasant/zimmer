require "test_helper"
require "mocha/minitest"

class EnqueuedMessagesControllerTest < ActionDispatch::IntegrationTest
  def setup
    # Stub Turbo Stream broadcasting to avoid missing partial errors in tests
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    @session = sessions(:running)
  end

  def teardown
    # Clean up all stubs to prevent leakage between tests
    Mocha::Mockery.instance.teardown
  end

  # Test create action - success cases
  test "should create enqueued message with valid content" do
    assert_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: "Test enqueued message"
      }
    end

    message = @session.enqueued_messages.last
    assert_equal "Test enqueued message", message.content
    assert_equal "pending", message.status
    assert_equal 1, message.position
  end

  test "should create enqueued message with follow_up_prompt param" do
    assert_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        follow_up_prompt: "Test with follow_up_prompt param"
      }
    end

    message = @session.enqueued_messages.last
    assert_equal "Test with follow_up_prompt param", message.content
  end

  test "should create enqueued message with content param" do
    assert_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: "Test with content param"
      }
    end

    message = @session.enqueued_messages.last
    assert_equal "Test with content param", message.content
  end

  test "should assign incremental position to enqueued messages" do
    # Create first message
    post session_enqueued_messages_url(@session), params: {
      content: "First message"
    }
    first_message = @session.enqueued_messages.last
    assert_equal 1, first_message.position

    # Create second message
    post session_enqueued_messages_url(@session), params: {
      content: "Second message"
    }
    second_message = @session.enqueued_messages.last
    assert_equal 2, second_message.position

    # Create third message
    post session_enqueued_messages_url(@session), params: {
      content: "Third message"
    }
    third_message = @session.enqueued_messages.last
    assert_equal 3, third_message.position
  end

  test "should create log entry when creating enqueued message" do
    assert_difference("@session.logs.count") do
      post session_enqueued_messages_url(@session), params: {
        content: "Test message"
      }
    end

    log = @session.logs.last
    assert_includes log.content, "Enqueued message added at position"
  end

  test "should create enqueued message with goal" do
    assert_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: "Test message",
        goal: "wait for user input"
      }
    end

    message = @session.enqueued_messages.last
    assert_equal "wait for user input", message.goal
  end

  test "should create enqueued message without goal" do
    assert_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: "Test message"
      }
    end

    message = @session.enqueued_messages.last
    assert_nil message.goal
  end

  test "should respond with turbo stream on successful create" do
    post session_enqueued_messages_url(@session), params: {
      content: "Test message"
    }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_match /turbo-stream/, response.body
  end

  test "should redirect with html format on successful create" do
    post session_enqueued_messages_url(@session), params: {
      content: "Test message"
    }

    assert_redirected_to session_path(@session)
    assert_equal "Message enqueued successfully", flash[:notice]
  end

  # Test create action - validation errors
  test "should reject empty content" do
    assert_no_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: ""
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_match /Message content cannot be empty/, response.body
  end

  test "should reject blank content" do
    assert_no_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: "   "
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_match /Message content cannot be empty/, response.body
  end

  test "should reject content exceeding maximum length" do
    long_content = "a" * (Session::PROMPT_MAX_LENGTH + 1)

    assert_no_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: long_content
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_match /Message is too long/, response.body
  end

  test "should accept content at maximum length" do
    max_content = "a" * Session::PROMPT_MAX_LENGTH

    assert_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: max_content
      }
    end

    message = @session.enqueued_messages.last
    assert_equal max_content, message.content
  end

  test "should reject goal exceeding maximum length" do
    long_condition = "a" * (Session::GOAL_MAX_LENGTH + 1)

    assert_no_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: "Test message",
        goal: long_condition
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_match /Goal is too long/, response.body
  end

  test "should accept goal at maximum length" do
    max_condition = "a" * Session::GOAL_MAX_LENGTH

    assert_difference("@session.enqueued_messages.count") do
      post session_enqueued_messages_url(@session), params: {
        content: "Test message",
        goal: max_condition
      }
    end

    message = @session.enqueued_messages.last
    assert_equal max_condition, message.goal
  end

  test "should respond with html redirect on validation error" do
    post session_enqueued_messages_url(@session), params: {
      content: ""
    }

    assert_redirected_to session_path(@session)
    assert_equal "Message content cannot be empty", flash[:alert]
  end

  # Test destroy action
  test "should destroy enqueued message" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )

    assert_difference("@session.enqueued_messages.count", -1) do
      delete session_enqueued_message_url(@session, message)
    end
  end

  test "should renumber remaining messages after destroy" do
    msg1 = @session.enqueued_messages.create!(content: "First", position: 1)
    msg2 = @session.enqueued_messages.create!(content: "Second", position: 2)
    msg3 = @session.enqueued_messages.create!(content: "Third", position: 3)

    delete session_enqueued_message_url(@session, msg2)

    msg1.reload
    msg3.reload

    assert_equal 1, msg1.position
    assert_equal 2, msg3.position
  end

  test "should create log entry when destroying message" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )

    assert_difference("@session.logs.count") do
      delete session_enqueued_message_url(@session, message)
    end

    log = @session.logs.last
    assert_includes log.content, "Enqueued message at position 1 removed"
  end

  test "should respond with turbo stream on successful destroy" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )

    delete session_enqueued_message_url(@session, message),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
  end

  test "should redirect with html format on successful destroy" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )

    delete session_enqueued_message_url(@session, message)

    assert_redirected_to session_path(@session)
    assert_equal "Message removed successfully", flash[:notice]
  end

  # Test update action
  test "should update enqueued message content" do
    message = @session.enqueued_messages.create!(
      content: "Original content",
      position: 1
    )

    patch session_enqueued_message_url(@session, message), params: {
      content: "Updated content"
    }

    message.reload
    assert_equal "Updated content", message.content
  end

  test "should update enqueued message goal" do
    message = @session.enqueued_messages.create!(
      content: "Test content",
      position: 1
    )

    patch session_enqueued_message_url(@session, message), params: {
      content: "Test content",
      goal: "New goal"
    }

    message.reload
    assert_equal "New goal", message.goal
  end

  test "should update both content and goal" do
    message = @session.enqueued_messages.create!(
      content: "Original content",
      goal: "Original condition",
      position: 1
    )

    patch session_enqueued_message_url(@session, message), params: {
      content: "Updated content",
      goal: "Updated condition"
    }

    message.reload
    assert_equal "Updated content", message.content
    assert_equal "Updated condition", message.goal
  end

  test "should clear goal when empty string provided" do
    message = @session.enqueued_messages.create!(
      content: "Test content",
      goal: "Existing condition",
      position: 1
    )

    patch session_enqueued_message_url(@session, message), params: {
      content: "Test content",
      goal: ""
    }

    message.reload
    assert_nil message.goal
  end

  test "should create log entry when updating message" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )

    assert_difference("@session.logs.count") do
      patch session_enqueued_message_url(@session, message), params: {
        content: "Updated message"
      }
    end

    log = @session.logs.last
    assert_includes log.content, "Enqueued message at position 1 updated"
  end

  test "should reject update with empty content" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )

    patch session_enqueued_message_url(@session, message), params: {
      content: ""
    }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match /Message content cannot be empty/, response.body

    message.reload
    assert_equal "Test message", message.content
  end

  test "should reject update with content exceeding maximum length" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )
    long_content = "a" * (Session::PROMPT_MAX_LENGTH + 1)

    patch session_enqueued_message_url(@session, message), params: {
      content: long_content
    }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match /Message is too long/, response.body

    message.reload
    assert_equal "Test message", message.content
  end

  test "should reject update with goal exceeding maximum length" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )
    long_condition = "a" * (Session::GOAL_MAX_LENGTH + 1)

    patch session_enqueued_message_url(@session, message), params: {
      content: "Test message",
      goal: long_condition
    }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match /Goal is too long/, response.body
  end

  test "should respond with turbo stream on successful update" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )

    patch session_enqueued_message_url(@session, message), params: {
      content: "Updated message"
    }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_match /turbo-stream/, response.body
  end

  test "should redirect with html format on successful update" do
    message = @session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )

    patch session_enqueued_message_url(@session, message), params: {
      content: "Updated message"
    }

    assert_redirected_to session_path(@session)
    assert_equal "Message updated successfully", flash[:notice]
  end

  # Test reorder action
  test "should reorder message to new position" do
    msg1 = @session.enqueued_messages.create!(content: "First", position: 1)
    msg2 = @session.enqueued_messages.create!(content: "Second", position: 2)
    msg3 = @session.enqueued_messages.create!(content: "Third", position: 3)

    patch reorder_session_enqueued_message_url(@session, msg1), params: {
      position: 3
    }

    msg1.reload
    msg2.reload
    msg3.reload

    assert_equal 3, msg1.position
    assert_equal 1, msg2.position
    assert_equal 2, msg3.position
  end

  test "should create log entry when reordering message" do
    message = @session.enqueued_messages.create!(content: "Test", position: 1)
    @session.enqueued_messages.create!(content: "Second", position: 2)

    assert_difference("@session.logs.count") do
      patch reorder_session_enqueued_message_url(@session, message), params: {
        position: 2
      }
    end

    log = @session.logs.last
    assert_includes log.content, "Enqueued message moved from position 1 to 2"
  end

  test "should reject invalid position less than 1" do
    message = @session.enqueued_messages.create!(content: "Test", position: 1)

    patch reorder_session_enqueued_message_url(@session, message), params: {
      position: 0
    }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    # Should still respond successfully but just refresh the list
    assert_response :success
  end

  test "should respond with turbo stream on successful reorder" do
    message = @session.enqueued_messages.create!(content: "Test", position: 1)
    @session.enqueued_messages.create!(content: "Second", position: 2)

    patch reorder_session_enqueued_message_url(@session, message), params: {
      position: 2
    }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
  end

  test "should redirect with html format on successful reorder" do
    message = @session.enqueued_messages.create!(content: "Test", position: 1)
    @session.enqueued_messages.create!(content: "Second", position: 2)

    patch reorder_session_enqueued_message_url(@session, message), params: {
      position: 2
    }

    assert_redirected_to session_path(@session)
    assert_equal "Message reordered successfully", flash[:notice]
  end

  # Test interrupt action
  test "should send interrupt message when session is needs_input" do
    session = sessions(:needs_input)
    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      position: 1
    )

    assert_enqueued_with(job: AgentSessionJob) do
      post interrupt_session_enqueued_message_url(session, message)
    end

    session.reload
    assert_equal "running", session.status
    assert_equal 0, session.enqueued_messages.count
  end

  test "should send interrupt message when session is waiting" do
    session = sessions(:waiting)
    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      position: 1
    )

    assert_enqueued_with(job: AgentSessionJob) do
      post interrupt_session_enqueued_message_url(session, message)
    end

    session.reload
    assert_equal "running", session.status
  end

  test "should pause running session before sending interrupt" do
    session = sessions(:running)
    # Add a fake PID that doesn't exist so we can test pause
    session.update!(metadata: { "process_pid" => 999999 })

    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      position: 1
    )

    post interrupt_session_enqueued_message_url(session, message)

    session.reload
    # Session should be paused then resumed to running
    assert_equal "running", session.status
  end

  test "should update goal from interrupt message" do
    session = sessions(:needs_input)
    session.update!(goal: "old condition")

    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      goal: "new condition",
      position: 1
    )

    post interrupt_session_enqueued_message_url(session, message)

    session.reload
    assert_equal "new condition", session.goal
  end

  test "should preserve session goal when interrupt message has none" do
    session = sessions(:needs_input)
    session.update!(goal: "existing condition")

    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      goal: nil,
      position: 1
    )

    post interrupt_session_enqueued_message_url(session, message)

    session.reload
    assert_equal "existing condition", session.goal
  end

  test "should delete interrupt message after sending" do
    session = sessions(:needs_input)
    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      position: 1
    )

    assert_difference("session.enqueued_messages.count", -1) do
      post interrupt_session_enqueued_message_url(session, message)
    end
  end

  test "should renumber remaining messages after interrupt" do
    session = sessions(:needs_input)
    msg1 = session.enqueued_messages.create!(content: "First", position: 1)
    msg2 = session.enqueued_messages.create!(content: "Second", position: 2)
    msg3 = session.enqueued_messages.create!(content: "Third", position: 3)

    post interrupt_session_enqueued_message_url(session, msg1)

    msg2.reload
    msg3.reload

    assert_equal 1, msg2.position
    assert_equal 2, msg3.position
  end

  test "should create log entry for interrupt" do
    session = sessions(:needs_input)
    message = session.enqueued_messages.create!(
      content: "Interrupt message with some content here",
      position: 1
    )

    post interrupt_session_enqueued_message_url(session, message)

    logs = session.logs.order(:created_at)
    interrupt_log = logs.find { |log| log.content.include?("Enqueued message sent as interrupt via web") }
    assert_not_nil interrupt_log, "Expected an 'Enqueued message sent as interrupt via web' log"
    assert_match(/Interrupt message/, interrupt_log.content)
  end

  test "should reset sigterm retry metadata on interrupt" do
    session = sessions(:needs_input)
    session.update!(
      metadata: {
        "sigterm_retry_count" => 3,
        "sigterm_retry_timestamps" => [ "2025-11-29T18:21:47Z" ],
        "last_sigterm_at" => "2025-11-29T18:21:47Z"
      }
    )

    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      position: 1
    )

    post interrupt_session_enqueued_message_url(session, message)

    session.reload
    assert_nil session.metadata["sigterm_retry_count"]
    assert_nil session.metadata["sigterm_retry_timestamps"]
    assert_nil session.metadata["last_sigterm_at"]
  end

  test "should respond with turbo stream on successful interrupt" do
    session = sessions(:needs_input)
    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      position: 1
    )

    post interrupt_session_enqueued_message_url(session, message),
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
  end

  test "should redirect with html format on successful interrupt" do
    session = sessions(:needs_input)
    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      position: 1
    )

    post interrupt_session_enqueued_message_url(session, message)

    assert_redirected_to session_path(session)
    assert_equal "Message sent as interrupt. Agent is processing...", flash[:notice]
  end

  test "should not interrupt when session is archived" do
    session = sessions(:archived)
    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      position: 1
    )

    # First pause would fail for archived session
    post interrupt_session_enqueued_message_url(session, message)

    assert_redirected_to session_path(session)
    assert_match /Cannot interrupt when session is/, flash[:alert]
  end

  test "should not interrupt when session is failed" do
    session = sessions(:failed)
    message = session.enqueued_messages.create!(
      content: "Interrupt message",
      position: 1
    )

    post interrupt_session_enqueued_message_url(session, message)

    assert_redirected_to session_path(session)
    assert_match /Cannot interrupt when session is/, flash[:alert]
  end

  # Test finding session by slug
  test "should find session by slug for create" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      slug: "test-session-123"
    )

    post session_enqueued_messages_url(session.slug), params: {
      content: "Test message"
    }

    assert_response :redirect
    message = session.enqueued_messages.last
    assert_equal "Test message", message.content
  end

  test "should find session by id for create when slug is not found" do
    post session_enqueued_messages_url(@session.id), params: {
      content: "Test message"
    }

    assert_response :redirect
    message = @session.enqueued_messages.last
    assert_equal "Test message", message.content
  end

  # Test routes
  test "should route to create" do
    assert_routing(
      { method: :post, path: "/sessions/1/enqueued_messages" },
      { controller: "enqueued_messages", action: "create", session_id: "1" }
    )
  end

  test "should route to destroy" do
    assert_routing(
      { method: :delete, path: "/sessions/1/enqueued_messages/2" },
      { controller: "enqueued_messages", action: "destroy", session_id: "1", id: "2" }
    )
  end

  test "should route to update" do
    assert_routing(
      { method: :patch, path: "/sessions/1/enqueued_messages/2" },
      { controller: "enqueued_messages", action: "update", session_id: "1", id: "2" }
    )
  end

  test "should route to reorder" do
    assert_routing(
      { method: :patch, path: "/sessions/1/enqueued_messages/2/reorder" },
      { controller: "enqueued_messages", action: "reorder", session_id: "1", id: "2" }
    )
  end

  test "should route to interrupt" do
    assert_routing(
      { method: :post, path: "/sessions/1/enqueued_messages/2/interrupt" },
      { controller: "enqueued_messages", action: "interrupt", session_id: "1", id: "2" }
    )
  end
end

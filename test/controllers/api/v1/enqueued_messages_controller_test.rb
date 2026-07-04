require "test_helper"

class Api::V1::EnqueuedMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    @session = sessions(:needs_input)
    # Create some enqueued messages for testing
    @msg1 = @session.enqueued_messages.create!(content: "First message", position: 1, status: "pending")
    @msg2 = @session.enqueued_messages.create!(content: "Second message", position: 2, status: "pending")
    @msg3 = @session.enqueued_messages.create!(content: "Third message", position: 3, status: "pending", goal: "PR merged")
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_session_enqueued_messages_path(@session)
    assert_response :unauthorized
  end

  test "should return 401 with invalid API key" do
    get api_v1_session_enqueued_messages_path(@session), headers: { "X-API-Key" => "invalid" }
    assert_response :unauthorized
  end

  # Index tests
  test "should return list of enqueued messages" do
    get api_v1_session_enqueued_messages_path(@session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("enqueued_messages")
    assert json.key?("pagination")
    assert_equal 3, json["enqueued_messages"].length
  end

  test "should return messages in position order" do
    get api_v1_session_enqueued_messages_path(@session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    positions = json["enqueued_messages"].map { |m| m["position"] }
    assert_equal [ 1, 2, 3 ], positions
  end

  test "should filter by status" do
    @msg1.update!(status: "sent")
    get api_v1_session_enqueued_messages_path(@session), params: { status: "pending" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 2, json["enqueued_messages"].length
  end

  test "should paginate messages" do
    get api_v1_session_enqueued_messages_path(@session), params: { per_page: 2 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 2, json["enqueued_messages"].length
    assert_equal 2, json["pagination"]["total_pages"]
  end

  # Show tests
  test "should return single enqueued message" do
    get api_v1_session_enqueued_message_path(@session, @msg1), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal @msg1.id, json["enqueued_message"]["id"]
    assert_equal "First message", json["enqueued_message"]["content"]
    assert_equal 1, json["enqueued_message"]["position"]
  end

  test "should return message with all expected fields" do
    get api_v1_session_enqueued_message_path(@session, @msg3), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["enqueued_message"]
    %w[id session_id content goal position status created_at updated_at].each do |field|
      assert json.key?(field), "Expected field '#{field}' to be present"
    end
    assert_equal "PR merged", json["goal"]
  end

  test "should return 404 for message in different session" do
    other_session = sessions(:running)
    get api_v1_session_enqueued_message_path(other_session, @msg1), headers: @headers
    assert_response :not_found
  end

  # Create tests
  test "should create enqueued message" do
    assert_difference("@session.enqueued_messages.count", 1) do
      post api_v1_session_enqueued_messages_path(@session), params: {
        content: "New queued message"
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "New queued message", json["enqueued_message"]["content"]
    assert_equal 4, json["enqueued_message"]["position"]
    assert_equal "pending", json["enqueued_message"]["status"]
  end

  test "should create message with goal" do
    post api_v1_session_enqueued_messages_path(@session), params: {
      content: "Message with stop", goal: "Tests pass"
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "Tests pass", json["enqueued_message"]["goal"]
  end

  test "should reject message without content" do
    assert_no_difference("EnqueuedMessage.count") do
      post api_v1_session_enqueued_messages_path(@session), params: {
        content: ""
      }, headers: @headers
    end

    assert_response :unprocessable_entity
  end

  test "should create log entry on message creation" do
    assert_difference("@session.logs.count", 1) do
      post api_v1_session_enqueued_messages_path(@session), params: {
        content: "Logged message"
      }, headers: @headers
    end
  end

  # Update tests
  test "should update message content" do
    patch api_v1_session_enqueued_message_path(@session, @msg1), params: {
      content: "Updated content"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Updated content", json["enqueued_message"]["content"]
  end

  test "should update goal" do
    patch api_v1_session_enqueued_message_path(@session, @msg1), params: {
      goal: "New condition"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "New condition", json["enqueued_message"]["goal"]
  end

  test "should reject blank content on update" do
    patch api_v1_session_enqueued_message_path(@session, @msg1), params: {
      content: ""
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  # Delete tests
  test "should delete enqueued message" do
    assert_difference("EnqueuedMessage.count", -1) do
      delete api_v1_session_enqueued_message_path(@session, @msg2), headers: @headers
    end

    assert_response :no_content
  end

  test "should renumber positions after delete" do
    delete api_v1_session_enqueued_message_path(@session, @msg1), headers: @headers
    assert_response :no_content

    assert_equal 1, @msg2.reload.position
    assert_equal 2, @msg3.reload.position
  end

  # Reorder tests
  test "should reorder message to new position" do
    patch reorder_api_v1_session_enqueued_message_path(@session, @msg3), params: {
      position: 1
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 1, json["enqueued_message"]["position"]
  end

  test "should reject invalid position" do
    patch reorder_api_v1_session_enqueued_message_path(@session, @msg1), params: {
      position: 0
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  # Interrupt tests
  test "should interrupt with needs_input session" do
    post interrupt_api_v1_session_enqueued_message_path(@session, @msg1), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Message sent as interrupt", json["message"]
    assert_raises(ActiveRecord::RecordNotFound) { @msg1.reload }
  end

  test "should reject interrupt when session is archived" do
    archived_session = sessions(:archived)
    msg = archived_session.enqueued_messages.create!(content: "test", position: 1, status: "pending")

    post interrupt_api_v1_session_enqueued_message_path(archived_session, msg), headers: @headers
    assert_response :unprocessable_entity
  end

  test "should renumber remaining messages after interrupt" do
    post interrupt_api_v1_session_enqueued_message_path(@session, @msg1), headers: @headers
    assert_response :success

    assert_equal 1, @msg2.reload.position
    assert_equal 2, @msg3.reload.position
  end

  # Session lookup tests
  test "should find session by slug" do
    @session.update!(slug: "test-slug")
    get api_v1_session_enqueued_messages_path("test-slug"), headers: @headers
    assert_response :success
  end

  test "should return 404 for nonexistent session" do
    get api_v1_session_enqueued_messages_path(999999), headers: @headers
    assert_response :not_found
  end

  # Response format tests
  test "should return JSON with correct content type" do
    get api_v1_session_enqueued_messages_path(@session), headers: @headers
    assert_equal "application/json; charset=utf-8", response.content_type
  end
end

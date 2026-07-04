# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class SlackServiceTest < ActiveSupport::TestCase
  setup do
    SlackService.reset!
  end

  teardown do
    SlackService.reset!
    Mocha::Mockery.instance.teardown
  end

  test "configured? returns false when SLACK_BOT_TOKEN is not set" do
    SecretsLoader.stubs(:get).with("SLACK_BOT_TOKEN").returns(nil)
    ENV.stubs(:[]).with("SLACK_BOT_TOKEN").returns(nil)
    assert_not SlackService.configured?
  end

  test "configured? returns true when SLACK_BOT_TOKEN is set via SecretsLoader" do
    SecretsLoader.stubs(:get).with("SLACK_BOT_TOKEN").returns("xoxb-test-token")
    assert SlackService.configured?
  end

  test "client raises ConfigurationError when not configured" do
    SecretsLoader.stubs(:get).with("SLACK_BOT_TOKEN").returns(nil)
    ENV.stubs(:[]).with("SLACK_BOT_TOKEN").returns(nil)

    error = assert_raises(SlackService::ConfigurationError) do
      SlackService.client
    end
    assert_includes error.message, "SLACK_BOT_TOKEN is not configured"
  end

  test "client is configured with timeouts to fail fast" do
    SecretsLoader.stubs(:get).with("SLACK_BOT_TOKEN").returns("xoxb-test-token")

    client = SlackService.client
    # Verify timeout constants are reasonable (not too long)
    assert SlackService::OPEN_TIMEOUT <= 10, "OPEN_TIMEOUT should be 10 seconds or less"
    assert SlackService::TIMEOUT <= 15, "TIMEOUT should be 15 seconds or less"

    # Verify the client was created (it should use the timeouts internally)
    assert_kind_of Slack::Web::Client, client
  end

  test "list_channels calls Slack API with correct parameters" do
    mock_client = mock("slack_client")
    mock_response = OpenStruct.new(
      channels: [
        OpenStruct.new(id: "C123", name: "general", is_private: false),
        OpenStruct.new(id: "C456", name: "random", is_private: false)
      ],
      response_metadata: nil
    )

    mock_client.expects(:conversations_list).with(
      types: "public_channel,private_channel",
      exclude_archived: true,
      limit: 200,
      cursor: nil
    ).returns(mock_response)

    SlackService.stubs(:client).returns(mock_client)

    channels = SlackService.list_channels
    assert_equal 2, channels.length
    assert_equal "C123", channels[0].id
    assert_equal "general", channels[0].name
  end

  test "list_member_channels returns only channels the bot is a member of" do
    member_channel = OpenStruct.new(id: "C123", name: "general", is_member: true)
    non_member_channel = OpenStruct.new(id: "C456", name: "random", is_member: false)

    SlackService.stubs(:list_channels).returns([ member_channel, non_member_channel ])

    channels = SlackService.list_member_channels
    assert_equal 1, channels.length
    assert_equal "C123", channels[0].id
    assert_equal "general", channels[0].name
  end

  test "list_member_channels returns empty array when no member channels" do
    non_member_channel = OpenStruct.new(id: "C456", name: "random", is_member: false)

    SlackService.stubs(:list_channels).returns([ non_member_channel ])

    channels = SlackService.list_member_channels
    assert_empty channels
  end

  test "get_channel_history calls Slack API with correct parameters" do
    mock_client = mock("slack_client")
    mock_response = OpenStruct.new(
      messages: [
        OpenStruct.new(ts: "1704067200.000000", text: "Hello"),
        OpenStruct.new(ts: "1704067100.000000", text: "World")
      ]
    )

    mock_client.expects(:conversations_history).with(
      channel: "C123",
      limit: 100
    ).returns(mock_response)

    SlackService.stubs(:client).returns(mock_client)

    messages = SlackService.get_channel_history("C123")
    assert_equal 2, messages.length
    assert_equal "Hello", messages[0].text
  end

  test "get_channel_history accepts oldest parameter" do
    mock_client = mock("slack_client")
    mock_response = OpenStruct.new(messages: [])

    mock_client.expects(:conversations_history).with(
      channel: "C123",
      limit: 50,
      oldest: "1704067200.000000"
    ).returns(mock_response)

    SlackService.stubs(:client).returns(mock_client)

    SlackService.get_channel_history("C123", oldest: "1704067200.000000", limit: 50)
  end

  test "get_message_permalink calls Slack API with correct parameters" do
    mock_client = mock("slack_client")
    mock_response = OpenStruct.new(permalink: "https://workspace.slack.com/archives/C123/p1704067200000000")

    mock_client.expects(:chat_getPermalink).with(
      channel: "C123",
      message_ts: "1704067200.000000"
    ).returns(mock_response)

    SlackService.stubs(:client).returns(mock_client)

    permalink = SlackService.get_message_permalink("C123", "1704067200.000000")
    assert_equal "https://workspace.slack.com/archives/C123/p1704067200000000", permalink
  end

  test "get_user calls Slack API with correct parameters" do
    mock_client = mock("slack_client")
    mock_user = OpenStruct.new(
      id: "U123",
      name: "johndoe",
      real_name: "John Doe",
      profile: OpenStruct.new(display_name: "John D")
    )
    mock_response = OpenStruct.new(user: mock_user)

    mock_client.expects(:users_info).with(user: "U123").returns(mock_response)

    SlackService.stubs(:client).returns(mock_client)

    user = SlackService.get_user("U123")
    assert_equal "U123", user.id
    assert_equal "John Doe", user.real_name
  end

  test "get_user_name returns display name when available" do
    mock_user = OpenStruct.new(
      profile: OpenStruct.new(display_name: "John D"),
      real_name: "John Doe",
      name: "johndoe"
    )

    SlackService.stubs(:get_user).returns(mock_user)

    name = SlackService.get_user_name("U123")
    assert_equal "John D", name
  end

  test "get_user_name falls back to real_name when display_name is blank" do
    mock_user = OpenStruct.new(
      profile: OpenStruct.new(display_name: ""),
      real_name: "John Doe",
      name: "johndoe"
    )

    SlackService.stubs(:get_user).returns(mock_user)

    name = SlackService.get_user_name("U123")
    assert_equal "John Doe", name
  end

  test "with_error_handling wraps Slack API errors" do
    mock_client = mock("slack_client")
    slack_error = Slack::Web::Api::Errors::SlackError.new("channel_not_found")

    mock_client.expects(:conversations_info).with(channel: "C123").raises(slack_error)

    SlackService.stubs(:client).returns(mock_client)

    error = assert_raises(SlackService::ApiError) do
      SlackService.get_channel("C123")
    end
    assert_includes error.message, "Slack API error"
  end

  test "with_error_handling retries on network errors and succeeds" do
    mock_response = OpenStruct.new(channel: OpenStruct.new(id: "C123", name: "general"))

    # Create a test client that fails twice then succeeds
    test_client = Object.new
    test_client.instance_variable_set(:@call_count, 0)
    test_client.instance_variable_set(:@mock_response, mock_response)
    def test_client.conversations_info(channel:)
      @call_count += 1
      case @call_count
      when 1 then raise Faraday::TimeoutError.new("timeout")
      when 2 then raise Faraday::ConnectionFailed.new("connection failed")
      else @mock_response
      end
    end
    def test_client.call_count
      @call_count
    end

    SlackService.stubs(:client).returns(test_client)
    SlackService.stubs(:sleep) # Don't actually sleep in tests

    channel = SlackService.get_channel("C123")
    assert_equal "C123", channel.id
    assert_equal 3, test_client.call_count
  end

  test "with_error_handling raises after max retries exceeded" do
    # Create a test client that always fails with timeout
    test_client = Object.new
    test_client.instance_variable_set(:@call_count, 0)
    def test_client.conversations_info(channel:)
      @call_count += 1
      raise Faraday::TimeoutError.new("timeout")
    end
    def test_client.call_count
      @call_count
    end

    SlackService.stubs(:client).returns(test_client)
    SlackService.stubs(:sleep) # Don't actually sleep in tests

    error = assert_raises(SlackService::ApiError) do
      SlackService.get_channel("C123")
    end
    assert_includes error.message, "Network error communicating with Slack"
    assert_equal 11, test_client.call_count # 1 initial + 10 retries
  end

  test "with_error_handling does not retry Slack API errors" do
    # Create a test client that fails with Slack API error
    test_client = Object.new
    test_client.instance_variable_set(:@call_count, 0)
    def test_client.conversations_info(channel:)
      @call_count += 1
      raise Slack::Web::Api::Errors::SlackError.new("channel_not_found")
    end
    def test_client.call_count
      @call_count
    end

    SlackService.stubs(:client).returns(test_client)

    assert_raises(SlackService::ApiError) do
      SlackService.get_channel("C123")
    end
    assert_equal 1, test_client.call_count # No retries for API errors
  end

  test "retry uses fixed 1 second delay" do
    mock_response = OpenStruct.new(channel: OpenStruct.new(id: "C123"))

    # Create a test client that fails 3 times then succeeds
    test_client = Object.new
    test_client.instance_variable_set(:@call_count, 0)
    test_client.instance_variable_set(:@mock_response, mock_response)
    def test_client.conversations_info(channel:)
      @call_count += 1
      if @call_count < 4
        raise Faraday::TimeoutError.new("timeout")
      else
        @mock_response
      end
    end

    SlackService.stubs(:client).returns(test_client)

    # Track sleep calls to verify fixed 1 second delay
    sleep_delays = []
    SlackService.stubs(:sleep).with { |delay| sleep_delays << delay; true }

    SlackService.get_channel("C123")
    assert_equal [ 1, 1, 1 ], sleep_delays
  end

  test "with_error_handling respects rate limit retry_after" do
    mock_response = OpenStruct.new(channel: OpenStruct.new(id: "C123"))

    # Create a mock TooManyRequestsError with retry_after
    rate_limit_error = Slack::Web::Api::Errors::TooManyRequestsError.allocate
    rate_limit_error.instance_variable_set(:@response, nil)
    def rate_limit_error.retry_after
      30 # Slack says wait 30 seconds
    end
    def rate_limit_error.message
      "ratelimited"
    end

    # Create a test client that gets rate limited once then succeeds
    test_client = Object.new
    test_client.instance_variable_set(:@call_count, 0)
    test_client.instance_variable_set(:@mock_response, mock_response)
    test_client.instance_variable_set(:@rate_limit_error, rate_limit_error)
    def test_client.conversations_info(channel:)
      @call_count += 1
      if @call_count == 1
        raise @rate_limit_error
      else
        @mock_response
      end
    end
    def test_client.call_count
      @call_count
    end

    SlackService.stubs(:client).returns(test_client)

    # Track sleep calls to verify we use Slack's retry_after value
    sleep_delays = []
    SlackService.stubs(:sleep).with { |delay| sleep_delays << delay; true }

    channel = SlackService.get_channel("C123")
    assert_equal "C123", channel.id
    assert_equal 2, test_client.call_count
    assert_equal [ 30 ], sleep_delays # Used Slack's retry_after value
  end

  test "with_error_handling uses fixed delay when rate limit has no retry_after" do
    mock_response = OpenStruct.new(channel: OpenStruct.new(id: "C123"))

    # Create a mock TooManyRequestsError without retry_after
    rate_limit_error = Slack::Web::Api::Errors::TooManyRequestsError.allocate
    rate_limit_error.instance_variable_set(:@response, nil)
    def rate_limit_error.retry_after
      nil # No retry_after provided
    end
    def rate_limit_error.message
      "ratelimited"
    end

    # Create a test client that gets rate limited once then succeeds
    test_client = Object.new
    test_client.instance_variable_set(:@call_count, 0)
    test_client.instance_variable_set(:@mock_response, mock_response)
    test_client.instance_variable_set(:@rate_limit_error, rate_limit_error)
    def test_client.conversations_info(channel:)
      @call_count += 1
      if @call_count == 1
        raise @rate_limit_error
      else
        @mock_response
      end
    end
    def test_client.call_count
      @call_count
    end

    SlackService.stubs(:client).returns(test_client)

    # Track sleep calls to verify we use fixed delay when no retry_after
    sleep_delays = []
    SlackService.stubs(:sleep).with { |delay| sleep_delays << delay; true }

    channel = SlackService.get_channel("C123")
    assert_equal "C123", channel.id
    assert_equal 2, test_client.call_count
    assert_equal [ 1 ], sleep_delays # Used fixed RETRY_DELAY
  end

  test "get_thread_replies calls Slack API and excludes parent message" do
    mock_client = mock("slack_client")
    mock_response = OpenStruct.new(
      messages: [
        OpenStruct.new(ts: "1704067200.000000", text: "Parent message"),
        OpenStruct.new(ts: "1704067300.000000", text: "Reply 1"),
        OpenStruct.new(ts: "1704067400.000000", text: "Reply 2")
      ],
      response_metadata: nil
    )

    mock_client.expects(:conversations_replies).with(
      channel: "C123",
      ts: "1704067200.000000",
      limit: 100,
      cursor: nil
    ).returns(mock_response)

    SlackService.stubs(:client).returns(mock_client)

    replies = SlackService.get_thread_replies("C123", "1704067200.000000")
    assert_equal 2, replies.length
    assert_equal "Reply 1", replies[0].text
    assert_equal "Reply 2", replies[1].text
  end

  test "get_thread_replies passes oldest parameter to filter replies" do
    mock_client = mock("slack_client")
    mock_response = OpenStruct.new(
      messages: [
        OpenStruct.new(ts: "1704067200.000000", text: "Parent message"),
        OpenStruct.new(ts: "1704067400.000000", text: "New reply only")
      ],
      response_metadata: nil
    )

    mock_client.expects(:conversations_replies).with(
      channel: "C123",
      ts: "1704067200.000000",
      limit: 100,
      cursor: nil,
      oldest: "1704067300.000000"
    ).returns(mock_response)

    SlackService.stubs(:client).returns(mock_client)

    replies = SlackService.get_thread_replies("C123", "1704067200.000000", oldest: "1704067300.000000")
    assert_equal 1, replies.length
    assert_equal "New reply only", replies[0].text
  end

  test "get_messages_since paginates through results" do
    mock_client = mock("slack_client")

    # First page with cursor
    first_response = OpenStruct.new(
      messages: [
        OpenStruct.new(ts: "1704067300.000000", text: "Message 1", bot_id: nil, thread_ts: nil)
      ],
      response_metadata: OpenStruct.new(next_cursor: "next_page_cursor")
    )

    # Second page without cursor (end of results)
    second_response = OpenStruct.new(
      messages: [
        OpenStruct.new(ts: "1704067400.000000", text: "Message 2", bot_id: nil, thread_ts: nil)
      ],
      response_metadata: nil
    )

    mock_client.expects(:conversations_history).with(
      channel: "C123",
      oldest: "1704067200.000000",
      limit: 100,
      cursor: nil
    ).returns(first_response)

    mock_client.expects(:conversations_history).with(
      channel: "C123",
      oldest: "1704067200.000000",
      limit: 100,
      cursor: "next_page_cursor"
    ).returns(second_response)

    SlackService.stubs(:client).returns(mock_client)

    messages = SlackService.get_messages_since("C123", since_ts: "1704067200.000000")
    # Results should be reversed (oldest first)
    assert_equal 2, messages.length
    assert_equal "Message 2", messages[0].text
    assert_equal "Message 1", messages[1].text
  end
end

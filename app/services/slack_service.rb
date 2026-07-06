# frozen_string_literal: true

require "slack-ruby-client"

# Service class for programmatic Slack API interactions
# Used by Triggers feature to poll channels and fetch messages
class SlackService
  class SlackError < StandardError; end
  class ConfigurationError < SlackError; end
  class ApiError < SlackError; end

  # Timeout configuration for Slack API calls
  # Keep these short to fail fast rather than hanging the UI
  OPEN_TIMEOUT = 5   # seconds to establish connection
  TIMEOUT = 10       # seconds for each request

  # Retry configuration for transient network errors
  # Use simple fixed delay retries - transient failures usually resolve quickly
  MAX_RETRIES = 10
  RETRY_DELAY = 1 # seconds, fixed delay between retries

  class << self
    # Get a configured Slack client instance
    def client
      raise ConfigurationError, "SLACK_BOT_TOKEN is not configured" unless slack_bot_token.present?

      @client ||= Slack::Web::Client.new(
        token: slack_bot_token,
        open_timeout: OPEN_TIMEOUT,
        timeout: TIMEOUT
      )
    end

    # Test the Slack connection
    # @return [Hash] auth.test response
    def test_connection
      with_error_handling do
        client.auth_test
      end
    end

    # Check if Slack is configured
    # @return [Boolean] true if SLACK_BOT_TOKEN is present
    def configured?
      slack_bot_token.present?
    end

    # Get the bot's own user ID (cached for the lifetime of the process)
    # @return [String] the bot's Slack user ID
    def bot_user_id
      @bot_user_id ||= test_connection.user_id
    end

    # List all channels the bot has access to
    # @param types [String] channel types to include (default: public and private channels)
    # @param exclude_archived [Boolean] exclude archived channels (default: true)
    # @return [Array<Hash>] list of channel objects
    def list_channels(types: "public_channel,private_channel", exclude_archived: true)
      with_error_handling do
        channels = []
        cursor = nil

        loop do
          response = client.conversations_list(
            types: types,
            exclude_archived: exclude_archived,
            limit: 200,
            cursor: cursor
          )

          channels.concat(response.channels || [])
          cursor = response.response_metadata&.next_cursor
          break if cursor.blank?
        end

        channels
      end
    end

    # List channels the bot is a member of (excluding DMs and archived channels)
    # @return [Array<Hash>] list of channel objects where is_member is true
    def list_member_channels
      channels = list_channels
      channels.select { |ch| ch.is_member }
    end

    # List DM channels for specific user IDs
    # @param user_ids [Array<String>] user IDs to find DM channels for
    # @return [Array<Hash>] list of DM channel objects with user field
    def list_dm_channels(user_ids:)
      with_error_handling do
        channels = []
        cursor = nil

        loop do
          response = client.conversations_list(
            types: "im",
            limit: 200,
            cursor: cursor
          )

          channels.concat(response.channels || [])
          cursor = response.response_metadata&.next_cursor
          break if cursor.blank?
        end

        # Filter to only DMs with the specified users
        user_id_set = user_ids.to_set
        channels.select { |ch| user_id_set.include?(ch.user) }
      end
    end

    # Get channel information
    # @param channel_id [String] the channel ID
    # @return [Hash] channel info
    def get_channel(channel_id)
      with_error_handling do
        response = client.conversations_info(channel: channel_id)
        response.channel
      end
    end

    # Get messages from a channel
    # @param channel_id [String] the channel ID
    # @param oldest [String] timestamp of oldest message to include
    # @param limit [Integer] max messages to return (default: 100)
    # @return [Array<Hash>] list of messages, newest first
    def get_channel_history(channel_id, oldest: nil, limit: 100)
      with_error_handling do
        params = { channel: channel_id, limit: limit }
        params[:oldest] = oldest if oldest.present?

        response = client.conversations_history(**params)
        response.messages || []
      end
    end

    # Get new messages since a given timestamp
    # @param channel_id [String] the channel ID
    # @param since_ts [String] timestamp to get messages after
    # @return [Array<Hash>] list of messages newer than since_ts, oldest first
    def get_messages_since(channel_id, since_ts:)
      with_error_handling do
        messages = []
        cursor = nil

        loop do
          params = {
            channel: channel_id,
            oldest: since_ts,
            limit: 100,
            cursor: cursor
          }

          response = client.conversations_history(**params)
          messages.concat(response.messages || [])

          cursor = response.response_metadata&.next_cursor
          break if cursor.blank?
        end

        # Return oldest first (for processing in order)
        messages.reverse
      end
    end

    # Get replies in a thread since a given timestamp
    # @param channel_id [String] the channel ID
    # @param thread_ts [String] timestamp of the parent message
    # @param oldest [String] only return replies after this timestamp (optional)
    # @return [Array<Hash>] list of replies (excluding the parent), oldest first
    def get_thread_replies(channel_id, thread_ts, oldest: nil)
      with_error_handling do
        replies = []
        cursor = nil

        loop do
          params = {
            channel: channel_id,
            ts: thread_ts,
            limit: 100,
            cursor: cursor
          }
          params[:oldest] = oldest if oldest.present?

          response = client.conversations_replies(**params)
          replies.concat(response.messages || [])

          cursor = response.response_metadata&.next_cursor
          break if cursor.blank?
        end

        # Remove the parent message (first item has ts == thread_ts) and return oldest-first
        replies.reject { |msg| msg.ts == thread_ts }
      end
    end

    # Get a permalink to a message
    # @param channel_id [String] the channel ID
    # @param message_ts [String] the message timestamp
    # @return [String] permalink URL
    def get_message_permalink(channel_id, message_ts)
      with_error_handling do
        response = client.chat_getPermalink(
          channel: channel_id,
          message_ts: message_ts
        )
        response.permalink
      end
    end

    # Get user information
    # @param user_id [String] the user ID
    # @return [Hash] user info
    def get_user(user_id)
      with_error_handling do
        response = client.users_info(user: user_id)
        response.user
      end
    end

    # Get user display name
    # @param user_id [String] the user ID
    # @return [String] user's display name or real name
    def get_user_name(user_id)
      user = get_user(user_id)
      user.profile&.display_name.presence || user.real_name || user.name
    end

    # Reset the client (useful for testing or after config changes)
    def reset!
      @client = nil
      @bot_user_id = nil
    end

    private

    def slack_bot_token
      SecretsLoader.get("SLACK_BOT_TOKEN") || ENV["SLACK_BOT_TOKEN"]
    end

    def with_error_handling
      retries = 0

      begin
        yield
      rescue Slack::Web::Api::Errors::TooManyRequestsError => e
        # Rate limited - use Slack's retry_after value if available, otherwise use fixed delay
        retries += 1
        if retries <= MAX_RETRIES
          delay = e.retry_after || RETRY_DELAY
          Rails.logger.warn("[SlackService] Rate limited (attempt #{retries}/#{MAX_RETRIES}). Retrying in #{delay}s...")
          sleep(delay)
          retry
        end
        raise ApiError, "Slack rate limit exceeded: #{e.message}"
      rescue Slack::Web::Api::Errors::SlackError => e
        # SlackError inherits from Faraday::Error, so catch it before Faraday::Error
        # Don't retry API errors (invalid channel, permission denied, etc.)
        raise ApiError, "Slack API error: #{e.message}"
      rescue Faraday::Error => e
        # Retry transient network errors (timeouts, connection failures, server errors)
        retries += 1
        if retries <= MAX_RETRIES
          Rails.logger.warn("[SlackService] Network error (attempt #{retries}/#{MAX_RETRIES}): #{e.message}. Retrying in #{RETRY_DELAY}s...")
          sleep(RETRY_DELAY)
          retry
        end
        raise ApiError, "Network error communicating with Slack: #{e.message}"
      end
    end
  end
end

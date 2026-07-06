# frozen_string_literal: true

# Concern for waiting on pending follow-up message delivery before pausing.
#
# When a user sends a follow-up and quickly pauses (or triggers an interrupt),
# there's a race condition where the message might not have been delivered to
# Claude CLI yet. This concern provides methods to wait for message delivery.
#
# Usage:
#   class SessionsController < ApplicationController
#     include PendingMessageDelivery
#
#     def pause
#       wait_for_pending_message_delivery(@session)
#       # ... proceed with pause
#     end
#   end
module PendingMessageDelivery
  extend ActiveSupport::Concern

  # Maximum time to wait for a pending message to be delivered to Claude CLI
  PENDING_MESSAGE_WAIT_TIMEOUT = 10.seconds

  # Polling interval while waiting for message delivery
  PENDING_MESSAGE_POLL_INTERVAL = 0.5.seconds

  # Wait for a pending follow-up message to be delivered before proceeding
  #
  # When a user sends a follow-up and quickly clicks pause, there's a race condition
  # where the message might not have been delivered to Claude CLI yet. This method
  # polls the transcript until the user message appears, ensuring the message isn't lost.
  #
  # @param session [Session] The session to check
  # @return [void]
  def wait_for_pending_message_delivery(session)
    pending_prompt = session.metadata&.dig("pending_follow_up_prompt")
    pending_sent_at_str = session.metadata&.dig("pending_follow_up_sent_at")

    # No pending message, nothing to wait for
    return unless pending_prompt.present? && pending_sent_at_str.present?

    pending_sent_at = Time.parse(pending_sent_at_str)

    # If the message was sent more than TIMEOUT ago, it should have been delivered
    # (or something went wrong, but we shouldn't block forever)
    return if Time.current - pending_sent_at > PENDING_MESSAGE_WAIT_TIMEOUT

    # Check if the message has already appeared in the transcript
    return if message_in_transcript?(session, pending_prompt)

    # Log that we're waiting
    session.logs.create!(
      content: "Waiting for pending message to be delivered before pausing...",
      level: "info"
    )

    # Poll until message appears or timeout
    deadline = pending_sent_at + PENDING_MESSAGE_WAIT_TIMEOUT
    while Time.current < deadline
      sleep PENDING_MESSAGE_POLL_INTERVAL
      session.reload
      if message_in_transcript?(session, pending_prompt)
        session.logs.create!(
          content: "Pending message delivered, proceeding with pause",
          level: "info"
        )
        return
      end
    end

    # Timeout - proceed anyway but log a warning
    session.logs.create!(
      content: "Timed out waiting for message delivery (#{PENDING_MESSAGE_WAIT_TIMEOUT.to_i}s), proceeding with pause",
      level: "warning"
    )
  end

  private

  # Check if a specific message content appears in the transcript
  #
  # @param session [Session] The session to check
  # @param content [String] The message content to look for
  # @return [Boolean] true if message found
  def message_in_transcript?(session, content)
    return false unless session.transcript.present?

    # Parse transcript and look for user message with matching content
    session.transcript.lines.any? do |line|
      begin
        entry = JSON.parse(line.strip)
        # Check if it's a user message with matching content
        next false unless entry["type"] == "user"

        message = entry["message"] || {}
        message_content = message["content"]

        # Content can be a string or array of content blocks
        if message_content.is_a?(String)
          message_content == content
        elsif message_content.is_a?(Array)
          message_content.any? { |block| block["type"] == "text" && block["text"] == content }
        else
          false
        end
      rescue JSON::ParserError
        false
      end
    end
  end
end

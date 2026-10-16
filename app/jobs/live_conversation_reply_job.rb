# frozen_string_literal: true

# Answers a Live Mode conversation's newest message (LiveConversations::TextReply).
#
# `responding_since` is the lock: claimed under a row lock so two messages typed
# in quick succession run one reply loop, which answers both. A claim older than
# RESPONDING_STALE_AFTER belongs to a job that died and may be taken over.
class LiveConversationReplyJob < ApplicationJob
  queue_as :inference

  def perform(conversation_id)
    conversation = LiveConversation.find_by(id: conversation_id)
    return unless conversation&.active? && conversation.text?
    return unless claim(conversation)

    begin
      LiveConversations::TextReply.call(conversation)
    rescue OpenaiClient::Error => e
      conversation.update!(error_message: "OpenAI: #{e.message}")
      failed = true
    ensure
      conversation.update!(responding_since: nil)
    end

    # A message that landed after the loop's last look, while this job still
    # held the claim, was turned away by its own job; pick it up now.
    self.class.perform_later(conversation.id) if !failed && LiveConversations::TextReply.awaiting_reply?(conversation)
  end

  private

  def claim(conversation)
    claimed = false
    conversation.with_lock do
      unless conversation.responding?
        conversation.update!(responding_since: Time.current)
        claimed = true
      end
    end
    claimed
  end
end

# frozen_string_literal: true

module LiveConversations
  # The credential one Claude delegation's `claude -p` process presents to
  # `POST /live/delegation_mcp` (LiveDelegationMcpController) to call this
  # conversation's Live tools.
  #
  # Signed and short-lived, and it names one conversation: it opens that
  # conversation's ToolBridge and nothing else on Zimmer. No API key is handed to
  # the child process, so a prompt that talks Claude into reading its own
  # environment finds nothing that outlives the delegation.
  module DelegationToken
    PURPOSE = :live_delegation_mcp
    # Longer than ClaudeClient::TIMEOUT_SECONDS, so a token cannot expire under a
    # delegation that is still allowed to run.
    TTL = 3.minutes

    Claims = Data.define(:live_conversation_id, :delegation_id)

    module_function

    def mint(conversation, delegation_id:)
      verifier.generate({ "c" => conversation.id, "d" => delegation_id.to_s }, purpose: PURPOSE, expires_in: TTL)
    end

    # @return [Claims, nil] nil for a token that is malformed, tampered with,
    #   expired, or minted for another purpose
    def verify(token)
      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      return nil unless payload.is_a?(Hash) && payload["c"].is_a?(Integer)

      Claims.new(live_conversation_id: payload["c"], delegation_id: payload["d"].to_s)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
      nil
    end

    def verifier = Rails.application.message_verifier(PURPOSE)
  end
end

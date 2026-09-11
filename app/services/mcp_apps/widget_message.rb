# frozen_string_literal: true

module McpApps
  # The View→Agent half of the host broker: a widget action becomes an agent turn.
  #
  # The spike dropped the text into the follow-up textarea and stopped there,
  # which made the demo look interactive without anything having happened. This
  # routes it into the same pipeline the follow-up form uses, so pressing a button
  # in a fragment does what pressing it in any other MCP host does — the model
  # gets the message.
  #
  # The two protocol methods are NOT the same instruction and are not delivered
  # the same way:
  #
  #   * `ui/message` is the view speaking on the user's behalf. It becomes a turn:
  #     delivered immediately to a session that is waiting, queued behind the
  #     current one if a turn is already underway.
  #   * `ui/update-model-context` is the view saying "know this", not "do this".
  #     It is always queued, so it reaches the agent as context on the next turn
  #     and never starts one. A widget that updates its own state on every click
  #     must not be able to spend a turn per click.
  #
  # Either way the text is attributed. An agent reading its transcript can tell a
  # message that came from a rendered widget from one a human typed, which matters
  # the moment the widget was written by somebody else.
  class WidgetMessage
    KINDS = %w[message context].freeze

    # A widget's message is a sentence, not a document. Far below
    # Session::PROMPT_MAX_LENGTH on purpose: this is the one prompt channel whose
    # content is composed by third-party code.
    MAX_LENGTH = 4000

    Result = Data.define(:status, :message) do
      def ok? = status != :rejected
    end

    class << self
      # @param session [Session]
      # @param server_name [String] the MCP server the fragment came from
      # @param tool [String] the tool whose view sent it
      # @param text [String] what the view said
      # @param kind [String] "message" or "context"
      # @return [Result]
      def deliver(session:, server_name:, tool:, text:, kind:)
        body = text.to_s.strip
        return rejected("the view sent no text") if body.empty?
        return rejected("the view sent more than #{MAX_LENGTH} characters") if body.length > MAX_LENGTH
        return rejected("unknown message kind") unless KINDS.include?(kind.to_s)

        prompt = attributed(body, server_name: server_name, tool: tool, kind: kind)

        if kind.to_s == "context" || Sessions::LiveTurn.underway?(session)
          queue(session, prompt)
        elsif session.waiting? || session.needs_input?
          send_now(session, prompt)
        else
          rejected("this session is #{session.status} and cannot take a message")
        end
      end

      private

      def attributed(body, server_name:, tool:, kind:)
        label = kind.to_s == "context" ? "context update" : "message"
        "[MCP App #{label} from #{server_name}/#{tool}]\n\n#{body}"
      end

      def queue(session, prompt)
        position = (session.enqueued_messages.maximum(:position) || 0) + 1
        session.enqueued_messages.create!(content: prompt, position: position, status: "pending")
        session.logs.create!(
          content: "MCP App widget queued a message at position #{position}",
          level: "info"
        )
        session.touch_user_activity!
        Result.new(status: :queued, message: "Queued for the agent's next turn.")
      rescue ActiveRecord::RecordInvalid => e
        rejected(e.message)
      end

      def send_now(session, prompt)
        sent_at = Time.current
        BroadcastService.new.optimistic_user_message(session, prompt, sent_at: sent_at)
        session.deliver_follow_up!(
          prompt,
          clear_metadata_keys: Session::STALE_RETRY_METADATA_KEYS,
          metadata_updates: {
            "pending_follow_up_sent_at" => sent_at.iso8601,
            "sent_message" => prompt,
            "sent_message_at" => sent_at.iso8601,
            "last_user_activity_at" => sent_at.iso8601
          }
        )
        session.logs.create!(content: "MCP App widget sent a message to the agent", level: "info")
        Result.new(status: :delivered, message: "Sent to the agent.")
      rescue ActiveRecord::RecordInvalid, AASM::InvalidTransition => e
        rejected(e.message)
      end

      def rejected(message)
        Result.new(status: :rejected, message: message)
      end
    end
  end
end

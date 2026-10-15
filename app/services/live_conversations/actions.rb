# frozen_string_literal: true

module LiveConversations
  # Everything a client does to a live conversation, behind both the web
  # controller and the REST API (and so the iOS app), with one set of rules.
  class Actions
    # A refusal a client should show as-is.
    class Refused < StandardError
      attr_reader :status

      def initialize(message, status: :unprocessable_entity)
        super(message)
        @status = status
      end
    end

    MESSAGE_MAX_LENGTH = 8_000

    def initialize(conversation)
      @conversation = conversation
    end

    # A typed message (Live Mode). Answered by LiveConversationReplyJob — or,
    # when it arrives while the conversation is still preparing, by the reply
    # LiveConversationPrepareJob starts once it is active.
    def post_message(text)
      require_open!
      raise Refused, "#{@conversation.live_mode.label} takes spoken turns, not typed messages." unless @conversation.text?

      text = text.to_s.strip
      raise Refused, "Message can't be blank." if text.empty?
      raise Refused, "Message is too long (maximum #{MESSAGE_MAX_LENGTH} characters)." if text.length > MESSAGE_MAX_LENGTH

      turn = @conversation.turns.create!(role: "user", source: "typed", content: text)
      @conversation.touch_activity!
      LiveConversationReplyJob.perform_later(@conversation.id)
      turn
    end

    # Live Voice: a short-lived secret the client opens its audio connection with.
    def client_secret
      require_voice!
      RealtimeSession.mint(@conversation)
    rescue OpenaiClient::NotConfiguredError => e
      raise Refused.new(e.message, status: :service_unavailable)
    rescue OpenaiClient::Error => e
      raise Refused.new("OpenAI: #{e.message}", status: :bad_gateway)
    end

    # Live Voice: run a function call the model made, return what to send back.
    def tool_call(name:, arguments:, call_id:)
      require_voice!
      raise Refused, "name is required." if name.blank?
      raise Refused, "call_id is required." if call_id.blank?

      bridge = ToolBridge.new(@conversation)
      result = bridge.execute(name, arguments, call_id: call_id)
      response = { output: result.output, error: result.error, tools_changed: result.tools_changed, turn_id: result.turn.id }
      response[:tools] = ToolBridge.new(@conversation.reload).realtime_tools if result.tools_changed
      response
    end

    # Live Voice: a finished transcript line, so the thread on the page and in
    # the API carries what was said.
    def record_turn(role:, content:)
      require_voice!
      raise Refused, "role must be user or assistant." unless %w[user assistant].include?(role.to_s)

      content = content.to_s.strip
      raise Refused, "content can't be blank." if content.empty?

      turn = @conversation.turns.create!(role: role.to_s, source: "spoken", content: content.truncate(MESSAGE_MAX_LENGTH))
      @conversation.touch_activity!
      turn
    end

    def finish
      @conversation.end!
      @conversation
    end

    private

    def require_open!
      return if @conversation.open?

      raise Refused.new("This conversation has #{@conversation.status}. Start a new one.", status: :conflict)
    end

    def require_active!
      return if @conversation.active?

      message = if @conversation.preparing?
        "This conversation is still reading its instructions. Try again in a moment."
      else
        "This conversation has #{@conversation.status}. Start a new one."
      end
      raise Refused.new(message, status: :conflict)
    end

    def require_voice!
      require_active!
      raise Refused, "This is a #{@conversation.live_mode.label} conversation, not Live Voice." unless @conversation.voice?
    end
  end
end

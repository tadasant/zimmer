# frozen_string_literal: true

module LiveConversations
  # Everything a client does to a live conversation, behind the web controller,
  # the REST API (and so the iOS app) and the MCP tool, with one set of rules.
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

    # @param client_surface [String, nil] the TurnSource surface of the client
    #   making this call. Each action a client takes on the conversation records it
    #   as the one driving it now, so a delegation the live model makes next is
    #   tagged with where the person actually is. nil leaves it alone.
    # @param listening_modes [Boolean] whether the client asks for each reply
    #   itself when the Listening setting is gated (Listening). One that does
    #   not is always answered as `always`. Neither is the car: a call from
    #   CarPlay answers every line, whatever Listening says. The car is one
    #   driver in a private space, a gate there drops lines without a sound,
    #   and the call sits on Listening as though it never heard. A call handed
    #   to the car mid-call is brought up to `always` by its next
    #   `session_update`, which the hand-over sends.
    def initialize(conversation, client_surface: nil, listening_modes: false)
      @conversation = conversation
      @client_surface = LiveConversation.normalize_client_surface(client_surface)
      @listening_modes = listening_modes && @client_surface != "carplay"
    end

    # A typed message. Answered by LiveConversationReplyJob — or, when it
    # arrives while the conversation is still preparing, by the reply
    # LiveConversationPrepareJob starts once it is active.
    #
    # Refused while voice is on: the Realtime call holds the conversation then,
    # and a reply written behind its back is one the call never hears.
    def post_message(text)
      require_open!
      raise Refused, "Voice is on for this conversation. Turn it off to type." if @conversation.voice?

      text = text.to_s.strip
      raise Refused, "Message can't be blank." if text.empty?
      raise Refused, "Message is too long (maximum #{MESSAGE_MAX_LENGTH} characters)." if text.length > MESSAGE_MAX_LENGTH

      note_client!
      turn = @conversation.turns.create!(role: "user", source: "typed", content: text)
      @conversation.touch_activity!
      LiveConversationReplyJob.perform_later(@conversation.id)
      turn
    end

    # Typed ⇄ spoken, mid-conversation. Turning voice on is what lets a client
    # mint a Realtime secret, whose instructions are built for speech; turning
    # it off makes the next typed reply's instructions the typed ones.
    def switch_mode(mode_key)
      require_open!
      raise Refused, "mode must be one of: #{LiveConversations.mode_keys.join(', ')}" unless LiveConversations.mode_keys.include?(mode_key.to_s)

      was_voice = @conversation.voice?
      note_client!
      @conversation.switch_mode!(mode_key)
      # A message typed before voice went on was never answered: the typed
      # path answers it now.
      LiveConversationReplyJob.perform_later(@conversation.id) if was_voice && @conversation.text? && @conversation.active? && TextReply.awaiting_reply?(@conversation)
      @conversation
    end

    # Voice: a short-lived secret the client opens its audio connection with.
    # The client asking is the one about to drive the call, so it is noted
    # first and the instructions minted with the secret name it.
    def client_secret
      require_voice!
      note_client!
      RealtimeSession.mint(@conversation, listening_modes: @listening_modes)
    rescue OpenaiClient::NotConfiguredError => e
      raise Refused.new(e.message, status: :service_unavailable)
    rescue OpenaiClient::Error => e
      raise Refused.new("OpenAI: #{e.message}", status: :bad_gateway)
    end

    # Voice: run a function call the model made, return what to send back.
    #
    # This and record_turn need an active conversation, not voice mode: a call
    # already connected when voice is turned off elsewhere still finishes what
    # it was saying, and the thread should still carry it.
    def tool_call(name:, arguments:, call_id:)
      require_active!
      raise Refused, "name is required." if name.blank?
      raise Refused, "call_id is required." if call_id.blank?

      note_client!
      bridge = ToolBridge.new(@conversation)
      result = bridge.execute(name, arguments, call_id: call_id)
      response = { output: result.output, error: result.error, tools_changed: result.tools_changed, turn_id: result.turn.id }
      response[:tools] = ToolBridge.new(@conversation.reload).realtime_tools if result.tools_changed
      # The live model changed its own settings: hand the client the
      # `session.update` that applies them to the call it is on.
      response[:session] = realtime_session(@conversation.reload).session_update if result.session_changed
      response
    end

    # Voice: the `session.update` that brings an open call up to the current
    # settings and guidance — what a client sends after a person changed them on
    # the settings page or in the app mid-call. Active, not voice, for the same
    # reason as tool_call below. Noted first, like the secret: a call that moves
    # between the phone and the car asks for this to bring its instructions up
    # to the client now driving it.
    def session_update
      require_active!
      note_client!
      realtime_session(@conversation).session_update
    end

    # What record_turn answers: the line it kept (nil when it dropped one), and
    # whether the call should answer it.
    Heard = Data.define(:turn, :respond) do
      def as_api_json = (turn ? turn.as_api_json : {}).merge(respond: respond, dropped: turn.nil?)
    end

    # Voice: a finished transcript line, so the thread on the page and in the
    # API carries what was said. A user line is also where Listening decides
    # whether the call answers it; in a gated mode a line it will not answer is
    # dropped rather than kept.
    def record_turn(role:, content:)
      require_active!
      raise Refused, "role must be user or assistant." unless %w[user assistant].include?(role.to_s)

      content = content.to_s.strip
      raise Refused, "content can't be blank." if content.empty?

      respond = role.to_s != "user" || listening.respond?(content)
      return Heard.new(turn: nil, respond: false) unless respond

      turn = @conversation.turns.create!(role: role.to_s, source: "spoken", content: content.truncate(MESSAGE_MAX_LENGTH))
      @conversation.touch_activity!
      Heard.new(turn: turn, respond: true)
    end

    def finish
      @conversation.end!
      @conversation
    end

    private

    def listening
      setting = LiveSetting.current
      Listening.new(@conversation, mode: Listening.mode(setting, capable: @listening_modes), setting: setting)
    end

    def realtime_session(conversation) = RealtimeSession.new(conversation, listening_modes: @listening_modes)

    # A single column write, and not through callbacks: which client last spoke is
    # bookkeeping for the turn-source note, not a change the page re-renders for.
    def note_client!
      return if @client_surface.nil? || @conversation.client_surface == @client_surface

      @conversation.update_column(:client_surface, @client_surface)
    end

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
      raise Refused.new("Voice is off for this conversation. Turn it on first.", status: :conflict) unless @conversation.voice?
    end
  end
end

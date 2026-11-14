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
    #   `session_update`, which the hand-over sends, and stays there until it
    #   hangs up, on the phone too (`LiveConversation#car_call`): the person
    #   carrying on from the car was never told the rules changed, so a gate
    #   arriving with the hand-over would look like a call that went deaf.
    # @param reattaches [Boolean] whether the client can move its call to another
    #   conversation when a tool call answers `switched_to`. One that cannot is
    #   refused the switch rather than left talking on a conversation that ended.
    # @param hangs_up [Boolean] whether the client closes its call when a tool
    #   call answers `hang_up`. One that cannot is refused the hang-up, and the
    #   model tells the person to tap End.
    # @param author [Author, nil] the human this request authenticated as, from
    #   the controller that accepted it. Stamped on the `user` turns this call
    #   writes, and the only thing HumanMessageCapture.record_live_mode_message
    #   attributes from. nil — the MCP tool's — writes turns nobody is said to
    #   have authored.
    # @param engines [Array<String>] the experimental voice engines this client
    #   can run (VoiceEngine). A client that names none runs only the default.
    def initialize(conversation, client_surface: nil, listening_modes: false, reattaches: false, hangs_up: false, author: nil, engines: [])
      @conversation = conversation
      @engines = Array(engines).map(&:to_s) & VoiceEngine::KEYS
      @author = author
      @reattaches = reattaches
      @hangs_up = hangs_up
      @client_surface = LiveConversation.normalize_client_surface(client_surface)
      @listening_modes = listening_modes
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
      turn = @conversation.turns.create!(role: "user", source: "typed", content: text, **authorship)
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
    #
    # `prewarm`: the CarPlay app asking ahead of a tap, for a connection it
    # holds idle until the driver chooses Continue (ios/CARPLAY_PREWARM_DESIGN.md).
    # Nobody is driving a call yet, so nothing on the conversation changes: no
    # client noted, no `car_call`, no model written, and voice need not be on.
    # The tap turns voice on and sends a fresh `session_update` before any
    # audio goes up, which brings the warm session's instructions to the
    # conversation as it is then. Only the car pre-warms.
    #
    # Which engine runs the call is decided here (VoiceEngine): the default
    # answers with the Realtime secret as always; `gpt_live_claude` answers
    # with no secret — the client starts that call with #gpt_live_session —
    # and an engine that cannot run falls back to the default, saying why in
    # `engine.fallback_reason`. Either way the answer names the engine.
    def client_secret(prewarm: false)
      return prewarm_secret if prewarm

      require_voice!
      note_client!(new_call: true)
      resolution = VoiceEngine.resolve(@conversation, client_engines: @engines)
      record_engine!(resolution)
      return { engine: resolution.engine, voice_engine: resolution.as_api_json } if resolution.engine == VoiceEngine::GPT_LIVE

      RealtimeSession.mint(@conversation, listening_modes: listening_modes?).merge(engine: resolution.engine, voice_engine: resolution.as_api_json)
    rescue OpenaiClient::NotConfiguredError => e
      raise Refused.new(e.message, status: :service_unavailable)
    rescue OpenaiClient::Error => e
      raise Refused.new("OpenAI: #{e.message}", status: :bad_gateway)
    end

    # Voice, `gpt_live_claude`: start the GPT-Live session with the browser's
    # WebRTC offer and return OpenAI's answer. Only for a conversation whose
    # call this client was just told runs on GPT-Live (#client_secret), so a
    # client cannot reach an engine the settings, the keys or the caps refused.
    def gpt_live_session(sdp:)
      require_voice!
      require_engine!(VoiceEngine::GPT_LIVE)
      # Decided again here, not trusted from the column: the settings, a key or
      # a cap may have changed since the call was resolved, and each session
      # this opens is billed.
      resolution = VoiceEngine.resolve(@conversation, client_engines: [ VoiceEngine::GPT_LIVE ])
      unless resolution.engine == VoiceEngine::GPT_LIVE
        raise Refused.new("GPT-Live is not available for this call: #{resolution.fallback_reason}. Start the call again.", status: :conflict)
      end

      GptLiveSession.start(@conversation, sdp: sdp)
    rescue GptLiveSession::Invalid => e
      raise Refused, e.message
    rescue OpenaiClient::NotConfiguredError => e
      raise Refused.new(e.message, status: :service_unavailable)
    rescue OpenaiClient::Error => e
      raise Refused.new("OpenAI: #{e.message}", status: :bad_gateway)
    end

    # Voice, `gpt_live_claude`: GPT-Live delegated a request; Claude does it
    # (ClaudeDelegate) and the client appends the answer as commentary.
    # `end_call` in the answer means the client hangs up once it is said — the
    # person asked to, or the engine hit a spend cap.
    def delegate(delegation_id:, pending_user_text: nil)
      require_active!
      require_engine!(VoiceEngine::GPT_LIVE)
      raise Refused, "delegation_id is required." if delegation_id.blank?

      note_client!
      ClaudeDelegate.call(@conversation, delegation_id: delegation_id, pending_user_text: pending_user_text)
    rescue ClaudeClient::NotConfiguredError => e
      raise Refused.new(e.message, status: :service_unavailable)
    end

    # Voice: what the client measured about its call's cost and speed, into
    # the ledger (UsageReport). Active or not: the last report of a call can
    # land after the conversation ended.
    def record_usage(events, model: nil)
      UsageReport.call(@conversation, events, model: model)
    rescue UsageReport::Invalid => e
      raise Refused, e.message
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
      bridge = ToolBridge.new(@conversation, can_reattach: @reattaches, can_hang_up: @hangs_up)
      result = bridge.execute(name, arguments, call_id: call_id)
      response = { output: result.output, error: result.error, tools_changed: result.tools_changed, turn_id: result.turn.id }
      # Nothing more goes down this socket: the client reconnects onto the
      # conversation this names, with its own instructions and tools.
      return response.merge(switched_to: { id: result.switched_to.id, title: result.switched_to.spoken_title }) if result.switched_to
      # The person asked to end the call: the client answers this call, asks for
      # no reply after it, and closes the call once the goodbye has sounded.
      return response.merge(hang_up: true) if result.hung_up

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
    #
    # `model`: the model the call runs on, recorded on the conversation. A call
    # that started on a CarPlay pre-warm connection sends it with the tap's
    # update, because its prewarm mint recorded nothing.
    def session_update(model: nil)
      require_active!
      note_client!
      record_model!(model)
      realtime_session(@conversation).session_update
    end

    # What record_turn answers: the line it kept (nil when it dropped one),
    # whether the call should answer it, and the Listening mode that decided.
    Heard = Data.define(:turn, :respond, :listening) do
      def as_api_json = (turn ? turn.as_api_json : {}).merge(respond: respond, dropped: turn.nil?, listening: listening)
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

      # A line from the car proves the call has been there, even when the
      # hand-over's own `session_update` never landed. The surface is left
      # alone: a line still in flight after the hand-over must not take it back.
      @conversation.update_column(:car_call, true) if @client_surface == "carplay" && !@conversation.car_call

      setting = LiveSetting.current
      mode = Listening.mode(setting, capable: listening_modes?)
      respond = role.to_s != "user" || Listening.new(@conversation, mode: mode, setting: setting).respond?(content)
      return Heard.new(turn: nil, respond: false, listening: mode) unless respond

      turn = @conversation.turns.create!(role: role.to_s, source: "spoken", content: content.truncate(MESSAGE_MAX_LENGTH),
                                         **(role.to_s == "user" ? authorship : {}))
      @conversation.touch_activity!
      Heard.new(turn: turn, respond: true, listening: mode)
    end

    def finish
      @conversation.end!
      @conversation
    end

    private

    def prewarm_secret
      raise Refused, "Only the CarPlay app pre-warms a connection." unless @client_surface == "carplay"

      require_active!
      RealtimeSession.mint(@conversation, listening_modes: listening_modes?, record_model: false)
    rescue OpenaiClient::NotConfiguredError => e
      raise Refused.new(e.message, status: :service_unavailable)
    rescue OpenaiClient::Error => e
      raise Refused.new("OpenAI: #{e.message}", status: :bad_gateway)
    end

    # `surface` is the client this line came from, kept on the line itself so a
    # human message can say where it was said. Display only.
    def authorship
      return {} if @author.nil?

      { author: @author.key, author_provenance: @author.provenance.merge("surface" => @client_surface).compact }
    end

    # Whether this request may gate the call: the client can, and neither it nor
    # anything earlier in this call is the car.
    def listening_modes? = @listening_modes && @client_surface != "carplay" && !@conversation.car_call

    def realtime_session(conversation) = RealtimeSession.new(conversation, listening_modes: listening_modes?)

    # Column writes, and not through callbacks: which client last spoke is
    # bookkeeping for the turn-source note and Listening, not a change the page
    # re-renders for. A secret is a new call, so it alone can clear `car_call`.
    def note_client!(new_call: false)
      columns = { car_call: @client_surface == "carplay" || (!new_call && @conversation.car_call) }
      columns[:client_surface] = @client_surface if @client_surface
      columns.reject! { |column, value| @conversation[column] == value }
      @conversation.update_columns(columns) if columns.any?
    end

    MODEL_NAME = /\A[a-z0-9][a-z0-9.\-]{0,63}\z/

    def record_model!(model)
      model = model.to_s
      return if model.empty? || @conversation.model == model
      raise Refused, "model is not a model name." unless MODEL_NAME.match?(model)

      @conversation.update_columns(model: model)
    end

    # The engine the call resolved to, on the conversation; a fallback is also
    # a ledger row, so /live/costs can count how often an engine was asked for
    # and not run.
    def record_engine!(resolution)
      @conversation.update_columns(voice_engine: resolution.engine, voice_engine_fallback: resolution.fallback_reason&.truncate(250))
      return unless resolution.fallback?

      LiveUsageEvent.record!(engine: resolution.requested, operation: "engine_fallback", vendor: "zimmer", live_conversation: @conversation,
                             count: 1, error: resolution.fallback_reason.truncate(250), details: { ran_on: resolution.engine, surface: @client_surface })
    rescue ActiveRecord::ActiveRecordError => e
      ErrorReporter.report_exception(e, context: { source: "LiveConversations::Actions#record_engine!", live_conversation_id: @conversation.id })
    end

    def require_engine!(engine)
      return if @conversation.voice_engine == engine

      raise Refused.new("This call is not running on #{engine}. Start the call again.", status: :conflict)
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

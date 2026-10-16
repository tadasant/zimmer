# frozen_string_literal: true

module LiveConversations
  # One Live Mode reply: send the thread to Chat Completions, run any function
  # calls through the ToolBridge, feed the results back, and repeat until the
  # model answers in words. If the human typed again while this was running,
  # answer that too before letting go — the thread is single, so the newest
  # message is always the one being answered.
  #
  # Chat Completions rather than the Responses API because the thread is
  # replayed from Zimmer's own rows every time (nothing is stored at OpenAI),
  # and Chat Completions takes a replayed tool exchange as plain messages.
  class TextReply
    # A model that keeps calling tools without ever answering is stopped here.
    MAX_ROUNDS = 8
    # How much of a long thread is replayed. Older turns stay on the page.
    HISTORY_TURNS = 80

    def self.call(conversation, client: OpenaiClient.new) = new(conversation, client: client).call

    # The thread ends with something the model has not answered: a human
    # message, or tool output it has not seen.
    def self.awaiting_reply?(conversation)
      last = conversation.turns.reorder(id: :desc).first
      last.present? && !last.assistant?
    end

    def initialize(conversation, client:)
      @conversation = conversation
      @client = client
      @bridge = ToolBridge.new(conversation)
    end

    def call
      rounds = 0
      while awaiting_reply?
        rounds += 1
        if rounds > MAX_ROUNDS
          @conversation.turns.create!(role: "assistant", content: "I stopped after #{MAX_ROUNDS} rounds of tool calls without an answer. Ask again, or narrow it down.")
          break
        end
        step
      end
      if @settings_warning
        @conversation.update!(error_message: @settings_warning)
      elsif @conversation.error_message.present?
        @conversation.update!(error_message: nil)
      end
    end

    private

    # Also true when a message arrived while a request was in flight: its turn
    # sits before that request's answer, so "the thread ends on an assistant
    # turn" alone would leave it unanswered.
    def awaiting_reply?
      return true if self.class.awaiting_reply?(@conversation)

      @answered_through.present? && @conversation.turns.where(role: "user").where("id > ?", @answered_through).exists?
    end

    # The reply job's claim (`responding_since`) is renewed before every OpenAI
    # request and every tool call, so a long multi-round reply never looks
    # abandoned to a second job: each of those operations is bounded well under
    # RESPONDING_STALE_AFTER. Written without callbacks — it is not a change the
    # page needs to hear about.
    def heartbeat!
      @conversation.update_columns(responding_since: Time.current) if @conversation.responding_since.present?
    end

    def step
      heartbeat!
      setting = LiveSetting.current
      response = begin
        @client.chat_completion(request_body(setting))
      rescue OpenaiClient::Error => e
        raise unless refused_settings?(e, setting)

        # OpenAI refused the configured settings (a model this key cannot use):
        # answer on the defaults rather than not at all, and say why on the page.
        @settings_warning = "OpenAI refused the Live settings (#{e.message.truncate(200)}), so this reply ran on the defaults. Change them on the Live settings page."
        Rails.logger.warn("[LiveConversations::TextReply] #{@settings_warning}")
        heartbeat!
        @client.chat_completion(request_body(LiveSetting.new(guidance: setting.guidance)))
      end
      message = response.dig("choices", 0, "message") || {}
      calls = Array(message["tool_calls"]).select { |call| call["type"] == "function" || call["function"] }
      text = message["content"].to_s.strip

      @conversation.turns.create!(role: "assistant", content: text) if text.present?
      if calls.empty?
        @conversation.turns.create!(role: "assistant", content: "(no reply)") if text.blank?
        return
      end

      calls.each do |call|
        heartbeat!
        call_id = call["id"].presence || "call_#{SecureRandom.hex(8)}"
        @bridge = ToolBridge.new(@conversation) if @bridge.execute(call.dig("function", "name"), call.dig("function", "arguments"), call_id: call_id).tools_changed
      end
    end

    # Read from LiveSetting on every request, so a change applies from the next
    # turn. `reasoning_effort` is always "none": it is the only effort at which
    # Chat Completions takes function tools from the GPT-6 models (LiveSetting).
    def request_body(setting)
      model = setting.effective(:text_model)
      @conversation.update_columns(model: model) if @conversation.model != model
      body = {
        model: model,
        reasoning_effort: "none",
        messages: messages(setting),
        tools: @bridge.chat_tools,
        tool_choice: "auto"
      }
      body[:temperature] = setting.effective(:text_temperature) if setting.overridden?(:text_temperature)
      body[:max_completion_tokens] = setting.effective(:text_max_output_tokens) if setting.overridden?(:text_max_output_tokens)
      body
    end

    def refused_settings?(error, setting)
      [ 400, 404, 422 ].include?(error.status) && LiveSetting::KEYS.any? { |key| key.start_with?("text_") && setting.overridden?(key) }
    end

    def messages(setting)
      list = [ { role: "system", content: SystemPrompt.build(@conversation, setting: setting) } ]
      turns = @conversation.turns.reorder(id: :desc).limit(HISTORY_TURNS).to_a.reverse
      @answered_through = turns.select(&:user?).map(&:id).max
      turns.shift while turns.first&.tool? # never open on an orphaned tool result

      turns.chunk_while { |a, b| a.tool? && b.tool? }.each do |group|
        if group.first.tool?
          list << {
            role: "assistant",
            content: nil,
            tool_calls: group.map do |turn|
              { id: turn.call_id, type: "function", function: { name: turn.tool_name, arguments: JSON.generate(turn.tool_arguments || {}) } }
            end
          }
          group.each { |turn| list << { role: "tool", tool_call_id: turn.call_id, content: turn.model_output } }
        else
          group.each { |turn| list << { role: turn.role, content: turn.content.to_s } }
        end
      end
      list
    end
  end
end

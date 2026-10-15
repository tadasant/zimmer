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
      @conversation.update!(error_message: nil) if @conversation.error_message.present?
    end

    private

    # Also true when a message arrived while a request was in flight: its turn
    # sits before that request's answer, so "the thread ends on an assistant
    # turn" alone would leave it unanswered.
    def awaiting_reply?
      return true if self.class.awaiting_reply?(@conversation)

      @answered_through.present? && @conversation.turns.where(role: "user").where("id > ?", @answered_through).exists?
    end

    def step
      response = @client.chat_completion(
        model: @conversation.model,
        reasoning_effort: "none",
        messages: messages,
        tools: @bridge.chat_tools,
        tool_choice: "auto"
      )
      message = response.dig("choices", 0, "message") || {}
      calls = Array(message["tool_calls"]).select { |call| call["type"] == "function" || call["function"] }
      text = message["content"].to_s.strip

      @conversation.turns.create!(role: "assistant", content: text) if text.present?
      if calls.empty?
        @conversation.turns.create!(role: "assistant", content: "(no reply)") if text.blank?
        return
      end

      calls.each do |call|
        @bridge = ToolBridge.new(@conversation) if @bridge.execute(call.dig("function", "name"), call.dig("function", "arguments"), call_id: call["id"]).tools_changed
      end
    end

    def messages
      list = [ { role: "system", content: SystemPrompt.build(@conversation) } ]
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

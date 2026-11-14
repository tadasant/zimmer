# frozen_string_literal: true

module LiveConversations
  # Claude answering one GPT-Live delegation (the `gpt_live_claude` engine):
  # the front end decided the person's request needs Zimmer or real thought,
  # and this does it — a Messages API tool loop over the same ToolBridge every
  # other Live path uses — and returns words for the front end to say.
  #
  # A delegation carries no task text (GPT-Live hands over an id, not the
  # request), so Claude reads the request from the thread: the recent turns,
  # plus the person's line the client had not yet written as a turn.
  #
  # Every Messages call is one LiveUsageEvent (`delegation`: model, tokens,
  # cache reads and writes, latency) and every tool Claude runs is one
  # (`tool_call`), so /live/costs can say what each delegation cost. The spend
  # cap is checked before Claude is called: a capped engine answers with the
  # cap and `end_call`, and the client ends the call (VoiceEngine sends the
  # next one to the default engine).
  #
  # The answer is split into chunks under GPT-Live's 500-token limit on one
  # `session.commentary.append`.
  class ClaudeDelegate
    MAX_ROUNDS = 6
    MAX_TOKENS = 4_096
    HISTORY_TURNS = 40
    TURN_CHARS = 1_500
    # ~4 characters a token keeps a chunk well under GPT-Live's 500 tokens.
    CHUNK_CHARS = 1_400
    PENDING_MAX_CHARS = 4_000
    ENGINE = VoiceEngine::GPT_LIVE

    # `cost_usd` is the list price of what this delegation used; `billed_usd`
    # the part of it that was billed (nothing, for Claude on a subscription).
    Result = Data.define(:text, :chunks, :end_call, :hung_up, :warning, :rounds, :cost_usd, :billed_usd) do
      def as_api_json = { text: text, chunks: chunks, end_call: end_call, hung_up: hung_up, warning: warning, rounds: rounds,
                          cost_usd: cost_usd.round(6), billed_usd: billed_usd.round(6) }.compact
    end

    def self.call(conversation, delegation_id:, pending_user_text: nil, setting: LiveSetting.current, client: nil)
      new(conversation, delegation_id: delegation_id, pending_user_text: pending_user_text, setting: setting, client: client).call
    end

    def initialize(conversation, delegation_id:, pending_user_text:, setting:, client:)
      @conversation = conversation
      @delegation_id = delegation_id.to_s
      @pending = pending_user_text.to_s.strip.truncate(PENDING_MAX_CHARS)
      @setting = setting
      @client = client
      @bridge = ToolBridge.new(conversation, can_reattach: false, can_hang_up: true)
      @cost = 0.0
      @billed = 0.0
    end

    def call
      check = SpendGuard.check(engine: ENGINE, conversation: @conversation, setting: @setting)
      if check.blocked?
        return result("I've hit the spend cap for this voice engine: #{check.reason}. I'm ending this call; call again and " \
                      "you'll be on the standard voice.", end_call: true, warning: check.reason, rounds: 0)
      end

      messages = [ { role: "user", content: request_text } ]
      texts = []
      rounds = 0
      hung_up = false
      while rounds < MAX_ROUNDS
        rounds += 1
        response = claude_call(messages, rounds, last: rounds == MAX_ROUNDS)
        content = Array(response["content"])
        texts = content.select { |block| block["type"] == "text" }.map { |block| block["text"].to_s }.reject(&:blank?)
        uses = content.select { |block| block["type"] == "tool_use" }
        break if uses.empty? || response["stop_reason"] != "tool_use"

        # Replayed as the API sent it, minus the nulls the gem's serializer
        # fills in for fields the block did not carry.
        messages << { role: "assistant", content: content.map(&:compact) }
        results = uses.map { |use| run_tool(use) }
        messages << { role: "user", content: results }
        hung_up = @hung_up
        break if hung_up
      end

      text = texts.join(" ").squish
      text = "I couldn't finish that in time. Ask again, or narrow it down." if text.blank? && !hung_up
      result(text, end_call: hung_up, hung_up: hung_up, warning: check.warning, rounds: rounds)
    rescue ClaudeClient::NotConfiguredError
      raise
    rescue ClaudeClient::Error => e
      record(operation: "delegation", vendor: "anthropic", model: model, error: e.message.truncate(250),
             details: { delegation_id: @delegation_id })
      result("I couldn't reach my reasoning backend just now (#{e.message.truncate(120)}). Try again in a moment.",
             end_call: false, warning: nil, rounds: rounds.to_i)
    end

    private

    def result(text, end_call:, warning:, rounds:, hung_up: false)
      Result.new(text: text, chunks: self.class.chunk(text), end_call: end_call, hung_up: hung_up, warning: warning,
                 rounds: rounds, cost_usd: @cost, billed_usd: @billed)
    end

    def model = @setting.effective(:voice_claude_model)

    def client = @client ||= ClaudeClient.new

    # `last`: the final round may not call tools, so it has to answer with
    # what it has rather than start work whose results nobody would read.
    def claude_call(messages, round, last: false)
      started = monotonic_ms
      params = {
        model: model,
        max_tokens: MAX_TOKENS,
        # The tools and this prompt are the same on every round of the loop, so
        # one breakpoint after them makes rounds two onwards cache reads.
        system_: [ { type: "text", text: system_prompt, cache_control: { type: "ephemeral" } } ],
        tools: tools,
        messages: messages
      }
      params[:tool_choice] = { type: "none" } if last
      response = client.create_message(**params)
      usage = response["usage"] || {}
      # Priced on the model asked for, which is the price table's key: the API
      # can answer with a dated snapshot id the table does not list, and an
      # unpriced row would never count toward a cap.
      record(operation: "delegation", vendor: "anthropic", model: model,
             input_tokens: usage["input_tokens"].to_i, output_tokens: usage["output_tokens"].to_i,
             cache_read_tokens: usage["cache_read_input_tokens"].to_i, cache_write_tokens: usage["cache_creation_input_tokens"].to_i,
             count: 1, latency_ms: monotonic_ms - started,
             details: { delegation_id: @delegation_id, round: round, stop_reason: response["stop_reason"], response_model: response["model"].to_s })
      response
    end

    def run_tool(use)
      started = monotonic_ms
      outcome = @bridge.execute(use["name"].to_s, use["input"] || {}, call_id: use["id"].to_s)
      @hung_up ||= outcome.hung_up
      record(operation: "tool_call", vendor: "zimmer", model: use["name"].to_s.truncate(120), count: 1,
             latency_ms: monotonic_ms - started, error: (outcome.output.to_s.truncate(250) if outcome.error),
             details: { delegation_id: @delegation_id, call_id: use["id"].to_s })
      { type: "tool_result", tool_use_id: use["id"].to_s, content: outcome.output.to_s, is_error: outcome.error ? true : false }
    end

    def record(**attributes)
      event = LiveUsageEvent.record!(engine: ENGINE, live_conversation: @conversation,
                                     mode: VoiceEngine.mode_for(ENGINE, setting: @setting, claude_model: model),
                                     **attributes)
      @cost += event.cost_usd.to_f
      @billed += event.billed_cost_usd
      event
    rescue ActiveRecord::ActiveRecordError => e
      # The ledger failing must not cost the person their answer.
      ErrorReporter.report_exception(e, context: { source: "LiveConversations::ClaudeDelegate", live_conversation_id: @conversation.id })
      nil
    end

    # ToolBridge's functions in the Messages API's shape, with the call-only
    # ones (hang up): a GPT-Live call is a voice call.
    def tools
      @tools ||= @bridge.realtime_tools.map do |tool|
        { name: tool[:name], description: tool[:description].to_s, input_schema: tool[:parameters].presence || { type: "object", properties: {} } }
      end
    end

    def system_prompt
      @system_prompt ||= "#{SystemPrompt.build(@conversation, setting: @setting)}\n\n" \
        "## You are answering a delegation (written by Zimmer)\n\n" \
        "This is a voice call. A separate voice model (GPT-Live) is talking with the person; it handed you their latest " \
        "request because it needs Zimmer's tools or careful thought. Do what the request needs with your functions, then " \
        "answer in two or three short spoken sentences: the voice model will say your answer aloud. No markdown, no lists, " \
        "no URLs, no ids unless the person needs one. Anything that takes more than a few seconds goes to a background " \
        "session, as above. If the person asked to hang up, call `#{ToolBridge::HANG_UP}` and say goodbye."
    end

    def request_text
      turns = @conversation.turns.reorder(id: :desc).limit(HISTORY_TURNS).to_a.reverse
      lines = turns.map { |turn| line_for(turn) }.compact
      latest = @pending.presence || turns.reverse.find(&:user?)&.content.to_s
      "The conversation so far, oldest first:\n\n#{lines.join("\n").presence || '(nothing yet)'}\n\n" \
        "The person's latest request, which the voice model delegated to you:\n\n#{latest.presence || '(not transcribed — answer from the thread)'}"
    end

    def line_for(turn)
      if turn.tool?
        "[#{turn.tool_name} → #{turn.model_output.to_s.squish.truncate(TURN_CHARS)}]"
      elsif turn.content.present?
        "#{turn.user? ? 'Them' : 'You'}: #{turn.content.to_s.squish.truncate(TURN_CHARS)}"
      end
    end

    def monotonic_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round

    # Sentences packed into chunks of at most CHUNK_CHARS; a sentence longer
    # than that is split at words, so nothing is dropped.
    def self.chunk(text)
      pieces = text.to_s.squish.split(/(?<=[.!?])\s+/).flat_map { |sentence| split_long(sentence) }
      pieces.each_with_object([]) do |sentence, chunks|
        if chunks.last && chunks.last.length + 1 + sentence.length <= CHUNK_CHARS
          chunks.last << " " << sentence
        else
          chunks << sentence.dup
        end
      end
    end

    def self.split_long(sentence)
      return [ sentence ] if sentence.length <= CHUNK_CHARS

      sentence.split(" ").each_with_object([ +"" ]) do |word, parts|
        if parts.last.empty? then parts.last << word[0, CHUNK_CHARS]
        elsif parts.last.length + 1 + word.length <= CHUNK_CHARS then parts.last << " " << word
        else parts << word[0, CHUNK_CHARS].dup
        end
      end
    end
  end
end

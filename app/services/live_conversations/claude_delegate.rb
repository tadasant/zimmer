# frozen_string_literal: true

module LiveConversations
  # Claude answering one GPT-Live delegation (the `gpt_live_claude` engine):
  # the front end decided the person's request needs Zimmer or real thought,
  # and this does it — one Claude Code run (ClaudeClient) with this
  # conversation's Live tools over MCP (LiveDelegationMcpController) — and
  # returns words for the front end to say.
  #
  # Claude runs on Zimmer's Claude Code subscription, on the model the Live
  # settings name (`voice_claude_model`), and nothing else: no Anthropic API
  # key, and no quieter model when the configured one is refused.
  #
  # A delegation carries no task text (GPT-Live hands over an id, not the
  # request), so Claude reads the request from the thread: the recent turns,
  # plus the person's line the client had not yet written as a turn.
  #
  # The run is one LiveUsageEvent (`delegation`: model, tokens across its turns,
  # cache reads and writes, latency) and every tool it calls is one
  # (`tool_call`, written by the MCP endpoint), so /live/costs can say what
  # each delegation cost. The spend cap is checked before Claude is called: a
  # capped engine answers with the cap and `end_call`, and the client ends the
  # call (VoiceEngine sends the next one to the default engine).
  #
  # A failure is logged at WARN (`[live.claude]`), recorded on the ledger with
  # whatever the run spent, and said aloud as what it was: Claude Code not
  # signed in or refused, rate limited, too slow, out of steps, or failing.
  # Never as the tools being unreachable.
  #
  # The delegation holds a Puma request thread while Claude Code runs, and the
  # run's tool calls come back to the same Puma over HTTP. So at most
  # MAX_CONCURRENT run at once per process — the threads less two, one for the
  # tool calls and one for everything else — and a delegation over that answers
  # "still working on the last one" rather than starving the tool calls it
  # would be waiting on.
  #
  # The answer is split into chunks under GPT-Live's 500-token limit on one
  # `session.commentary.append`.
  class ClaudeDelegate
    HISTORY_TURNS = 40
    TURN_CHARS = 1_500
    # ~4 characters a token keeps a chunk well under GPT-Live's 500 tokens.
    CHUNK_CHARS = 1_400
    PENDING_MAX_CHARS = 4_000
    ENGINE = VoiceEngine::GPT_LIVE
    MAX_CONCURRENT = [ ConnectionBudget.puma_threads - 2, 1 ].max
    RUNNING = { count: 0 }
    RUNNING_LOCK = Mutex.new

    # `cost_usd` is the list price of what this delegation used; `billed_usd`
    # the part of it that was billed (nothing, for Claude on a subscription;
    # all of it, for Claude on an API key).
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
      @cost = 0.0
      @billed = 0.0
    end

    def call
      check = SpendGuard.check(engine: ENGINE, conversation: @conversation, setting: @setting)
      if check.blocked?
        return result("I've hit the spend cap for this voice engine: #{check.reason}. I'm ending this call; call again and " \
                      "you'll be on the standard voice.", end_call: true, warning: check.reason, rounds: 0)
      end

      return busy_result unless claim_slot

      begin
        run_claude(check)
      ensure
        release_slot
      end
    end

    private

    def run_claude(check)
      started = monotonic_ms
      answer = client.run(prompt: request_text, system: system_prompt, model: model,
                          mcp_token: DelegationToken.mint(@conversation, delegation_id: @delegation_id))
      record_answer(answer, monotonic_ms - started)
      hung_up = hung_up?
      text = answer.text.squish
      text = "I couldn't finish that in time. Ask again, or narrow it down." if text.blank? && !hung_up
      result(text, end_call: hung_up, hung_up: hung_up, warning: check.warning, rounds: answer.num_turns)
    rescue ClaudeClient::NotConfiguredError
      raise
    rescue ClaudeClient::Error => e
      record_failure(e, monotonic_ms - started)
      # A goodbye already asked for still ends the call, whatever came after it.
      return result("Okay, hanging up.", end_call: true, hung_up: true, warning: nil, rounds: 0) if hung_up?

      result(failure_text(e), end_call: false, warning: nil, rounds: 0)
    end

    def claim_slot
      RUNNING_LOCK.synchronize do
        next false if RUNNING[:count] >= MAX_CONCURRENT

        RUNNING[:count] += 1
        true
      end
    end

    def release_slot = RUNNING_LOCK.synchronize { RUNNING[:count] -= 1 }

    def busy_result
      Rails.logger.warn("[live.claude] delegation refused: #{MAX_CONCURRENT} already running in this process " \
                        "(conversation=#{@conversation.id} delegation=#{@delegation_id})")
      # Nothing ran, so nothing was billed; metered is the honest basis for $0.
      record(operation: "delegation", vendor: "anthropic", model: model, billing_basis: "metered",
             error: "busy: #{MAX_CONCURRENT} delegations already running",
             details: { delegation_id: @delegation_id, kind: "busy", via: "claude_code" })
      result("I'm still working on the last request. Ask me again in a moment.", end_call: false, warning: nil, rounds: 0)
    end

    def result(text, end_call:, warning:, rounds:, hung_up: false)
      Result.new(text: text, chunks: self.class.chunk(text), end_call: end_call, hung_up: hung_up, warning: warning,
                 rounds: rounds, cost_usd: @cost, billed_usd: @billed)
    end

    def model = @setting.effective(:voice_claude_model)

    def client = @client ||= ClaudeClient.new

    # Priced on the model asked for, which is the price table's key: the CLI
    # can report a dated snapshot id the table does not list, and an unpriced
    # row would never count toward a cap.
    def record_answer(answer, latency_ms)
      usage = answer.usage
      record(operation: "delegation", vendor: "anthropic", model: model, billing_basis: client.billing_basis,
             input_tokens: usage["input_tokens"].to_i, output_tokens: usage["output_tokens"].to_i,
             cache_read_tokens: usage["cache_read_input_tokens"].to_i, cache_write_tokens: usage["cache_creation_input_tokens"].to_i,
             count: 1, latency_ms: latency_ms,
             details: { delegation_id: @delegation_id, turns: answer.num_turns, response_models: answer.models, via: "claude_code" })
    end

    def record_failure(error, latency_ms)
      Rails.logger.warn("[live.claude] delegation failed kind=#{error.kind} exit=#{error.status.inspect} model=#{model} " \
                        "conversation=#{@conversation.id} delegation=#{@delegation_id} message=#{error.message.squish.truncate(200).inspect}")
      usage = error.usage || {}
      record(operation: "delegation", vendor: "anthropic", model: model, billing_basis: client.billing_basis,
             error: error.message.truncate(250), latency_ms: latency_ms,
             input_tokens: usage["input_tokens"].to_i, output_tokens: usage["output_tokens"].to_i,
             cache_read_tokens: usage["cache_read_input_tokens"].to_i, cache_write_tokens: usage["cache_creation_input_tokens"].to_i,
             details: { delegation_id: @delegation_id, kind: error.kind.to_s, exit: error.status, via: "claude_code" }.compact)
    end

    # Spoken, so short and plain; the detail is on the ledger and in the log.
    def failure_text(error)
      case error.kind
      when :auth
        "Claude Code isn't signed in on Zimmer's subscription right now, so I can't do that on this voice engine. Your " \
          "tools are fine. Re-authenticate the account on the inference page, or switch back to the standard voice."
      when :rate_limited
        "Claude is rate limited or overloaded on Zimmer's subscription right now. Try again in a moment."
      when :timeout
        "Claude took too long on that one. Ask again, or narrow it down."
      when :max_turns
        "That took more steps than I can take on a call. Ask for less at once, or have me start a background session for it."
      else
        "Claude failed on that one. Try again in a moment, or switch back to the standard voice."
      end
    end

    # The person asked to hang up if Claude called `hang_up` during this run.
    # The call ran in the MCP endpoint's request, which wrote it to the ledger
    # under this delegation's id, so it is read back from there.
    def hung_up?
      LiveUsageEvent.where(live_conversation: @conversation, operation: "tool_call", model: ToolBridge::HANG_UP, error: nil)
                    .where("details->>'delegation_id' = ?", @delegation_id).exists?
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

    def system_prompt
      @system_prompt ||= "#{SystemPrompt.build(@conversation, setting: @setting)}\n\n" \
        "## You are answering a delegation (written by Zimmer)\n\n" \
        "This is a voice call. A separate voice model (GPT-Live) is talking with the person; it handed you their latest " \
        "request because it needs Zimmer's tools or careful thought. Your functions are the `#{ClaudeClient::MCP_SERVER}` " \
        "MCP server's tools. Do what the request needs with them, then answer in two or three short spoken sentences: the " \
        "voice model will say your answer aloud. No markdown, no lists, no URLs, no ids unless the person needs one. " \
        "Anything that takes more than a few seconds goes to a background session, as above. If the person asked to hang " \
        "up, call `#{ToolBridge::HANG_UP}` and say goodbye."
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

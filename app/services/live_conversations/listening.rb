# frozen_string_literal: true

module LiveConversations
  # Which spoken lines a voice call answers (LiveSetting `voice_listening`):
  #
  #   always     every line — a private space, the car. OpenAI's turn detection
  #              starts the reply itself.
  #   wake_word  a line that says "Zimmer", or a follow-up: one heard within
  #              FOLLOW_UP_SECONDS of the last line kept or spoken, so "yes" to
  #              a question, or the rest of a sentence split at a pause, counts.
  #   dynamic    the same, or a line a text model judges was said to the
  #              assistant, given the last few lines of the thread.
  #
  # A line that repeats what the assistant just said is its own voice through
  # the speaker, and is dropped in both before anything else is asked.
  #
  # In the two gated modes the Realtime session is told not to start replies or
  # cut one off on its own (RealtimeSession#turn_detection). The client records
  # each finished user transcript (Actions#record_turn), which asks #respond?;
  # the answer comes back to the client, which then either asks for the reply
  # (`response.create`) or deletes the line from the call
  # (`conversation.item.delete`). A dropped line is never written to the thread.
  #
  # Gating needs a client that does that second half, so it applies only to a
  # client that says it can (`listening_modes`); any other one is answered as
  # `always`.
  class Listening
    MODES = %w[always wake_word dynamic].freeze
    GATED = %w[wake_word dynamic].freeze
    WAKE_WORD = /\bzimmer(?:s|'s|’s)?\b/i

    # The judge is on the turn's critical path: an answer slower than this is
    # worse than a wrong one.
    JUDGE_OPEN_TIMEOUT_SECONDS = 2
    JUDGE_TIMEOUT_SECONDS = 6
    CONTEXT_TURNS = 6
    FOLLOW_UP_SECONDS = 10
    # Shorter than this, a line inside the assistant's last one is a coincidence
    # ("yes", "okay"), not an echo.
    ECHO_MIN_LENGTH = 12

    JUDGE_PROMPT = <<~PROMPT.squish
      You screen what a voice assistant named Zimmer hears through an open microphone, which also picks up
      people talking to each other, a radio or TV, and the assistant's own voice. Decide whether the LAST
      heard line was said to the assistant: a question or request for it, an answer to something it just
      asked, or a follow-up on what it just said. A line between other people, background audio, an echo of
      the assistant, or noise is not. Answer with exactly one word: yes or no.
    PROMPT

    def self.mode(setting = LiveSetting.current, capable: true)
      mode = setting.effective(:voice_listening).to_s
      capable && MODES.include?(mode) ? mode : "always"
    end

    def self.gated?(mode) = GATED.include?(mode)

    def initialize(conversation, mode:, client: nil, setting: LiveSetting.current)
      @conversation = conversation
      @mode = mode
      @client = client
      @setting = setting
    end

    # Whether the call should answer this finished user line.
    def respond?(transcript)
      text = transcript.to_s
      return true unless self.class.gated?(@mode)
      return false if echo?(text)
      return true if text.match?(WAKE_WORD) || follow_up?
      return false if @mode == "wake_word"

      judge(text)
    end

    private

    def echo?(text)
      heard = normalize(text)
      said = @conversation.turns.where(role: "assistant").reorder(id: :desc).pick(:content)
      heard.length >= ECHO_MIN_LENGTH && said.present? && normalize(said).include?(heard)
    end

    def normalize(text) = text.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").squish

    def follow_up?
      last = @conversation.turns.where(role: %w[user assistant]).reorder(id: :desc).pick(:created_at)
      last.present? && last > FOLLOW_UP_SECONDS.seconds.ago
    end

    # Fails open: a call that answers a stray line is a nuisance, one that
    # silently stops answering is the bug a person cannot see.
    def judge(text)
      response = client.chat_completion(
        model: @setting.effective(:text_model),
        reasoning_effort: "none",
        max_completion_tokens: 3,
        messages: [
          { role: "system", content: JUDGE_PROMPT },
          { role: "user", content: judge_input(text) }
        ]
      )
      answer = response.dig("choices", 0, "message", "content").to_s.strip.downcase
      !answer.start_with?("no")
    rescue OpenaiClient::Error => e
      Rails.logger.warn("[LiveConversations::Listening] could not judge a heard line, answering it: #{e.message}")
      true
    end

    def judge_input(text)
      recent = @conversation.turns.where(role: %w[user assistant]).reorder(id: :desc).limit(CONTEXT_TURNS).to_a.reverse
      lines = recent.map { |turn| "#{turn.user? ? 'Heard' : 'Zimmer'}: #{turn.content.to_s.truncate(400)}" }
      context = lines.any? ? "The thread so far:\n#{lines.join("\n")}\n\n" : ""
      "#{context}The last heard line:\nHeard: #{text.truncate(1_000)}"
    end

    def client = @client ||= OpenaiClient.new(open_timeout: JUDGE_OPEN_TIMEOUT_SECONDS, read_timeout: JUDGE_TIMEOUT_SECONDS)
  end
end

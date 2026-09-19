# Names a newly created session from a single headless inference call over the
# early conversation transcript.
#
# Why the transcript and not the prompt:
# - The transcript ("a few minutes of conversation context") is a far stronger
#   signal than the raw initial prompt. Router-dispatched sessions begin with a
#   large routing preamble; tiny prompts ("run discovery") say almost nothing;
#   junk sessions never reveal they did no real work. Titling off what the agent
#   actually did names all three correctly.
#
# Backend: HeadlessInferenceService (a runtime-neutral one-shot completion). The
# call runs against a small, cheap model — titling is high-volume and
# low-stakes, and Haiku matches the larger models here once it has transcript
# context. The model is a constant, not a setting: the operator override that
# used to move it was the categorization model (`category_inference_model`),
# because title and category shared one call, and it went with categories.
#
# Edge cases that must hold:
# - A manually-set title is never overwritten (we only title when the title is
#   still auto-generated).
# - A failed session's transcript is crash output that misleads the LLM (e.g.
#   titling an MCP-server startup crash "Interrupted by Session Limit"). For a
#   failed session with a recorded failure reason we set a deterministic title
#   from that reason, NOT from the transcript.
# - Degradation is graceful: no transcript yet, or a blank answer, falls back to
#   a deterministic title from the human's own prompt (Session#human_prompt, not
#   the composed one the runtime got).
class SessionTitleJob < ApplicationJob
  include DatabaseRetry
  # A title can block for INFERENCE_TIMEOUT seconds. A dedicated scheduler is the
  # backpressure: excess work stays queued once, instead of being claimed,
  # rejected by a perform-limit advisory lock, and re-enqueued on every retry.
  queue_as :inference

  # Don't retry if session is not found
  discard_on ActiveRecord::RecordNotFound

  # Titling is high-volume and low-stakes, so it runs on a small, cheap model.
  INFERENCE_MODEL = "haiku"

  # A single inference call may block for this long.
  INFERENCE_TIMEOUT = 30

  # Per-message truncation when formatting the transcript for the prompt.
  MAX_MESSAGE_CHARS = 500

  # Overall cap on the transcript context fed to the inference, so a long
  # session can't blow past the backend's context window.
  MAX_CONTEXT_CHARS = 8000

  # Allow injection of inference service for testing
  attr_accessor :inference_service

  def initialize(*args)
    super
    @inference_service ||= HeadlessInferenceService.new
  end

  def perform(session_id)
    session = Session.find(session_id)
    return unless title_needed?(session)

    # Failed sessions: derive a deterministic, accurate title from the recorded
    # failure reason instead of summarizing the misleading crash transcript.
    if session.failed? && (failure_title = session.failure_summary).present?
      apply_title(session, failure_title.truncate(100, omission: ""), "failure_reason")
      return
    end

    transcript = transcript_context(session)

    if transcript.present?
      # Strong signal: one inference over what the agent actually did. A blank
      # answer (a timeout, a non-zero exit, an empty reply) falls back to the
      # prompt-derived title rather than leaving the placeholder in place.
      title = infer_title(transcript)
      title_source = "transcript"
      if title.blank?
        title = generate_title_from_prompt(session.human_prompt)
        title_source = "prompt_fallback"
      end
      apply_title(session, title&.truncate(100, omission: ""), title_source)
    else
      # No transcript yet. Title the session deterministically from the prompt
      # (no inference — the raw prompt is a weak signal we don't pay an LLM call
      # for).
      fallback = generate_title_from_prompt(session.human_prompt)
      apply_title(session, fallback, "prompt_fallback") if fallback.present?
    end
  rescue StandardError => e
    Rails.logger.error "Failed to generate title for session #{session_id}: #{e.message}"
    # Don't fail the job, just log the error. The timeline write is best-effort:
    # if the session was destroyed mid-flight (so even the log write fails) we
    # swallow that too rather than letting the rescue itself re-raise.
    begin
      with_db_retry do
        session&.logs&.create!(
          content: "Failed to generate title: #{e.message}",
          level: "warning"
        )
      end
    rescue StandardError => log_error
      Rails.logger.error "Failed to record title failure for session #{session_id}: #{log_error.message}"
    end
  end

  private

  # Whether the session still needs an auto-generated title.
  # - flag present and true: run (auto-generated, needs a real title)
  # - flag present and false/nil: skip (user manually edited)
  # - no flag but title present: skip (old sessions with manual titles)
  # - no flag and no title: run (old sessions without titles — backwards compat)
  def title_needed?(session)
    if session.metadata&.key?("auto_generated_title")
      session.metadata["auto_generated_title"] == true
    else
      session.title.blank?
    end
  end

  # One inference over the transcript. Returns the title, or nil when the
  # backend answered nothing usable.
  def infer_title(context)
    raw = @inference_service.generate(
      build_prompt(context),
      timeout: INFERENCE_TIMEOUT,
      model: INFERENCE_MODEL,
      single_line: false
    )
    parse_title(raw)
  end

  def build_prompt(context)
    <<~PROMPT
      You are summarizing a coding-agent session.

      The session context:
      #{context}

      Produce the following:
      - TITLE: a concise title (max 6 words, descriptive, action verbs, no quotes or formatting).

      Respond in EXACTLY this format and nothing else:
      TITLE: <title>
    PROMPT
  end

  # Reads the labelled `TITLE:` line. Tolerates the model omitting the label:
  # only one field was asked for, so the first non-empty line is the title.
  def parse_title(raw)
    text = raw.to_s

    text.each_line do |line|
      if (m = line.match(/\A\s*title\s*:\s*(.+?)\s*\z/i))
        return m[1]
      end
    end

    text.strip.lines.map(&:strip).find(&:present?)
  end

  # The formatted early-conversation transcript, or nil when there isn't one yet.
  # This is the strong signal the inference prefers; without it the job falls
  # back to a deterministic prompt-derived title (see #perform).
  def transcript_context(session)
    return nil unless session.transcript_present?

    conversation = normalized_conversation(session)
    return nil if conversation.blank?

    format_conversation(conversation)
  end

  def format_conversation(conversation)
    conversation.map do |msg|
      role = msg[:role] == "assistant" ? "Assistant" : "User"
      content = msg[:content]
      content = content.truncate(MAX_MESSAGE_CHARS, omission: "...") if content.length > MAX_MESSAGE_CHARS
      "#{role}: #{content}"
    end.join("\n\n").truncate(MAX_CONTEXT_CHARS, omission: "...")
  end

  # --- Title persistence -------------------------------------------------------

  # Persist a generated title, clear the auto_generated_title flag, regenerate
  # the slug, and log the source. Shared by the inference path and the
  # deterministic failure-reason path.
  def apply_title(session, title, title_source)
    return if title.blank?

    with_db_retry do
      session.update!(title: title)
      # After the title lands, never before: both re-title gates key on this
      # marker, so dropping it first and then failing the write (the stale-catalog
      # RecordInvalid is the live case) would leave the session unnamed and
      # ineligible to be named again.
      session.remove_metadata!("auto_generated_title")
    end

    with_db_retry do
      session.generate_slug_from_title!
    end

    with_db_retry do
      session.logs.create!(
        content: title_generation_log_message(title_source),
        level: "info"
      )
    end
  end

  def title_generation_log_message(title_source)
    case title_source
    when "transcript"
      "Generated session title from transcript"
    when "prompt_fallback"
      "Generated session title from prompt fallback"
    when "failure_reason"
      "Set session title from failure reason"
    else
      "Generated session title"
    end
  end

  # Deterministic title from the prompt text. Callers pass `Session#human_prompt`
  # rather than `prompt`: the chat bubble wraps the human's words in a
  # `<context-about-user's-current-view>` block before handing them to the
  # runtime, and the first 60 characters of that block are the block, not the
  # ask.
  def generate_title_from_prompt(prompt_text)
    return nil if prompt_text.blank?

    title = prompt_text.strip
    first_sentence = title.split(/[.!?]/).first
    title = first_sentence if first_sentence.present? && first_sentence.length < title.length
    title = title.truncate(60, omission: "...")
    title.strip
  end

  # --- Transcript normalization ------------------------------------------------

  def normalized_conversation(session)
    normalizer = TranscriptRuntime.normalizer_for(session)

    session.parsed_transcript.each_with_index.filter_map do |raw_event, index|
      transcript_index = raw_event["_transcript_index"] || index
      normalizer.normalize(raw_event, session: session, transcript_index: transcript_index)
    end.flatten.filter_map do |event|
      next unless event[:type].in?([ OpenTranscript::Types::USER_MESSAGE, OpenTranscript::Types::ASSISTANT_MESSAGE ])
      next if OpenTranscript.blank_message?(event)

      content = text_content_from_parts(event[:content])
      next if content.blank?

      {
        role: event[:type] == OpenTranscript::Types::ASSISTANT_MESSAGE ? "assistant" : "user",
        content: content,
        timestamp: event[:ts],
        has_tool_use: false,
        has_tool_result: false
      }
    end
  end

  def text_content_from_parts(parts)
    return "" unless parts.is_a?(Array)

    parts.filter_map do |part|
      next unless part.is_a?(Hash) && part["type"] == "text"

      part["text"].presence
    end.join("\n\n")
  end
end

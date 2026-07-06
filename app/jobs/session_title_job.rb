# Names a newly created session AND auto-sorts it into one of the operator's
# categories — both from a single headless inference call over the early
# conversation transcript.
#
# Why both in one job (and one call):
# - The transcript ("a few minutes of conversation context") is a far stronger
#   signal than the raw initial prompt. Router-dispatched sessions begin with a
#   large routing preamble; tiny prompts ("run discovery") say almost nothing;
#   junk sessions never reveal they did no real work. Categorizing off the
#   prompt alone mis-sorts all three. Categorizing off what the agent actually
#   did fixes them.
# - The title and the category are two summaries of the same context, so we ask
#   for them together in one combined prompt and parse a labeled response. That
#   halves the inference calls versus titling and categorizing separately.
#
# Backend: HeadlessInferenceService (a runtime-neutral one-shot completion). The
# call runs against a small, cheap model (Haiku) — title/category inference is
# high-volume and low-stakes, and Haiku matches the larger models here once it
# has transcript context.
#
# Edge cases that must hold:
# - A manually-set title is never overwritten (we only title when the title is
#   still auto-generated); category is still inferred in that case.
# - A failed session's transcript is crash output that misleads the LLM (e.g.
#   titling an MCP-server startup crash "Interrupted by Session Limit"). For a
#   failed session with a recorded failure reason we set a deterministic title
#   from that reason and infer the category from the prompt, NOT the transcript.
# - A category the operator set manually is never clobbered (checked up front
#   and re-checked on a fresh read immediately before writing).
# - Frozen categories are never auto-assignment targets (a frozen category is a
#   parked "leave it alone" bucket excluded from refresh/recovery).
# - Degradation is graceful: missing transcript falls back to the prompt; a
#   blank/NONE/unmatched category answer leaves the session Uncategorized with
#   an info-level timeline note and Rails log explaining why.
class SessionTitleJob < ApplicationJob
  include DatabaseRetry
  queue_as :default

  # Don't retry if session is not found
  discard_on ActiveRecord::RecordNotFound

  # Timeout for the headless inference call, in seconds.
  INFERENCE_TIMEOUT = 30

  # Title/category inference is high-volume and low-stakes; run it on a small,
  # cheap model. Haiku matches the larger models on this task once it has
  # transcript context (matches ModelCatalog's "haiku" id for claude_code).
  INFERENCE_MODEL = "haiku"

  # Per-message truncation when formatting the transcript for the prompt.
  MAX_MESSAGE_CHARS = 500

  # Overall cap on the transcript context fed to the inference, so a long
  # session can't blow past the backend's context window.
  MAX_CONTEXT_CHARS = 8000

  # Cap on the raw prompt text used as fallback context (no transcript) or as
  # the category signal for failed sessions.
  MAX_PROMPT_CHARS = 1500

  # Allow injection of inference service for testing
  attr_accessor :inference_service

  def initialize(*args)
    super
    @inference_service ||= HeadlessInferenceService.new
  end

  def perform(session_id)
    session = Session.find(session_id)

    want_title = title_needed?(session)
    want_category = category_needed?(session)
    return unless want_title || want_category

    # Failed sessions: derive a deterministic, accurate title from the recorded
    # failure reason instead of summarizing the misleading crash transcript, and
    # infer the category from the prompt (also avoiding the crash transcript).
    if session.failed? && (failure_title = session.failure_summary).present?
      apply_title(session, failure_title.truncate(100, omission: ""), "failure_reason") if want_title
      infer_from_context(session, want_title: false, context: prompt_context(session), context_source: "prompt") if want_category
      return
    end

    transcript = transcript_context(session)

    if transcript.present?
      # Strong signal: one combined inference over what the agent actually did
      # yields both the title and the category.
      infer_from_context(session, want_title: want_title, context: transcript, context_source: "transcript")
    else
      # No transcript yet. Title the session deterministically from the prompt
      # (no inference — the raw prompt is a weak signal we don't pay an LLM call
      # for), and infer the category from the prompt only when candidates exist.
      if want_title
        fallback = generate_title_from_prompt(session.prompt)
        apply_title(session, fallback, "prompt_fallback") if fallback.present?
      end
      infer_from_context(session, want_title: false, context: prompt_context(session), context_source: "prompt") if want_category
    end
  rescue StandardError => e
    Rails.logger.error "Failed to generate title/category for session #{session_id}: #{e.message}"
    # Don't fail the job, just log the error. The timeline write is best-effort:
    # if the session was destroyed mid-flight (so even the log write fails) we
    # swallow that too rather than letting the rescue itself re-raise.
    begin
      with_db_retry do
        session&.logs&.create!(
          content: "Failed to generate title/category: #{e.message}",
          level: "warning"
        )
      end
    rescue StandardError => log_error
      Rails.logger.error "Failed to record title/category failure for session #{session_id}: #{log_error.message}"
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

  # Whether the session still needs a category. Candidate availability (and the
  # frozen-only edge case) is re-checked at generation time.
  def category_needed?(session)
    session.category_id.blank? && session.prompt.present?
  end

  # Runs the combined inference over the given context and applies whatever was
  # requested. Category is attempted only when there are candidate categories.
  def infer_from_context(session, want_title:, context:, context_source:)
    return if context.blank?

    candidates = want_category_after_load?(session) ? category_candidates : []
    return unless want_title || candidates.any?

    raw = @inference_service.generate(
      combined_prompt(context, want_title: want_title, candidates: candidates),
      timeout: INFERENCE_TIMEOUT,
      model: INFERENCE_MODEL,
      single_line: false
    )

    title, choice = parse_response(raw, want_title: want_title, want_category: candidates.any?)

    if want_title
      title = title.presence
      title_source = context_source == "transcript" ? "transcript" : "prompt_fallback"
      if title.blank?
        title = generate_title_from_prompt(session.prompt)
        title_source = "prompt_fallback"
      end
      apply_title(session, title&.truncate(100, omission: ""), title_source)
    end

    if candidates.any?
      category = match_category(choice, candidates)
      category ? assign_category(session, category) : record_uncategorized(session, choice)
    end
  end

  # category_needed? is checked at enqueue and again here against the freshest
  # state; this guards the actual write path against a category set in between.
  def want_category_after_load?(session)
    session.category_id.blank? && session.prompt.present?
  end

  def category_candidates
    Category.ordered.where(is_frozen: false).to_a
  end

  # The formatted early-conversation transcript, or nil when there isn't one yet.
  # This is the strong signal the combined inference prefers; without it the job
  # falls back to a deterministic prompt-derived title (see #perform).
  def transcript_context(session)
    return nil if session.transcript.blank?

    conversation = normalized_conversation(session)
    return nil if conversation.blank?

    format_conversation(conversation)
  end

  def prompt_context(session)
    session.prompt.to_s.truncate(MAX_PROMPT_CHARS)
  end

  def format_conversation(conversation)
    conversation.map do |msg|
      role = msg[:role] == "assistant" ? "Assistant" : "User"
      content = msg[:content]
      content = content.truncate(MAX_MESSAGE_CHARS, omission: "...") if content.length > MAX_MESSAGE_CHARS
      "#{role}: #{content}"
    end.join("\n\n").truncate(MAX_CONTEXT_CHARS, omission: "...")
  end

  # Builds the combined prompt requesting only the fields needed. The response
  # is a labeled, multi-line format the caller parses (single_line: false).
  def combined_prompt(context, want_title:, candidates:)
    want_category = candidates.any?

    tasks = []
    tasks << "- TITLE: a concise title (max 6 words, descriptive, action verbs, no quotes or formatting)." if want_title
    if want_category
      category_lines = candidates.map do |category|
        description = category.description.presence
        description ? "- #{category.name}: #{description}" : "- #{category.name}"
      end.join("\n")
      tasks << <<~CATEGORY.strip
        - CATEGORY: the single best-fitting category from this list, or NONE. Do your best to place the session in a category — match on the meaning conveyed by each name AND its description (a name may be a short abbreviation, e.g. "AO"), not just literal keyword overlap. But only commit to a category when you are reasonably confident it fits. If no category clearly fits, or your confidence is low, answer NONE so the session is left Uncategorized rather than mis-sorted. When in doubt, prefer NONE.

        Available categories (formatted "name: description"):
        #{category_lines}
      CATEGORY
    end

    response_lines = []
    response_lines << "TITLE: <title>" if want_title
    response_lines << "CATEGORY: <exact category name or NONE>" if want_category

    <<~PROMPT
      You are summarizing a coding-agent session.

      The session context:
      #{context}

      Produce the following:
      #{tasks.join("\n\n")}

      Respond in EXACTLY this format and nothing else:
      #{response_lines.join("\n")}
    PROMPT
  end

  # Parses the labeled response. Tolerates the model omitting a label when only
  # one field was requested (then the whole answer is that field's value).
  def parse_response(raw, want_title:, want_category:)
    text = raw.to_s
    title = nil
    choice = nil

    text.each_line do |line|
      if (m = line.match(/\A\s*title\s*:\s*(.+?)\s*\z/i))
        title ||= m[1]
      elsif (m = line.match(/\A\s*category\s*:\s*(.+?)\s*\z/i))
        choice ||= m[1]
      end
    end

    # If the model ignored the label and only one field was requested, treat the
    # first non-empty line as that field's value.
    if want_title ^ want_category
      first = text.strip.lines.map(&:strip).find(&:present?)
      title ||= first if want_title
      choice ||= first if want_category
    end

    [ title, choice ]
  end

  # --- Title persistence -------------------------------------------------------

  # Persist a generated title, clear the auto_generated_title flag, regenerate
  # the slug, and log the source. Shared by the inference path and the
  # deterministic failure-reason path.
  def apply_title(session, title, title_source)
    return if title.blank?

    updated_metadata = (session.metadata || {}).except("auto_generated_title")
    with_db_retry do
      session.update!(title: title, metadata: updated_metadata)
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

  def generate_title_from_prompt(prompt_text)
    return nil if prompt_text.blank?

    title = prompt_text.strip
    first_sentence = title.split(/[.!?]/).first
    title = first_sentence if first_sentence.present? && first_sentence.length < title.length
    title = title.truncate(60, omission: "...")
    title.strip
  end

  # --- Category persistence ----------------------------------------------------

  def assign_category(session, category)
    with_db_retry do
      # Re-read inside the retry block so a category the operator assigned
      # manually while inference was running is never clobbered.
      session.reload
      return if session.category_id.present?

      session.update!(category_id: category.id)
    end

    with_db_retry do
      session.logs.create!(
        content: "Auto-assigned to category \"#{category.name}\"",
        level: "info"
      )
    end
  end

  # Records why a session was left Uncategorized so the outcome is inspectable
  # from the session timeline (and greppable in the Rails log). Distinguishes a
  # missing answer, an explicit NONE, and an answer that matched no candidate.
  # Per the logging philosophy these are expected, self-resolving outcomes, so
  # they log at INFO — not warn/error.
  def record_uncategorized(session, choice)
    content, rails_message =
      if choice.blank?
        [ "Left uncategorized (inference returned no answer)",
          "left session #{session.id} uncategorized: inference returned no answer" ]
      elsif normalize_answer(choice) == "none"
        [ "Left uncategorized (inference returned NONE — no category fit)",
          "left session #{session.id} uncategorized: inference returned NONE" ]
      else
        [ "Left uncategorized (inference answer #{choice.inspect} matched no category)",
          "left session #{session.id} uncategorized: inference answer #{choice.inspect} matched no category" ]
      end

    Rails.logger.info "Auto-categorize #{rails_message}"

    with_db_retry do
      session.logs.create!(content: content, level: "info")
    end
  end

  # Resolves the inference's answer to one of the candidate categories without
  # ever coercing a malformed answer into the WRONG category:
  # 1. Exact (case-insensitive, punctuation-trimmed) match against a name.
  # 2. Failing that, if the answer wraps exactly one category name as a whole
  #    token (e.g. "The category is AO." or "**Bugs**"), match it. When the
  #    answer mentions several candidate names it's ambiguous, so we decline.
  # Anything else (including "NONE") leaves the session Uncategorized.
  def match_category(choice, candidates)
    return nil if choice.blank?

    normalized = normalize_answer(choice)
    return nil if normalized == "none"

    exact = candidates.find { |category| category.name.strip.downcase == normalized }
    return exact if exact

    token_matches = candidates.select { |category| answer_mentions_name?(normalized, category.name) }
    token_matches.first if token_matches.size == 1
  end

  # Lower-cases, strips whitespace, and trims surrounding non-alphanumeric
  # characters (quotes, markdown asterisks, list dashes, trailing periods).
  def normalize_answer(choice)
    choice.strip.downcase.gsub(/\A[^[:alnum:]]+|[^[:alnum:]]+\z/, "")
  end

  # True when the category name appears as a whole token within the answer,
  # using alphanumeric word boundaries so "ao" matches in "the category is ao"
  # but not inside "chaos".
  def answer_mentions_name?(answer, name)
    needle = name.strip.downcase
    return false if needle.blank?

    answer.match?(/(?<![[:alnum:]])#{Regexp.escape(needle)}(?![[:alnum:]])/)
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

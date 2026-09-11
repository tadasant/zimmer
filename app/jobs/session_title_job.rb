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
# Backend: HeadlessInferenceService (a runtime-neutral one-shot completion),
# reached through CategorizationService — which owns the prompt, the model
# choice, the response parsing and the answer matching. This job owns the
# session: which context to feed the categorizer, and what to write when the
# answer comes back. That split is what lets a context be SCORED without being
# APPLIED, which is what replay needs (tadasant/zimmer#16).
#
# The call runs against a small, cheap model (Haiku by default) — title/category
# inference is high-volume and low-stakes, and Haiku matches the larger models
# here once it has transcript context. The operator can override the model and
# add category guidance from the settings page without a deploy.
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
# - Degradation is graceful: missing transcript falls back to the human's own
#   prompt (Session#human_prompt, not the composed one the runtime got); a
#   blank/NONE/unmatched category answer leaves the session Uncategorized with
#   an info-level timeline note and Rails log explaining why.
# - EVERY category outcome is recorded to CategoryFeedbackEvent, the assign and
#   the decline alike, together with the exact context string the model saw. A
#   decline is a different failure from a mis-sort — a pile of them means the
#   categories under-cover the work — and both are only legible if they are
#   written down before a human can overwrite them.
class SessionTitleJob < ApplicationJob
  include DatabaseRetry
  # A title can block for CategorizationService::INFERENCE_TIMEOUT seconds. A
  # dedicated scheduler is the backpressure: excess work stays queued once,
  # instead of being claimed, rejected by a perform-limit advisory lock, and
  # re-enqueued on every retry.
  queue_as :inference

  # Don't retry if session is not found
  discard_on ActiveRecord::RecordNotFound

  # Per-message truncation when formatting the transcript for the prompt.
  MAX_MESSAGE_CHARS = 500

  # Overall cap on the transcript context fed to the inference, so a long
  # session can't blow past the backend's context window.
  MAX_CONTEXT_CHARS = 8000

  # Cap on the prompt text used as fallback context (no transcript) or as the
  # category signal for failed sessions. It is applied to Session#human_prompt,
  # not to the composed prompt — see #prompt_context.
  MAX_PROMPT_CHARS = 1500

  # Allow injection of inference service for testing. The categorizer is built
  # around whatever is set here, so a test that swaps the backend swaps it for
  # both halves of the combined call.
  attr_accessor :inference_service

  def initialize(*args)
    super
    @inference_service ||= HeadlessInferenceService.new
  end

  # The categorizer this job drives. One per job run, so the settings it reads
  # (model, guidance) are read once and the whole run agrees with itself.
  def categorizer
    @categorizer ||= CategorizationService.new(inference_service: @inference_service)
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
        fallback = generate_title_from_prompt(session.human_prompt)
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

    candidates = want_category_after_load?(session) ? CategorizationService.candidates : []
    return unless want_title || candidates.any?

    result = categorizer.infer(context: context, want_title: want_title, candidates: candidates)

    if want_title
      title = result.title.presence
      title_source = context_source == "transcript" ? "transcript" : "prompt_fallback"
      if title.blank?
        title = generate_title_from_prompt(session.human_prompt)
        title_source = "prompt_fallback"
      end
      apply_title(session, title&.truncate(100, omission: ""), title_source)
    end

    return if candidates.none?

    # Written BEFORE the session write, so the model's answer and the context it
    # came from exist even if the assignment below is skipped (a manual category
    # landed mid-flight) or a human overwrites it a second later.
    record_feedback_event(
      session,
      category: result.category,
      raw_answer: result.raw,
      context: context,
      context_source: context_source,
      title_requested: want_title,
      candidates: candidates
    )

    result.category ? assign_category(session, result.category) : record_uncategorized(session, result.choice)
  end

  # The corpus write. Best-effort inside CategoryFeedbackEvent itself, so a
  # failure here can never cost the operator the title or the category.
  def record_feedback_event(session, category:, raw_answer:, context:, context_source:, title_requested:, candidates:)
    CategoryFeedbackEvent.record_inference_outcome!(
      session: session,
      category: category,
      raw_answer: raw_answer,
      context: context,
      context_source: context_source,
      title_requested: title_requested,
      model: categorizer.model,
      prompt_version: CategorizationService::PROMPT_VERSION,
      candidates: candidates
    )
  end

  # category_needed? is checked at enqueue and again here against the freshest
  # state; this guards the actual write path against a category set in between.
  def want_category_after_load?(session)
    session.category_id.blank? && session.prompt.present?
  end

  # The formatted early-conversation transcript, or nil when there isn't one yet.
  # This is the strong signal the combined inference prefers; without it the job
  # falls back to a deterministic prompt-derived title (see #perform).
  def transcript_context(session)
    return nil unless session.transcript_present?

    conversation = normalized_conversation(session)
    return nil if conversation.blank?

    format_conversation(conversation)
  end

  # The category signal when there is no usable transcript. Same string the
  # title comes from: a chat bubble's page-context block can be 50,000
  # characters, so truncating the composed prompt to MAX_PROMPT_CHARS hands the
  # model a page dump with the human's actual ask cut off the end.
  def prompt_context(session)
    session.human_prompt.to_s.truncate(MAX_PROMPT_CHARS)
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

  # --- Category persistence ----------------------------------------------------

  def assign_category(session, category)
    with_db_retry do
      # Re-read inside the retry block so a category the operator assigned
      # manually while inference was running is never clobbered.
      session.reload
      return if session.category_id.present?

      # Names this write as the categorizer's own, so Session's category-change
      # hook records the auto path's timeline note (below) rather than filing it
      # as a human correction of itself.
      session.category_change_source = SessionCategorization::CATEGORY_CHANGE_BY_INFERENCE
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
      elsif categorizer.normalize_answer(choice) == "none"
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

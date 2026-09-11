# frozen_string_literal: true

# The categorizer itself, extracted from SessionTitleJob so a context can be
# SCORED without writing to any session (tadasant/zimmer#16).
#
# Before this class the inference, the prompt and the answer-matching lived
# inside the job, entangled with the persistence that job does. That made
# categorization a hard no-op on any already-categorized session — there was no
# way to ask "what would the current config say about this context?" without
# also making it true. Replay and dry-run need exactly that question, so this
# class answers it and writes nothing.
#
# What is here:
#   * the prompt (title and category are ONE inference, so the prompt builder
#     is here too — see #build_prompt for why the title half travels with it),
#   * the labelled-response parser,
#   * the answer-to-category matcher, which never coerces a malformed answer
#     into the wrong bucket,
#   * the two operator-tunable knobs: the guidance preamble and the model.
#
# What is NOT here: transcripts, titles-on-disk, session writes, timeline notes.
# SessionTitleJob still owns all of that.
#
# THE GUIDANCE PREAMBLE IS DELIBERATELY NOT THE WHOLE PROMPT
# ----------------------------------------------------------
# `AppSetting#category_guidance` is appended to the fixed CATEGORY task, inside
# the category half of the prompt. It cannot replace the task, cannot reach the
# TITLE task, cannot change the response format, and cannot remove the
# "when in doubt, prefer NONE" instruction. Title and category share one
# inference call, so an operator-editable prompt would put titling — which has
# nothing to do with categorization and no feedback loop of its own — inside the
# blast radius of a bad edit. A preamble that can only ADD guidance keeps the
# knob useful and the failure mode local.
class CategorizationService
  # Bumped whenever the fixed part of the prompt changes in a way that makes an
  # older row's answer incomparable with a new one. Recorded on every
  # CategoryFeedbackEvent, so a corpus that spans a prompt change says so
  # instead of quietly mixing two populations.
  PROMPT_VERSION = "2026-09-11"

  # Title/category inference is high-volume and low-stakes, so it runs on a
  # small, cheap model. Haiku matches the larger models on this task once it has
  # transcript context. This is the fallback: AppSetting#category_inference_model
  # overrides it without a deploy.
  DEFAULT_MODEL = "haiku"

  # A single inference call may block for this long.
  INFERENCE_TIMEOUT = 30

  # The answer to "what does the current config say about this context", with
  # everything a caller needs to record or render it. `category` is nil whenever
  # the categorizer declined — which is not the same as it failing, so `raw` is
  # carried through for both.
  Result = Struct.new(:title, :choice, :category, :raw, keyword_init: true) do
    # Nil only when the backend returned nothing at all (timeout, non-zero exit).
    def answered?
      !raw.nil?
    end
  end

  attr_reader :inference_service

  def initialize(inference_service: nil, setting: nil)
    @inference_service = inference_service || HeadlessInferenceService.new
    @setting = setting
  end

  # The categories auto-assignment may target. Frozen categories are a parked
  # "leave it alone" bucket and are never candidates.
  def self.candidates
    Category.ordered.where(is_frozen: false).to_a
  end

  def settings
    @setting ||= AppSetting.current(context: "CategorizationService")
  end

  # The model the categorizer runs on: the operator's override when it is set
  # and still valid for the runtime that backs HeadlessInferenceService,
  # otherwise the shipped default.
  def model
    settings.category_inference_model.presence || DEFAULT_MODEL
  end

  # The operator's extra guidance, or nil. Capped by AppSetting's validation, not
  # here.
  def guidance
    settings.category_guidance.presence
  end

  # Run the inference and return a Result. WRITES NOTHING — this is the seam
  # replay and dry-run are built on, and the reason a dry-run in Zimmer is
  # actually dry.
  def infer(context:, want_title: false, candidates: self.class.candidates)
    return Result.new(raw: nil) if context.blank?
    return Result.new(raw: nil) unless want_title || candidates.any?

    raw = @inference_service.generate(
      build_prompt(context, want_title: want_title, candidates: candidates),
      timeout: INFERENCE_TIMEOUT,
      model: model,
      single_line: false
    )

    title, choice = parse_response(raw, want_title: want_title, want_category: candidates.any?)

    Result.new(
      title: title,
      choice: choice,
      category: candidates.any? ? match(choice, candidates) : nil,
      raw: raw
    )
  end

  # Builds the combined prompt requesting only the fields needed. The response is
  # a labelled, multi-line format #parse_response reads back.
  #
  # The title half lives here because it shares the call: one context, one
  # inference, two summaries. Replay rebuilds the prompt with the SAME
  # `want_title` the live call used (recorded on the feedback event), so a
  # replayed score is comparable with the answer it is scoring.
  def build_prompt(context, want_title:, candidates:)
    want_category = candidates.any?

    tasks = []
    tasks << "- TITLE: a concise title (max 6 words, descriptive, action verbs, no quotes or formatting)." if want_title
    tasks << category_task(candidates) if want_category

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

  # The CATEGORY half: the fixed task, the operator's guidance (when set), then
  # the candidate list. The guidance sits BETWEEN the task and the list on
  # purpose — it is read as extra instruction about how to choose, never as a
  # replacement for the instruction to prefer NONE.
  def category_task(candidates)
    category_lines = candidates.map do |category|
      description = category.description.presence
      description ? "- #{category.name}: #{description}" : "- #{category.name}"
    end.join("\n")

    parts = [ <<~TASK.strip ]
      - CATEGORY: the single best-fitting category from this list, or NONE. Do your best to place the session in a category — match on the meaning conveyed by each name AND its description (a name may be a short abbreviation, e.g. "Zimmer"), not just literal keyword overlap. But only commit to a category when you are reasonably confident it fits. If no category clearly fits, or your confidence is low, answer NONE so the session is left Uncategorized rather than mis-sorted. When in doubt, prefer NONE.
    TASK

    if (extra = guidance)
      parts << "Additional guidance from the operator:\n#{extra}"
    end

    parts << "Available categories (formatted \"name: description\"):\n#{category_lines}"
    parts.join("\n\n")
  end

  # Parses the labelled response. Tolerates the model omitting a label when only
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

  # Resolves the inference's answer to one of the candidate categories without
  # ever coercing a malformed answer into the WRONG category:
  # 1. Exact (case-insensitive, punctuation-trimmed) match against a name.
  # 2. Failing that, if the answer wraps exactly one category name as a whole
  #    token (e.g. "The category is Zimmer." or "**Bugs**"), match it. When the
  #    answer mentions several candidate names it's ambiguous, so we decline.
  # Anything else (including "NONE") leaves the session Uncategorized.
  def match(choice, candidates)
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
end

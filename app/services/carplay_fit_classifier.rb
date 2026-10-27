# frozen_string_literal: true

# Derives a session's CarPlay fit from the status summary it already has, with
# one short pool-independent completion.
#
# The ordinary path writes the mark for free: the status-summary fork answers
# the CarPlay-fit question in the same turn as the blurb
# (SessionStatusSummaryGenerator::CARPLAY_FIT_TRAILER_RULE). This is the path
# for a session whose blurb was written BEFORE that rule existed — the whole
# board, on the first deploy — where the blurb's first sentence already states
# what the human must do and a small model can read it. It is deliberately not
# a second summary: the stored blurb is left exactly as it is, and only the
# five mark columns change.
#
# Runs on the same substrate as a session title (`claude -p` on Haiku through
# HeadlessInferenceService), which shares the current account's quota and so
# can answer "Not logged in" when the pool is exhausted — in which case no mark
# is written and the session stays untagged until it next comes to rest.
class CarplayFitClassifier
  TIMEOUT = 60
  MODEL = SessionStatusSummaryGenerator::HEADLESS_MODEL

  Result = Struct.new(:outcome, :message, keyword_init: true) do
    def applied? = outcome == :applied
  end

  def self.call(session, inference_service: HeadlessInferenceService.new)
    new(session, inference_service: inference_service).call
  end

  def initialize(session, inference_service:)
    @session = session
    @inference_service = inference_service
  end

  attr_reader :session

  def call
    summary = session.status_summary
    return Result.new(outcome: :skipped, message: "No status summary to classify.") if summary.nil? || summary.summary.blank?

    answer = @inference_service.generate(prompt(summary.summary), timeout: TIMEOUT, model: MODEL, single_line: false)
    mark = StatusSummaryAnswer.carplay_fit(answer)
    return Result.new(outcome: :failed, message: "The classifier produced no carplay-fit line.") if mark.nil?

    # Stamped at the line count the blurb carries, so the mark and the blurb it
    # was read from go stale together.
    written = Sessions::SetCarplayFit.call(
      session: session,
      fit: mark[:fit],
      reason: mark[:reason],
      source: SessionCarplayFit::SOURCE_AUTO,
      line_count: summary.transcript_line_count
    )
    return Result.new(outcome: :kept, message: written.message) unless written.applied?

    Result.new(outcome: :applied, message: written.message)
  end

  private

  def prompt(blurb)
    <<~PROMPT
      Below is the Status panel of Zimmer session ##{session.id}#{session.title.present? ? " (\"#{session.title.to_s.truncate(120)}\")" : ''}.
      Its first sentence says what the human reading it should do next. Decide
      whether that can be done BY VOICE, FROM A CAR, and answer with exactly one
      line in this shape and nothing else:

      carplay-fit: <carplay_ok|laptop_only>; reason: <#{SessionCarplayFit::REASONS.join('|')}>

      carplay_ok when the action is a yes or no, a merge decision the sentence
      already frames, a short reply, or nothing at all (reason decision,
      short_answer or nothing_needed). laptop_only when it needs a screen or a
      keyboard: a credential to paste or mint (credential), a console or
      checklist to click through (manual_steps), something to run on their own
      machine or phone (local_device), or a long document or diff to read
      (long_read).

      Status panel:
      #{blurb}
    PROMPT
  end
end

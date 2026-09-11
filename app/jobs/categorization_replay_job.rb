# frozen_string_literal: true

# Re-scores the corrected-session corpus against the CURRENT categorization
# config, and writes the verdict onto each correction row (tadasant/zimmer#16).
#
# This is the tight loop the issue is about: edit a category description or the
# guidance preamble, replay, read the score, keep or revert — in seconds, with no
# PR and no deploy. Before it existed every tuning knob was unfalsifiable,
# because `SessionTitleJob` is a hard no-op on an already-categorized session and
# nothing else could ask the categorizer a question.
#
# TWO PROPERTIES MAKE THIS A REAL DRY RUN
# ---------------------------------------
#   * It writes no session. Not the category, not the title, not a timeline note.
#     The only rows it touches are the `replay_*` columns of the corrections it
#     scored. A dry run that mutates the thing it is predicting is not a dry run.
#   * It is hermetic. It scores `context_snapshot` — the exact string the model
#     saw at the time — so it neither re-reads a transcript TranscriptArchiveJob
#     may have archived nor needs the session to still exist.
#
# It runs on the `inference` queue, which is the two-thread lane SessionTitleJob
# and SessionStatusSummaryJob already share. MAX_LIMIT is what keeps one replay
# from parking that lane: 50 corrections at the 30s inference ceiling is the
# worst case, and the default of 10 is the one an operator tuning a description
# actually presses.
class CategorizationReplayJob < ApplicationJob
  queue_as :inference

  # At most one replay queued or running. Each is up to MAX_LIMIT serial
  # inference calls on a two-thread lane that titling and needs-input pushes
  # share, so two at once could hold both threads for the better part of half an
  # hour. A second press is refused at enqueue, and #enqueue says so.
  good_job_control_concurrency_with(
    key: -> { "categorization_replay" },
    total_limit: 1
  )

  DEFAULT_LIMIT = 10
  MAX_LIMIT = 50

  # Enqueue a replay. Returns false when one is already queued or running, so the
  # page and the MCP tool can say so rather than claim a replay they did not
  # start.
  def self.enqueue(limit)
    job = perform_later(limit)
    job.respond_to?(:successfully_enqueued?) ? job.successfully_enqueued? : job != false
  end

  def perform(limit = DEFAULT_LIMIT, inference_service: nil)
    events = CategoryFeedbackEvent.eval_corpus(limit: self.class.clamp_limit(limit))
    return if events.empty?

    service = CategorizationService.new(inference_service: inference_service)
    # One candidate list for the whole batch: this is a snapshot of the config as
    # it stands right now, and a category created mid-batch would otherwise make
    # the first half and the second half incomparable.
    candidates = CategorizationService.candidates

    events.each do |event|
      replay(service, candidates, event)
    rescue StandardError => e
      # One unscorable row must not abandon the rest of the batch — the score is
      # over whatever was scored, and `replayed_at` is what says which.
      Rails.logger.warn "[CategorizationReplay] event #{event.id} could not be replayed: #{e.class}: #{e.message}"
    end
  end

  def self.clamp_limit(limit)
    Integer(limit.to_s, exception: false)&.clamp(1, MAX_LIMIT) || DEFAULT_LIMIT
  end

  private

  def replay(service, candidates, event)
    return if event.context_snapshot.blank?
    # A correction into a since-deleted or since-frozen category cannot be
    # scored, so asking the model about it would spend a call on nothing.
    return unless event.scorable?

    result = service.infer(
      context: event.context_snapshot,
      # The same shape of call the live answer came from. The title task shares
      # the inference, so replaying a title-less prompt against an answer that
      # had one would be scoring a different question.
      want_title: event.title_requested,
      candidates: candidates
    )
    # A backend that did not answer at all (timeout, non-zero exit) is not a
    # wrong answer, and recording it as one would make the score a measure of
    # inference availability. Leave the row's previous verdict alone.
    return unless result.answered?

    event.update!(
      replayed_at: Time.current,
      replay_category_id: result.category&.id,
      replay_category_name: result.category&.name,
      replay_raw_answer: result.raw,
      replay_model: service.model,
      replay_prompt_version: CategorizationService::PROMPT_VERSION
    )
  end
end

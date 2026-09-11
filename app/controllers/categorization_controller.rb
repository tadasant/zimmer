# frozen_string_literal: true

# The categorization tuning screen: the two operator knobs, the correction
# corpus, and the replay that scores the knobs against it (tadasant/zimmer#16).
#
# Why its own page rather than a block on /settings: the useful thing here is the
# TABLE — what the categorizer answered, what the human said instead, and what
# the current config says now — and a list of corrections does not fit beside a
# runtime dropdown. /settings links here.
#
# Why a controller rather than a rake task: an operator tuning categorization on
# the Tadasant deployment has no shell on the box, so a tuning loop that needed
# one would be a tuning loop nobody could run. See the "no production box
# access" section of AGENTS.md.
class CategorizationController < ApplicationController
  # How many corrections the page shows. The replay batch is bounded separately
  # by CategorizationReplayJob::MAX_LIMIT.
  CORPUS_PAGE_SIZE = 25

  def show
    load_page
  end

  # Persist the two knobs. Deliberately NOT the whole prompt: guidance is
  # APPENDED to the fixed CATEGORY task, so a bad edit cannot reach the TITLE
  # task that shares the same inference call, cannot change the response format,
  # and cannot delete the "when in doubt, prefer NONE" instruction. See
  # CategorizationService#category_task.
  def update
    setting = AppSetting.editable
    submitted = params[:app_setting] || {}

    setting.category_guidance = submitted[:category_guidance].to_s.strip.presence
    setting.category_inference_model = submitted[:category_inference_model].to_s.strip.presence

    if setting.save
      redirect_to categorization_path, notice: "Categorization settings updated."
    else
      redirect_to categorization_path, alert: "Not saved: #{setting.errors.full_messages.join(", ")}"
    end
  end

  # Enqueue a replay of the last N corrections against the current config.
  #
  # Enqueued rather than run inline: each correction is a real inference call
  # with a 30-second ceiling, and a default batch of ten would hold the request
  # open for longer than any proxy in front of it will wait. The page reads the
  # verdicts off the rows once the job has written them.
  def replay
    limit = CategorizationReplayJob.clamp_limit(params[:limit].presence || CategorizationReplayJob::DEFAULT_LIMIT)
    corpus_size = CategoryFeedbackEvent.eval_corpus(limit: limit).pluck(:id).size

    if corpus_size.zero?
      redirect_to categorization_path,
        alert: "Nothing to replay yet — no corrections have been recorded. Move a mis-sorted session to the right category and it will appear here."
      return
    end

    unless CategorizationReplayJob.enqueue(limit)
      redirect_to categorization_path,
        notice: "A replay is already queued or running. Reload in a moment to see its scores."
      return
    end

    redirect_to categorization_path,
      notice: "Replaying #{corpus_size} #{'correction'.pluralize(corpus_size)} against the current config. Reload in a moment to see the scores."
  end

  private

  def load_page
    @setting = AppSetting.current(context: "CategorizationController#show")
    @resolved_model = CategorizationService.new(setting: @setting).model
    @model_options = ModelCatalog.model_ids_for(RuntimeRegistry::DEFAULT_RUNTIME)
    @candidates = CategorizationService.candidates
    @corrections = CategoryFeedbackEvent.eval_corpus(limit: CORPUS_PAGE_SIZE).without_bodies.to_a
    @scorecard = CategoryFeedbackEvent.scorecard(@corrections)
    @decline_rate = CategoryFeedbackEvent.decline_rate
    @replay_limit = CategorizationReplayJob::DEFAULT_LIMIT
  end
end

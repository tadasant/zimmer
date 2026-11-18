# frozen_string_literal: true

# Re-judges every session marked `laptop_only` only because of a long read.
#
# A long document or a long diff is reviewed by talking it through with Live
# Mode by voice, so from this deploy on `long_read` is a `carplay_ok` reason and
# `laptop_only` + `long_read` can no longer be written
# (SessionCarplayFit.normalize_mark). The marks already stored under that pairing
# were the old rule's answer, and every one of them keeps a session out of the
# driver's `not_laptop_only` view until the session next comes to rest — which,
# for a session waiting on its reader, can be days.
#
# No second inference is needed to re-judge them: the stored reason already
# says the only thing standing between the session and the car was the read, and
# under the new rule that is `carplay_ok` + `long_read`. So the flip changes the
# fit alone and keeps the reason, `carplay_fit_set_at` and
# `carplay_fit_line_count`: a mark that was current stays current, a stale one
# stays stale, and the next rest re-judges each the ordinary way. Whatever the
# source (`auto`, `assistant`, `session`, `human`); a laptop-only mark with any
# other reason is left exactly as it was.
#
# Two rows get what the live write path would give them
# (Sessions::SetCarplayFit, StatusSummaryAnswer.carplay_fit):
#
# - an `auto` mark on a CarPlay-engaged session becomes the sticky `carplay`
#   mark, as the summary fork's `carplay_ok` for that session does;
# - a `human`, `assistant` or `session` mark gets one line on the session's
#   timeline saying it was flipped and why, so a person's explicit "Laptop only
#   (a long read)" does not change without a trace. `auto` marks are not logged,
#   as the live path does not log them.
#
# It ships with the deploy because AGENTS.md ("ops actions ship with the deploy")
# leaves no other route: nobody has a shell on the production box.
#
# IDEMPOTENT. It only matches `laptop_only` + `long_read`, which it leaves none
# of, so a second run flips nothing. Its answer is in `post_deploy_task_runs`
# (on /health, in `GET /api/v1/health`, from `get_system_health` and at
# /supervisor/post_deploy_task_runs) as the count it flipped and the first
# 500 ids (ID_SAMPLE).
class FlipLongReadCarplayMarksToCarplayOk < PostDeployTask
  ID_SAMPLE = 500
  TIMELINE_NOTE = "CarPlay fit re-read as CarPlay-ok (a long read): a long document or diff is talked through by voice, " \
                  "so it is never laptop-only. The %<source>s mark said Laptop only (a long read)."

  def self.candidates
    Session.where(carplay_fit: SessionCarplayFit::LAPTOP_ONLY, carplay_fit_reason: SessionCarplayFit::REASON_LONG_READ)
  end

  def up
    flipped = []
    self.class.candidates.order(:id).find_each do |session|
      flip(session)
      flipped << session.id
    end

    checkpoint!(flipped: flipped.size, flipped_ids: flipped.first(ID_SAMPLE))
    nil
  end

  private

  def flip(session)
    sticky = session.carplay_fit_source == SessionCarplayFit::SOURCE_AUTO && session.carplay_engaged?
    session.update_columns(
      carplay_fit: SessionCarplayFit::CARPLAY_OK,
      carplay_fit_source: sticky ? SessionCarplayFit::SOURCE_CARPLAY : session.carplay_fit_source,
      updated_at: Time.current
    )
    return if session.carplay_fit_source.in?([ SessionCarplayFit::SOURCE_AUTO, SessionCarplayFit::SOURCE_CARPLAY ])

    session.logs.create!(content: format(TIMELINE_NOTE, source: session.carplay_fit_source), level: "info")
  rescue ActiveRecord::ActiveRecordError => e
    # Best-effort, as in Sessions::SetCarplayFit: a timeline line must not fail the flip.
    logger.error("[FlipLongReadCarplayMarksToCarplayOk] Failed to note the flip on session #{session.id}'s timeline: #{e.message}")
  end
end

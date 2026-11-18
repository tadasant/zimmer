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
# under the new rule that is `carplay_ok` + `long_read`. So the flip is one
# UPDATE of the fit alone. The reason, source, `carplay_fit_set_at` and
# `carplay_fit_line_count` are kept, so a mark that was current stays current,
# a stale one stays stale, and the next rest re-judges each the ordinary way.
# Whatever the source (`auto`, `assistant`, `session`, `human`); a laptop-only
# mark with any other reason is left exactly as it was.
#
# Nothing is written to the sessions' timelines: the mark is the same judgement
# under the new rule, not a new one by a new writer.
#
# It ships with the deploy because AGENTS.md ("ops actions ship with the deploy")
# leaves no other route: nobody has a shell on the production box.
#
# IDEMPOTENT. The UPDATE only matches `laptop_only` + `long_read`, which it
# leaves none of, so a second run flips nothing. Its answer is in
# `post_deploy_task_runs` (on /health, in `GET /api/v1/health`, from
# `get_system_health` and at /supervisor/post_deploy_task_runs) as the ids it
# flipped.
class FlipLongReadCarplayMarksToCarplayOk < PostDeployTask
  def self.candidates
    Session.where(carplay_fit: SessionCarplayFit::LAPTOP_ONLY, carplay_fit_reason: SessionCarplayFit::REASON_LONG_READ)
  end

  def up
    ids = self.class.candidates.order(:id).pluck(:id)
    self.class.candidates.where(id: ids).update_all(carplay_fit: SessionCarplayFit::CARPLAY_OK, updated_at: Time.current)

    checkpoint!(flipped: ids.size, flipped_ids: ids)
    nil
  end
end

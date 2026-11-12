# frozen_string_literal: true

# Declares the two backlog rows that #1489 was filed about as open by design, so
# they stop paging `#alerts` every week (WorkBacklogItem::CONTINUATIONS):
#
#   zimmer#321   multi_slice          each groomer pull lands one slice and
#                                     closes nothing; re-queued by hand 15 times
#   zimmer#1463  awaiting_recurrence  instrumented, no recurrence, open until
#                                     the flake fails again
#
# The marker is set on append, and an append on a key that already has a queued
# row writes nothing, so no agent surface can mark a row that already exists.
# This does it once. Only the newest row per key is marked: older rows are
# superseded and the sweep no longer counts them. The next sweep pass reads the
# marker: zimmer#321 queues its next slice if one merged while the row was out,
# and zimmer#1463 reads `awaiting_recurrence`.
#
# On a deployment that has neither key, it marks nothing.
#
# IDEMPOTENT. A row that already carries a marker is left alone, so a second run
# writes nothing. Its answer is in `post_deploy_task_runs` (on /health, in
# `GET /api/v1/health`, from `get_system_health` and at
# /supervisor/post_deploy_task_runs) as the ids it marked.
class MarkOpenByDesignBacklogRows < PostDeployTask
  MARKERS = {
    "zimmer#321" => WorkBacklogItem::CONTINUATION_MULTI_SLICE,
    "zimmer#1463" => WorkBacklogItem::CONTINUATION_AWAITING_RECURRENCE
  }.freeze

  def up
    marked = MARKERS.filter_map do |key, continuation|
      row = WorkBacklogItem.where(key: key).order(id: :desc).first
      next unless row && row.continuation.nil?

      row.update_columns(continuation: continuation, updated_at: Time.current)
      row.id
    end

    checkpoint!(marked: marked)
    nil
  end
end

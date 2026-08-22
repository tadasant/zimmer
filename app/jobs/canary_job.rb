# frozen_string_literal: true

# Exists to be RUN, nothing more.
#
# The production deploy gate (`scripts/verify-job-drain-remote.sh` in
# `tadasant/tadasant-internal`) enqueues one of these onto every GoodJob queue —
# `default`, `pollers`, `triggers`, `agents` — at negative priority right after a
# cutover, and fails the deploy if the worker does not claim and finish them within
# a bounded timeout. It exists because the 2026-08-13 deploy passed every automated
# check while production processed zero background jobs for ten hours.
#
# Rules for anyone tempted to improve this file:
#
# - Keep it a no-op. Anything this job touches — a query, an HTTP call, a shell-out —
#   becomes a way for the liveness gate to fail for a non-liveness reason, on every
#   production cutover.
# - Never add `good_job_control_concurrency_with`. A concurrency-limited job is
#   *deferred* rather than run, which is indistinguishable from a dead queue and
#   would red healthy deploys.
# - It is not dead code, and it must not be renamed. The gate resolves the class by
#   name (`CANDIDATES = %w[CanaryJob CleanupExpiredElicitationsJob]`); deleting or
#   renaming it silently drops the gate back onto a business job.
class CanaryJob < ApplicationJob
  queue_as :default

  # The token is echoed so a human reading worker logs can match a specific canary
  # to the deploy that enqueued it. Interpolating it is the whole body.
  def perform(token = nil)
    Rails.logger.info("[CanaryJob] #{token}")
  end
end

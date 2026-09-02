# frozen_string_literal: true

# Exists to be RUN, nothing more.
#
# The production deploy gate (`scripts/verify-job-drain-remote.sh` in
# `tadasant/tadasant-internal`) enqueues one of these onto every GoodJob queue —
# `default`, `inference`, `pollers`, `triggers`, `agents`, `auth` — at negative priority right
# after a cutover. The first four are gated; the long-held `agents` and `auth` lanes
# are advisory. It exists because the 2026-08-13 deploy passed every automated
# check while production processed zero background jobs for ten hours.
#
# Rules for anyone tempted to improve this file:
#
# - Keep it a no-op. It touches no database, no network and no shell, and anything
#   it starts touching becomes a way for the liveness gate to fail for a
#   non-liveness reason, on every production cutover.
# - Never add `good_job_control_concurrency_with`. A `total_limit`/`enqueue_limit`
#   rule makes GoodJob `throw :abort` at enqueue time so no row is ever written; a
#   `perform_limit` writes a row that is deferred rather than run. Both are
#   indistinguishable from a dead queue to the gate, and would red healthy deploys.
# - It is not dead code, and it must not be renamed. The gate resolves the class by
#   name, preferring this one and falling back to a business job if it is absent —
#   and that fallback is exactly what this job exists to retire. Renaming or
#   deleting it silently reinstates it.
class CanaryJob < ApplicationJob
  queue_as :default

  # The token is echoed so a human reading worker logs can match a specific canary
  # to the deploy that enqueued it. Interpolating it is the whole body. Extra
  # arguments are swallowed rather than raised on: a gate that grows a second
  # argument should not red a deploy over an ArgumentError from the canary.
  def perform(token = nil, *)
    Rails.logger.info("[CanaryJob] #{token}")
  end
end

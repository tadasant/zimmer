# frozen_string_literal: true

# One change a per-session PR poll found on a webhook-covered session, and whether GitHub's webhook
# had signalled it first (Github::PrWebhookIngest.observe).
#
#   hit          a GithubPrSignal for this change was newer than the evaluator's previous run.
#                `signaled_at` is that signal's time, so `created_at - signaled_at` is how far the
#                webhook was ahead of the poll. GithubPrSignal keeps only the NEWEST time per
#                subject and kind, so after a burst of deliveries this is the last one's lead, a
#                lower bound on the first one's.
#   miss         the poll found the change and no signal had announced it.
#
# Kinds, one per evaluator reading the webhook can make due:
#
#   status          the PR's recorded state (open, merged, closed) moved. Announced by `status`.
#   ci              the PR's recorded CI status moved. Announced by `status` on the PR (check_suite,
#                   check_run) or `ci` on the repository (a commit status) while CI was unsettled.
#   comments        a comment the evaluator had not stored before. Announced by `comments`.
#   merge_conflict  a conflict marker appeared or cleared. Announced by `merge_conflict` on the PR
#                   or `base_push` on the repository.
#
# Written in webhook_shadow and webhook_with_poll_fallback (in the latter, every miss is a change
# only the fallback caught). Kept RETENTION, pruned by InboundEventRetentionJob, read by
# Github::PrWebhookShadowReport.
class GithubPrShadowObservation < ApplicationRecord
  KINDS = %w[status ci comments merge_conflict].freeze

  RETENTION = 30.days

  validates :pr_url, :mode, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :expired, ->(now = Time.current) { where(created_at: ...(now - RETENTION)) }

  def self.record!(session_id:, pr_url:, kind:, mode:, signaled_at:, now: Time.current)
    create!(session_id: session_id, pr_url: pr_url, kind: kind, mode: mode, hit: signaled_at.present?,
            signaled_at: signaled_at, created_at: now)
  end
end

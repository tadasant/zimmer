require "administrate/base_dashboard"

# One change a per-session PR poll found on a webhook-covered session, and whether GitHub's webhook
# signalled it first. See GithubPrShadowObservation; `compare_github_pr_webhook_shadow` (MCP) is the
# aggregate reading, this page the rows behind it.
#
# Read-only by construction: FORM_ATTRIBUTES is empty and the route offers index and show only.
# The rows are the comparison's evidence, so an edited one would change what it reports.
class GithubPrShadowObservationDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session_id: Field::Number,
    pr_url: Field::Url,
    kind: Field::String,
    mode: Field::String,
    hit: Field::Boolean,
    signaled_at: Field::DateTime,
    created_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id kind hit pr_url session_id created_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[id session_id pr_url kind mode hit signaled_at created_at].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(observation)
    "#{observation.kind} #{observation.hit ? 'hit' : 'miss'} #{observation.pr_url}"
  end
end

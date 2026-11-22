require "administrate/base_dashboard"

# What GitHub's webhook has said about tracked pull requests: one row per subject and kind,
# holding the newest time it was said. See GithubPrSignal and Github::PrWebhookIngest.
#
# The no-shell answer to "is the webhook reaching the PR pollers, and for which repositories":
# a `delivery` row per repository is its liveness, and a repository whose row is older than
# Github::PrWebhookIngest::COVERAGE_WINDOW is polled as if it had no hook.
#
# Read-only: the route offers index and show only. A hand-written row would make an evaluator
# read GitHub early, which is harmless, but it would also make a repository look covered.
class GithubPrSignalDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    subject: Field::String,
    kind: Field::String,
    signaled_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id subject kind signaled_at].freeze
  SHOW_PAGE_ATTRIBUTES = %i[id subject kind signaled_at].freeze
  FORM_ATTRIBUTES = %i[].freeze
  COLLECTION_FILTERS = {}.freeze

  def display_resource(signal)
    "#{signal.subject} #{signal.kind}"
  end
end

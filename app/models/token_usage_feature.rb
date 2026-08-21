# frozen_string_literal: true

# One context-management feature's estimated share of one API call.
#
# Written by TokenUsageIngestionService from ContextFeatureAttributor's estimate.
# Every figure here is an ESTIMATE derived from transcript content — the API
# reports per-request totals with no per-feature decomposition — and the estimate
# is constructed so the parts can never exceed the request's real totals. What is
# left over is the unattributed residual, computed at read time rather than
# stored: see CostAnalytics#feature_breakdown.
#
# The columns deliberately mirror `session_token_usages`, so TokenPricing prices
# this table with the same SQL and a feature's DOLLARS fall out of one GROUP BY.
# That is the figure that answers "is this feature worth what it costs" — tokens
# alone cannot, because a cache write bills at up to 2x base input while a cache
# read bills at a tenth.
class TokenUsageFeature < ApplicationRecord
  include TokenAccounting

  belongs_to :session, optional: true
  belongs_to :session_token_usage, primary_key: :request_id, foreign_key: :request_id,
    optional: true, inverse_of: false

  validates :feature, presence: true

  # `request_id` is unique on the PARENT; here the unique key is the pair, because
  # one request splits across several features. The concern's uniqueness
  # validation is scoped to match.
  validates :request_id, uniqueness: { scope: :feature }

  scope :for_feature, ->(feature) { where(feature: feature) }
  scope :for_agent_root, ->(root) { where(agent_root: root) }
  scope :main_thread, -> { where(subagent: false) }

  # Features Zimmer itself injects — the ones this repository can decide to stop
  # injecting, shrink, or serve from a cheaper model. The rest is cost you can
  # see but not directly legislate.
  scope :zimmer_owned, -> { where(feature: ContextFeatureRegistry.zimmer_keys) }

  # TokenAccounting#totals is for the two tables that hold ONE row per API call.
  # Here several rows describe one call, so `api_calls` would be inflated by the
  # number of features detected, and the server-tool counters it sums do not exist
  # on this table at all. Refusing is better than either: a wrong total reads as
  # authoritative. CostAnalytics reads this table through `cost_sum_sql` and
  # `total_tokens_sql`, and reconciles against the PARENT table's totals.
  def self.totals
    raise NotImplementedError,
      "token_usage_features holds several rows per API call — use SessionTokenUsage.totals " \
      "for the whole, and CostAnalytics#feature_breakdown for the split"
  end

  def label = ContextFeatureRegistry.label_for(feature)

  # The concern's `totals` is meaningless here and refuses rather than lying.
  #
  # It counts rows as API calls and sums the per-request server-tool counters.
  # Neither survives the shape of this table: SEVERAL rows describe ONE call, so
  # `api_calls` would come back inflated by the number of features detected, and
  # this table has no server-tool columns at all because a per-request charge
  # cannot be divided across the content features inside that request.
  #
  # CostAnalytics reads this table through `cost_sum_sql` and `total_tokens_sql`,
  # which are correct at any grouping, and takes the call count from the parent.
  def self.totals
    raise NotImplementedError,
      "TokenUsageFeature has several rows per API call — use SessionTokenUsage#totals for " \
      "call counts, and cost_sum_sql / total_tokens_sql for a per-feature rollup."
  end
end

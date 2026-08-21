# frozen_string_literal: true

# One Anthropic API call made by an agent session.
#
# Rows are written by TokenUsageIngestionService, which reads them out of the
# runtime's transcript files. They are keyed on `request_id` — the API's own
# identifier for one call — because a single call appears in the JSONL as several
# assistant lines, each repeating the same `usage` object. See the migration for
# why that distinction is load-bearing.
#
# `session` is nullable and nullifies on delete: a transcript can outlive its
# Session row, and spend that happened is still spend. `agent_root` is
# denormalized for exactly that case, so a deleted session does not take its
# cost out of the by-root rollup with it.
class SessionTokenUsage < ApplicationRecord
  include TokenAccounting

  belongs_to :session, optional: true

  # One row per API call: `request_id` is the API's own identifier for one call.
  validates :request_id, uniqueness: true

  scope :main_thread, -> { where(subagent: false) }
  scope :subagents, -> { where(subagent: true) }
  scope :for_agent_root, ->(root) { where(agent_root: root) }

  # Spend that could not be attributed to a Session row. Worth being able to see
  # rather than silently folding into the totals: a large unattributed share
  # means the transcript-to-session join is degrading.
  scope :unattributed, -> { where(session_id: nil) }

  # Priced spend per session, for the muted indicator on the dashboard cards.
  #
  # ONE grouped query for the whole page. The dashboard renders up to a few
  # hundred cards in a single response, and a per-card lookup would be a per-card
  # round trip. Ids with no stored usage are returned as 0.0 rather than left out,
  # so the caller can cache the miss instead of asking again for every card.
  #
  # @param session_ids [Array<Integer>]
  # @return [Hash{Integer => Float}]
  def self.cost_by_session(session_ids)
    ids = Array(session_ids).compact.uniq
    return {} if ids.empty?

    found = where(session_id: ids)
      .group(:session_id)
      .pluck(:session_id, cost_sum_sql)
      .to_h { |id, cost| [ id, cost.to_f ] }

    ids.index_with { |id| found[id] || 0.0 }
  end
end

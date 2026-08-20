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

  scope :main_thread, -> { where(subagent: false) }
  scope :subagents, -> { where(subagent: true) }
  scope :for_agent_root, ->(root) { where(agent_root: root) }

  # Spend that could not be attributed to a Session row. Worth being able to see
  # rather than silently folding into the totals: a large unattributed share
  # means the transcript-to-session join is degrading.
  scope :unattributed, -> { where(session_id: nil) }
end

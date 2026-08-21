# frozen_string_literal: true

# Which context-management feature a request's tokens went to.
#
# `session_token_usages` answers "what did this API call cost". It cannot answer
# "what was the call carrying", because the `usage` object is a per-request total
# with no decomposition: nothing Anthropic returns says how many input tokens were
# the injected goal versus a skill definition versus an MCP tool result. That
# question is the one that decides whether a context-management feature earns its
# place, gets cut, or gets moved to a cheaper model — so it has to be answered
# some other way.
#
# ESTIMATES, AND WHY THAT IS SAID OUT LOUD
#
# Every number in this table is an ESTIMATE derived from transcript content, not a
# measurement. ContextFeatureAttributor measures the characters each feature
# contributes to a request's prompt, converts to tokens at a fixed ratio, and
# scales the result so the parts can never exceed the request's real totals. What
# is left over is carried explicitly as an unattributed residual rather than being
# spread across the features — most of it is the system prompt and tool schemas,
# which the transcript does not record at all. A confidently wrong attribution is
# worse than a missing one here: it gets a feature cut that was never expensive.
#
# WHY PER-REQUEST ROWS, AND NOT A ROLLUP
#
# Three properties fall out of keying on (request_id, feature) and nothing else:
#
#   1. Idempotence, the same way the parent table gets it. Ingestion upserts and
#      ignores conflicts, so re-scanning a transcript is free — which is what makes
#      a detector added six months from now backfillable over whatever transcripts
#      are still on disk, with no instrumentation in the hot path and no waiting
#      for fresh data. A (session, feature, hour) rollup would need additive
#      upserts, and additive upserts are not re-runnable.
#   2. Reconciliation stays possible. The residual is only honest if the parts can
#      be compared against one request's own totals.
#   3. The column names match the parent's, so TokenPricing.cost_sql prices this
#      table with the same expression, and a feature's DOLLARS — not just its
#      tokens — come out of one GROUP BY. That distinction is the whole point:
#      cache writes bill at up to 2x base input and cache reads at a tenth, so a
#      feature that sits in the stable prompt prefix and one that lands late in the
#      context can move identical token volumes for wildly different money.
#
# The cost is volume: this table grows at roughly the number of features detected
# per request — call it 5-8x the parent. It is denormalized (agent_root, model,
# session_id, subagent, called_at) for the same reason the parent is: the rollups
# this exists to serve group by those axes, and a join to the parent on every one
# of them would be the expensive part. `request_id` carries a foreign key to the
# parent's unique index, so deleting a usage row takes its attribution with it.
#
# `web_search_requests` is deliberately absent. Server-side tools bill per request,
# not per token, and there is no meaningful way to split a per-request charge
# across the content features in that request — so it stays on the parent row and
# lands in the unattributed residual, which is the honest place for it.
class CreateTokenUsageFeatures < ActiveRecord::Migration[8.0]
  def change
    create_table :token_usage_features do |t|
      t.string :request_id, null: false
      t.string :feature, null: false

      # Denormalized from the parent so every breakdown the Costs page offers can
      # be sliced by feature without a join.
      t.bigint :session_id
      t.string :agent_root
      t.string :model, null: false
      t.boolean :subagent, default: false, null: false
      t.datetime :called_at, null: false

      t.bigint :input_tokens, default: 0, null: false
      t.bigint :output_tokens, default: 0, null: false
      t.bigint :cache_read_tokens, default: 0, null: false
      t.bigint :cache_creation_tokens, default: 0, null: false
      t.bigint :cache_creation_5m_tokens, default: 0, null: false
      t.bigint :cache_creation_1h_tokens, default: 0, null: false

      # The evidence behind the estimate: characters measured, and how many
      # distinct occurrences of the feature were in the prompt. Kept because a
      # token figure alone cannot be sanity-checked, and because "the goal block
      # appeared 40 times in this session" is itself the finding sometimes.
      t.bigint :chars, default: 0, null: false
      t.integer :occurrences, default: 0, null: false

      t.timestamps
    end

    add_index :token_usage_features, [ :request_id, :feature ], unique: true

    # `called_at` ALONE, and not only as the trailing half of the composites
    # below. Every read path narrows to the window first and groups second —
    # `by_feature` groups by feature with no feature in the WHERE, `by_agent_root`
    # groups by (agent_root, feature) with no agent_root in the WHERE — so none of
    # the composites is usable for those scans. Without this one Postgres reads
    # the whole table, which is the biggest in the schema. The parent table
    # carries the same index for the same reason.
    add_index :token_usage_features, :called_at

    add_index :token_usage_features, [ :feature, :called_at ]
    add_index :token_usage_features, [ :agent_root, :called_at ]
    add_index :token_usage_features, [ :session_id, :called_at ]

    add_foreign_key :token_usage_features, :session_token_usages,
      column: :request_id, primary_key: :request_id, on_delete: :cascade

    # `session_id` nullifies, matching the parent exactly. Anything else and the
    # two tables disagree after a session is deleted: `session_token_usages`
    # blanks its own `session_id`, so a per-session rollup would find feature rows
    # still pointing at the dead id while the parent reported nothing — a split
    # with no whole to reconcile against, rendering as a full residual of zero.
    add_foreign_key :token_usage_features, :sessions, on_delete: :nullify
  end
end

# frozen_string_literal: true

# Durable token-spend accounting.
#
# Zimmer has never stored what its inference costs. `claude_account_quota_snapshots`
# records per-account utilization percentages read off Anthropic's rate-limit
# response headers — a gauge reading, not a ledger, and it cannot be decomposed by
# session, agent root, or model. `subagent_transcripts.total_tokens` is a single
# undifferentiated integer. Everything else was thrown away: OpenTranscript parses
# `message.usage` and hardcodes `cost_usd: nil`.
#
# Two tables, because the two populations answer different questions:
#
#   session_token_usages — inference an agent session did. The bulk of spend, and
#     the join point for later cost-vs-performance work.
#   adhoc_token_usages   — inference Zimmer's own code made outside any session
#     (HeadlessInferenceService's `claude -p` calls, the CLI status probe). Small
#     in volume, but invisible in the session table by construction, and worth
#     watching precisely because nothing else surfaces it.
#
# Two design commitments worth stating, because getting either wrong silently
# corrupts every number downstream:
#
# 1. `request_id` is the unique key, NOT the transcript line's `uuid`. One API
#    call is written to the JSONL as SEVERAL assistant lines — separate thinking
#    and text content blocks, plus full replays of prior history when a session
#    resumes — and every one of those lines repeats the SAME `usage` object.
#    Keying on `uuid` counts one API response once per content block: measured
#    against this deployment's own corpus, that over-counts tokens by 79%. The
#    unique index is what makes ingestion idempotent and re-runnable.
#
# 2. Volumes are stored, prices are not. Rates change, and we want to re-run old
#    windows at new rates and compare models against the same volumes. Pricing
#    lives in TokenPricing and is applied at read time. This mirrors the method
#    already used in PulseMCP/pulsemcp `agents/agent-roots/inference-metrics`.
#
# The cache columns are split three ways on purpose. Cache writes bill at a
# multiple of base input (1.25x on the 5-minute TTL, 2x on the 1-hour TTL) while
# cache reads bill at a tenth of it, so a single `cache_tokens` column cannot be
# priced. On this deployment cache writes are the largest single line item, and
# 95% of them are on the 1-hour TTL — a distinction worth ~37% of the cache-write
# bill, which a collapsed column would hide.
class CreateTokenUsageTables < ActiveRecord::Migration[8.0]
  def change
    create_table :session_token_usages do |t|
      t.string :request_id, null: false
      t.references :session, foreign_key: { on_delete: :nullify }, null: true, index: true

      # Denormalized so a row survives its session being deleted, and so the
      # primary analytic axis (which agent root spent this) does not need a join.
      t.string :agent_root
      t.string :runtime_session_id
      t.string :agent_runtime, default: "claude_code", null: false

      t.string :model, null: false
      t.boolean :subagent, default: false, null: false

      t.bigint :input_tokens, default: 0, null: false
      t.bigint :output_tokens, default: 0, null: false
      t.bigint :cache_read_tokens, default: 0, null: false
      t.bigint :cache_creation_tokens, default: 0, null: false
      t.bigint :cache_creation_5m_tokens, default: 0, null: false
      t.bigint :cache_creation_1h_tokens, default: 0, null: false

      # Server-side tools bill per request, not per token.
      t.integer :web_search_requests, default: 0, null: false
      t.integer :web_fetch_requests, default: 0, null: false

      t.string :service_tier
      t.datetime :called_at, null: false
      t.string :transcript_path

      t.timestamps
    end

    add_index :session_token_usages, :request_id, unique: true
    add_index :session_token_usages, :called_at
    add_index :session_token_usages, :model
    add_index :session_token_usages, [ :agent_root, :called_at ]
    add_index :session_token_usages, [ :session_id, :called_at ]

    create_table :adhoc_token_usages do |t|
      t.string :request_id, null: false

      # Which piece of Zimmer made the call: `session_title` (SessionTitleJob),
      # `push_notification` (SendPushNotificationJob), `cli_status_probe`
      # (CliStatusRefreshJob's `claude whoami`), or `unknown` when a transcript
      # turns up outside a clone directory that we cannot attribute.
      t.string :source, null: false, default: "unknown"

      # The session the call was ABOUT, where there is one (titling session N).
      # Deliberately not a foreign key on `session_id` semantics: this is
      # provenance, not ownership, and the row outlives the session.
      t.bigint :subject_session_id

      t.string :model, null: false

      t.bigint :input_tokens, default: 0, null: false
      t.bigint :output_tokens, default: 0, null: false
      t.bigint :cache_read_tokens, default: 0, null: false
      t.bigint :cache_creation_tokens, default: 0, null: false
      t.bigint :cache_creation_5m_tokens, default: 0, null: false
      t.bigint :cache_creation_1h_tokens, default: 0, null: false

      t.integer :web_search_requests, default: 0, null: false
      t.integer :web_fetch_requests, default: 0, null: false

      t.string :service_tier
      t.datetime :called_at, null: false
      t.string :transcript_path
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :adhoc_token_usages, :request_id, unique: true
    add_index :adhoc_token_usages, :called_at
    add_index :adhoc_token_usages, [ :source, :called_at ]
    add_index :adhoc_token_usages, :subject_session_id
  end
end

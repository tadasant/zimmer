# frozen_string_literal: true

# One billable or measured operation of a Live Mode voice call: the cost ledger
# behind /live/costs, `get_live_costs` and the per-engine spend caps
# (LiveConversations::SpendGuard).
#
# Every row carries the **engine** that ran the call, the **conversation** it
# belongs to and the **operation** it was:
#
# - `voice_tokens`      a Realtime response's tokens (openai_realtime)
# - `transcription`     the Realtime transcription of one user line
# - `voice_session`     a GPT-Live session's billed seconds (gpt_live_claude)
# - `voice_standby`     a GPT-Live session's seconds held ready for a tap, at
#                       OpenAI's standby rate (gpt_live_claude)
# - `delegation`        one Claude Code run made to answer a delegation
# - `tool_call`         one Zimmer tool Claude ran (unbilled; counted)
# - `turn_latency`      a turn's timings as the client measured them (unbilled)
# - `engine_fallback`   a call that asked for an engine and ran on another
# - `call`              a whole call's length as the client timed it (unbilled),
#                       the denominator for cost per minute on every engine
#
# `mode` is the engine with the models it ran on — `gpt-realtime-2.1 · effort
# high`, `gpt-live-1 + claude-sonnet-5-5` — so a mode is compared with another
# like for like, not just engine with engine (VoiceEngine.mode_for).
#
# `cost_usd` is always the list price. `billing_basis` says whether that money
# was billed (`metered`) or covered by a flat plan (`subscription`). The writer
# that knows how the call was paid for says so: ClaudeDelegate passes the basis
# ClaudeClient derives from the credential the run was given (a subscription
# OAuth token, or an API key billed per token). A row whose writer says nothing
# is `metered`, so money nobody vouched for is counted rather than hidden.
# The "billed" figures — and the spend caps (SpendGuard) — count only metered
# money; the list price is kept beside it so a subscription's value stays
# visible.
#
# Rows written from a client report carry volumes, never dollars: the price is
# applied here, from LiveVoicePricing, with the table version that applied it.
# `idempotency_key` makes a retried report a no-op.
class LiveUsageEvent < ApplicationRecord
  ENGINES = %w[openai_realtime gpt_live_claude livekit_claude].freeze
  OPERATIONS = %w[voice_tokens transcription voice_session voice_standby delegation tool_call turn_latency engine_fallback call].freeze
  BILLING_BASES = %w[metered subscription].freeze
  # Money that was billed, for the caps and the reports: a SQL expression.
  BILLED_COST_SQL = "COALESCE(SUM(cost_usd) FILTER (WHERE billing_basis = 'metered'), 0)"
  VOLUMES = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens audio_input_tokens audio_output_tokens seconds characters count].freeze

  belongs_to :live_conversation, optional: true

  validates :engine, inclusion: { in: ENGINES }
  validates :operation, inclusion: { in: OPERATIONS }
  validates :occurred_at, presence: true
  validates :idempotency_key, uniqueness: true, allow_nil: true
  validates :billing_basis, inclusion: { in: BILLING_BASES }

  attribute :billing_basis, :string, default: "metered"

  before_validation :apply_price, :apply_basis_and_mode, on: :create

  scope :for_engine, ->(engine) { where(engine: engine) }
  scope :between, ->(from, to) { where(occurred_at: from...to) }

  # Writes one event, priced. A repeated idempotency key returns the row that
  # is already there rather than counting the spend twice.
  def self.record!(**attributes)
    attributes[:occurred_at] ||= Time.current
    key = attributes[:idempotency_key].presence
    return find_by(idempotency_key: key) || create!(attributes) if key

    create!(attributes)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    raise unless key && (existing = find_by(idempotency_key: key))

    existing
  end

  def as_api_json
    {
      id: id, live_conversation_id: live_conversation_id, engine: engine, operation: operation, vendor: vendor, model: model,
      **VOLUMES.to_h { |volume| [ volume, volume == :seconds ? seconds.to_f : self[volume] ] },
      mode: mode, cost_usd: cost_usd.to_f, billed_cost_usd: billed_cost_usd, billing_basis: billing_basis, priced: priced, price_version: price_version,
      latency_ms: latency_ms, first_audio_ms: first_audio_ms, error: error, details: details, occurred_at: occurred_at
    }
  end

  def billed_cost_usd = billing_basis == "metered" ? cost_usd.to_f : 0.0

  private

  # What the writer did not say: a mode is the engine's under the current
  # settings, and money is metered.
  def apply_basis_and_mode
    self.billing_basis ||= "metered"
    return if engine.blank?

    self.mode ||= LiveConversations::VoiceEngine.mode_for(engine)
  end

  def apply_price
    price = LiveVoicePricing.price(vendor: vendor, model: model, **VOLUMES.to_h { |volume| [ volume, self[volume] ] })
    self.cost_usd = price.cost_usd
    self.priced = price.priced
    self.price_version = price.version
  end
end

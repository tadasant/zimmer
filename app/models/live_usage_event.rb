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
# - `delegation`        one Claude Messages call made to answer a delegation
# - `tool_call`         one Zimmer tool Claude ran (unbilled; counted)
# - `turn_latency`      a turn's timings as the client measured them (unbilled)
# - `engine_fallback`   a call that asked for an engine and ran on another
#
# Rows written from a client report carry volumes, never dollars: the price is
# applied here, from LiveVoicePricing, with the table version that applied it.
# `idempotency_key` makes a retried report a no-op.
class LiveUsageEvent < ApplicationRecord
  ENGINES = %w[openai_realtime gpt_live_claude livekit_claude].freeze
  OPERATIONS = %w[voice_tokens transcription voice_session delegation tool_call turn_latency engine_fallback].freeze
  VOLUMES = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens audio_input_tokens audio_output_tokens seconds characters count].freeze

  belongs_to :live_conversation, optional: true

  validates :engine, inclusion: { in: ENGINES }
  validates :operation, inclusion: { in: OPERATIONS }
  validates :occurred_at, presence: true
  validates :idempotency_key, uniqueness: true, allow_nil: true

  before_validation :apply_price, on: :create

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
      cost_usd: cost_usd.to_f, priced: priced, price_version: price_version,
      latency_ms: latency_ms, first_audio_ms: first_audio_ms, error: error, details: details, occurred_at: occurred_at
    }
  end

  private

  def apply_price
    price = LiveVoicePricing.price(vendor: vendor, model: model, **VOLUMES.to_h { |volume| [ volume, self[volume] ] })
    self.cost_usd = price.cost_usd
    self.priced = price.priced
    self.price_version = price.version
  end
end

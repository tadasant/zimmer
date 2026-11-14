# frozen_string_literal: true

# Prices one Live Mode usage event from config/live_voice_prices.yml.
#
# Unlike TokenPricing (agent-session spend, priced on read), a voice event is
# priced when it is written, because the engines bill in different units —
# tokens, seconds — and a spend cap has to answer "how much has this
# conversation cost" with one indexed SUM while a call is waiting on it. The
# volumes stay on the row, and so does the table `version` that priced it, so
# nothing is lost by pricing early.
module LiveVoicePricing
  PATH = Rails.root.join("config/live_voice_prices.yml")
  PER_MILLION = 1_000_000.0

  Price = Data.define(:cost_usd, :priced, :version)

  module_function

  def table = @table ||= YAML.safe_load_file(PATH).freeze

  def version = table.fetch("version")

  # Volumes are the event's attributes (input_tokens, seconds, …).
  # @return [Price]
  def price(vendor:, model:, **volumes)
    cost = case vendor.to_s
    when "openai_realtime" then realtime(model, volumes)
    when "openai_transcription" then per_token(table.dig("openai_transcription", model.to_s), volumes)
    when "openai_live" then per_minute(table.dig("openai_live", model.to_s), volumes)
    when "anthropic" then anthropic(model, volumes)
    when "zimmer" then 0.0 # tool calls and latency samples: measured, not billed
    end
    Price.new(cost_usd: (cost || 0.0).round(6), priced: !cost.nil?, version: version)
  end

  def realtime(model, volumes)
    rates = table.dig("openai_realtime", model.to_s)
    return nil unless rates

    audio = rates.fetch("audio")
    text = rates.fetch("text")
    cached = volumes[:cache_read_tokens].to_i
    # The text and audio splits of the cached tokens are not kept apart, so a
    # cached token is priced at the audio cache rate, the dearer of the two.
    text_in = [ volumes[:input_tokens].to_i, 0 ].max
    (volumes[:audio_input_tokens].to_i * audio["input"] + volumes[:audio_output_tokens].to_i * audio["output"] +
      text_in * text["input"] + volumes[:output_tokens].to_i * text["output"] + cached * audio["cached_input"]) / PER_MILLION
  end

  def per_token(rates, volumes)
    return nil unless rates

    (volumes[:input_tokens].to_i * rates["input"] + volumes[:output_tokens].to_i * rates["output"]) / PER_MILLION
  end

  def per_minute(rates, volumes)
    return nil unless rates

    volumes[:seconds].to_f / 60.0 * rates["per_minute"]
  end

  def anthropic(model, volumes)
    rates = table.dig("anthropic", model.to_s)
    return nil unless rates

    (volumes[:input_tokens].to_i * rates["input"] + volumes[:output_tokens].to_i * rates["output"] +
      volumes[:cache_read_tokens].to_i * rates["cache_read"] + volumes[:cache_write_tokens].to_i * rates["cache_write"]) / PER_MILLION
  end

  def anthropic_models = table.fetch("anthropic").keys
end

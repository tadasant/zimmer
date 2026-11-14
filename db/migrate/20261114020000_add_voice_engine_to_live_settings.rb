# frozen_string_literal: true

# Which voice engine a Live call runs on, the Claude model behind the
# experimental engines and how its use is billed, and the spend caps that send a
# call back to the default engine. NULL is the shipped default, as for every other LiveSetting column:
# `openai_realtime`, so nothing changes until somebody picks another engine.
class AddVoiceEngineToLiveSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :live_settings, :voice_engine, :string
    add_column :live_settings, :voice_claude_model, :string
    add_column :live_settings, :voice_claude_billing, :string
    add_column :live_settings, :voice_engine_conversation_cap_usd, :float
    add_column :live_settings, :voice_engine_daily_cap_usd, :float
  end
end

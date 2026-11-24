# frozen_string_literal: true

# A conversation kept ready for the next New (LiveConversations::Standby): one at
# most, so an app that keeps asking for one never leaves a pile of empty ones.
# And the cap on what holding a GPT-Live session in standby may cost a day.
class AddLiveStandby < ActiveRecord::Migration[8.1]
  def change
    add_index :live_conversations, "(true)", unique: true, where: "status = 'standby'", name: "index_live_conversations_one_standby"
    add_column :live_settings, :voice_standby_daily_cap_usd, :float
  end
end

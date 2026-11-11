class AddVoiceCarplayPrewarmToLiveSettings < ActiveRecord::Migration[8.1]
  # Whether the iOS app pre-warms a Realtime connection while CarPlay is
  # connected (LiveSetting `voice_carplay_prewarm`): NULL is the shipped
  # default, `off`. The flag and its kill switch, flipped on the Live settings
  # page without a deploy.
  def change
    add_column :live_settings, :voice_carplay_prewarm, :string
  end
end

# Which lines a voice call answers: everything (nil, the default), only those
# that name Zimmer, or only those a model judges were said to it
# (LiveConversations::Listening).
class AddVoiceListeningToLiveSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :live_settings, :voice_listening, :string
  end
end

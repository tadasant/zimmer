# frozen_string_literal: true

# LiveSetting's voice output cap has a floor of 1,024 that every writer clamps to, and
# a stored value below it never met that check. It goes back to blank, no cap, so
# nobody needs to know it is there: blank is the shipped default, and no person chose
# the value. Recorded in the settings history like any other write. A second run finds
# nothing to do.
class ClearVoiceOutputCapsBelowTheFloor < ActiveRecord::Migration[8.1]
  FLOOR = 1_024

  class Setting < ActiveRecord::Base
    self.table_name = "live_settings"
  end

  class Change < ActiveRecord::Base
    self.table_name = "live_setting_changes"
  end

  def up
    Setting.where("voice_max_output_tokens < ?", FLOOR).find_each do |setting|
      Change.create!(
        changeset: { voice_max_output_tokens: [ setting.voice_max_output_tokens, nil ] },
        actor_kind: "agent", actor: "deploy: voice output cap floor"
      )
      setting.update!(voice_max_output_tokens: nil, updated_by: "agent: deploy: voice output cap floor")
    end
  end

  def down
    # The values it cleared are in live_setting_changes, and none of them should come back.
  end
end

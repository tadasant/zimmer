# frozen_string_literal: true

# LiveSetting's voice output cap gained a floor of 1,024, and every writer clamps to
# it. A value stored before the floor existed never met that check, so it goes back
# to blank, no cap: nobody needs to know it is there. Blank rather than the floor,
# because that is what voice ran with before anything set a cap. Recorded in the
# settings history like any other write. A second run finds nothing to do.
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

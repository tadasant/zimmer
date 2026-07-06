# frozen_string_literal: true

# Singleton table holding global, user-tunable application defaults.
#
# The first (and only) row stores the global base default runtime + model that
# fills in session creation when nothing more specific applies — neither a form/
# API param nor an explicit roots.json value. Both columns are nullable: a blank
# value means "no global override", deferring to the hardcoded runtime/model
# defaults.
class CreateAppSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :app_settings do |t|
      t.string :default_runtime
      t.string :default_model

      t.timestamps
    end
  end
end

# frozen_string_literal: true

# The two operator-tunable knobs behind the categorization loop
# (tadasant/zimmer#16): extra guidance appended to the fixed CATEGORY task, and
# a model override for the inference that runs it.
#
# Both are nullable, and null means "no override" — the guidance is simply not
# appended and the model falls back to CategorizationService::DEFAULT_MODEL.
class AddCategorizationSettingsToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :category_guidance, :text
    add_column :app_settings, :category_inference_model, :string
  end
end

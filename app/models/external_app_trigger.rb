# frozen_string_literal: true

# One entry on a Zimmer plugin's allowlist: this ExternalApp may invoke this
# Trigger. Both foreign keys cascade, so deleting either end removes the entry.
class ExternalAppTrigger < ApplicationRecord
  belongs_to :external_app
  belongs_to :trigger

  validates :trigger_id, uniqueness: { scope: :external_app_id }
end

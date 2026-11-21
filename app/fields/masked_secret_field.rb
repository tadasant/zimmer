# frozen_string_literal: true

require "administrate/field/base"

# An Administrate field for a stored secret: the panel says whether it is set and
# never renders the value — not on the index, not on the show page, and not
# pre-filled into the edit form (Administrate's own Password field puts the
# value into the input's `value` attribute, i.e. into the page source).
#
# The form takes a NEW value. A blank submission keeps the stored one; the
# controller drops blank masked params before they reach the model (see
# Supervisor::McpOauthCredentialsController#resource_params).
class MaskedSecretField < Administrate::Field::Base
  def self.searchable? = false

  def self.sortable? = false

  def to_s
    data.present? ? "set (hidden)" : "not set"
  end
end

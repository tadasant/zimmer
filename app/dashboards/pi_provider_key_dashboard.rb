require "administrate/base_dashboard"

# The short-lived OpenRouter keys PiSessionKeys minted for Pi spawns: one row per key,
# holding OpenRouter's identifier for it (never the key), its cap and expiry, and when and
# why it was revoked, with the spend OpenRouter reported at that moment.
#
# The no-shell answer to "is the feature minting, are keys being revoked, and is any revoke
# stuck": an active row with `last_error` is a revoke PiProviderKeySweepJob keeps retrying.
#
# Read-only: the route offers index and show only. PiSessionKeys owns every row.
class PiProviderKeyDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session_id: Field::Number,
    key_hash: Field::String,
    name: Field::String,
    limit_usd: Field::Number.with_options(decimals: 2),
    expires_at: Field::DateTime,
    revoked_at: Field::DateTime,
    revoke_reason: Field::String,
    usage_usd: Field::Number.with_options(decimals: 6),
    last_error: Field::Text,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id session_id created_at expires_at revoked_at revoke_reason usage_usd].freeze
  SHOW_PAGE_ATTRIBUTES = %i[
    id session_id key_hash name limit_usd expires_at revoked_at revoke_reason usage_usd last_error
    created_at updated_at
  ].freeze
  FORM_ATTRIBUTES = %i[].freeze
  COLLECTION_FILTERS = {}.freeze

  def display_resource(key)
    "Pi key ##{key.id} (session #{key.session_id || 'none'})"
  end
end

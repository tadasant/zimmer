# frozen_string_literal: true

# A phone Zimmer's iOS app registered for push notifications: one APNs device
# token, the APNs environment it belongs to, and the OAuth grant it was registered
# under. ApnsService delivers to every deliverable row; see that class for the
# sender and its configuration.
#
# Registration is an upsert on the token (POST /api/v1/apns_devices), so the app
# can register on every launch — iOS hands out the same token until it rotates
# one — and a re-registration revives a row that was disabled. A device stops
# being deliverable when Apple reports its token dead (`disabled_at`), when the
# app unregisters it on sign-out (the row is deleted), or when the grant it was
# registered under is revoked: a revoked phone must not keep receiving session
# titles on its lock screen.
class ApnsDevice < ApplicationRecord
  SANDBOX = "sandbox"
  PRODUCTION = "production"
  ENVIRONMENTS = [ SANDBOX, PRODUCTION ].freeze

  # APNs tokens are 32 bytes today, sent as hex; Apple reserves the right to make
  # them longer, so the bound is generous rather than exact.
  TOKEN_FORMAT = /\A[0-9a-f]{64,200}\z/

  belongs_to :grant, class_name: "OauthServer::Grant", foreign_key: :oauth_server_grant_id, optional: true

  validates :token, format: { with: TOKEN_FORMAT, message: "must be the device token in lowercase hex" }, uniqueness: true
  validates :environment, inclusion: { in: ENVIRONMENTS }
  validates :device_name, :app_version, length: { maximum: 100 }
  validates :last_registered_at, presence: true

  # Not disabled, and not registered under a grant that has since been revoked.
  # A row with no grant (registered over an API key) stays deliverable.
  scope :deliverable, lambda {
    left_joins(:grant).where(disabled_at: nil).where(oauth_server_grants: { revoked_at: nil })
  }

  # @return [ApnsDevice]
  def self.register!(token:, environment:, grant:, device_name: nil, app_version: nil, now: Time.current)
    device = find_or_initialize_by(token: token.to_s.downcase)
    device.assign_attributes(
      environment: environment, grant: grant, device_name: device_name.presence&.truncate(100),
      app_version: app_version.presence&.truncate(100), last_registered_at: now,
      disabled_at: nil, disabled_reason: nil
    )
    device.save!
    device
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def disable!(reason)
    update!(disabled_at: Time.current, disabled_reason: reason.to_s.truncate(200))
  end

  def disabled? = disabled_at.present?

  # The token is a delivery address, not a secret, but nothing needs all of it in
  # a log line.
  def token_hint
    "#{token.first(8)}…"
  end
end

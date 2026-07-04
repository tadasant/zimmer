# Stores web push notification subscriptions for the application.
#
# Each subscription contains the endpoint URL and encryption keys needed
# to send push notifications to a specific browser/device.
#
# Attributes:
#   endpoint    - The push service URL (unique identifier for the subscription)
#   p256dh_key  - Public key for message encryption (base64 encoded)
#   auth_key    - Authentication secret (base64 encoded)
#   user_agent  - Optional browser/device identifier for debugging
class PushSubscription < ApplicationRecord
  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh_key, presence: true
  validates :auth_key, presence: true
end

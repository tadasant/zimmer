# Service for sending web push notifications to subscribed browsers/devices.
#
# Wraps the web-push gem to provide a clean interface for sending notifications
# to all active PushSubscription records. Handles errors gracefully:
# - 410 Gone: Subscription expired, automatically deleted
# - Network errors: Logged but don't crash the caller
#
# Usage:
#   service = WebPushService.new
#   result = service.send_to_all(
#     title: "Session Complete",
#     body: "Your agent session has finished",
#     url: "/sessions/123"
#   )
#   result[:sent]    # Number of successful sends
#   result[:failed]  # Number of failed sends
#   result[:expired] # Number of expired subscriptions removed
class WebPushService
  # WebPush gem wrapper for dependency injection in tests
  attr_accessor :webpush_client

  def initialize(webpush_client: WebPush)
    @webpush_client = webpush_client
    @logger = Rails.logger
  end

  # Send a push notification to all active subscriptions
  #
  # @param title [String] Notification title
  # @param body [String] Notification body text
  # @param url [String, nil] URL to open when notification is clicked
  # @param data [Hash] Additional data to include in the payload
  # @return [Hash] Results with :sent, :failed, :expired counts
  def send_to_all(title:, body:, url: nil, data: {})
    unless WebpushConfig.configured?
      @logger.warn "[WebPushService] VAPID keys not configured, skipping push notifications"
      return { sent: 0, failed: 0, expired: 0, skipped: true }
    end

    subscriptions = PushSubscription.all
    results = { sent: 0, failed: 0, expired: 0 }

    subscriptions.find_each do |subscription|
      result = send_to_subscription(subscription, title: title, body: body, url: url, data: data)
      results[result] += 1
    end

    @logger.info "[WebPushService] Push notification results: #{results.inspect}"
    results
  end

  # Send a push notification to a single subscription
  #
  # @param subscription [PushSubscription] The subscription to send to
  # @param title [String] Notification title
  # @param body [String] Notification body text
  # @param url [String, nil] URL to open when notification is clicked
  # @param data [Hash] Additional data to include in the payload
  # @return [Symbol] :sent, :failed, or :expired
  def send_to_subscription(subscription, title:, body:, url: nil, data: {})
    payload = build_payload(title: title, body: body, url: url, data: data)

    @webpush_client.payload_send(
      message: payload.to_json,
      endpoint: subscription.endpoint,
      p256dh: subscription.p256dh_key,
      auth: subscription.auth_key,
      vapid: WebpushConfig.vapid_keys,
      urgency: "normal"
    )

    @logger.debug "[WebPushService] Sent notification to #{subscription.endpoint.truncate(50)}"
    :sent
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription => e
    # 410 Gone - subscription is no longer valid, delete it
    @logger.info "[WebPushService] Removing expired subscription: #{subscription.endpoint.truncate(50)} - #{e.class.name}"
    subscription.destroy
    :expired
  rescue WebPush::ResponseError => e
    # Other HTTP errors from the push service
    @logger.error "[WebPushService] Push service error for #{subscription.endpoint.truncate(50)}: #{e.message}"
    :failed
  rescue StandardError => e
    # Network errors, timeouts, etc.
    @logger.error "[WebPushService] Failed to send notification: #{e.class.name} - #{e.message}"
    :failed
  end

  private

  # Build the notification payload
  #
  # @param title [String] Notification title
  # @param body [String] Notification body text
  # @param url [String, nil] URL to open when notification is clicked
  # @param data [Hash] Additional data to include
  # @return [Hash] The notification payload
  def build_payload(title:, body:, url: nil, data: {})
    payload = {
      title: title,
      body: body,
      icon: "/icons/icon-192x192.png",
      badge: "/icons/icon-192x192.png"
    }

    payload[:data] = data.merge(url: url) if url.present?
    payload[:data] = data if url.blank? && data.present?

    payload
  end
end

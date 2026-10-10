# frozen_string_literal: true

# Sends push notifications to Zimmer's iOS app through Apple's push service, the
# native counterpart of WebPushService. SendPushNotificationJob calls both with
# the same payload.
#
# APNs takes one HTTP/2 POST per device to /3/device/<token>, on the production
# host for TestFlight and App Store builds and the sandbox host for development
# builds — a token only works against the environment it was issued in, which is
# why ApnsDevice stores it. The request authenticates with a provider token: an
# ES256 JWT over {iss: team id, iat}, signed with the .p8 key and named by its
# Key ID. Apple refuses one older than an hour and throttles one refreshed more
# often than every twenty minutes, so it is minted once and reused for 50.
#
# **Inert until configured.** With no key (Apns::Config#configured? false),
# `send_to_all` returns `skipped: true` and makes no request — the state this
# deployment is in until a human creates the APNs key. Every failure after that
# is best-effort: a push that cannot be sent is logged and counted, never raised
# into the job that asked for it.
class ApnsService
  HOSTS = {
    ApnsDevice::PRODUCTION => "https://api.push.apple.com",
    ApnsDevice::SANDBOX => "https://api.sandbox.push.apple.com"
  }.freeze
  PROVIDER_TOKEN_TTL = 50.minutes
  REQUEST_TIMEOUT = 10
  # Apple's reasons for a token that will never work again: disable the device.
  DEAD_TOKEN_REASONS = %w[BadDeviceToken DeviceTokenNotForTopic Unregistered].freeze
  # Reasons that mean our provider token is the problem: mint a fresh one next time.
  PROVIDER_TOKEN_REASONS = %w[ExpiredProviderToken InvalidProviderToken].freeze

  # The HTTP/2 client, behind a seam so the tests never reach Apple.
  class Transport
    Response = Data.define(:status, :body)

    def post(url, headers:, body:)
      response = HTTPX.with(timeout: { request_timeout: REQUEST_TIMEOUT }).post(url, headers: headers, body: body)
      raise response.error if response.is_a?(HTTPX::ErrorResponse)

      Response.new(status: response.status, body: response.to_s)
    end
  end

  @provider_tokens = {}
  @provider_tokens_mutex = Mutex.new

  class << self
    # One provider token per key, shared across jobs in the process.
    def provider_token(config, now: Time.current)
      @provider_tokens_mutex.synchronize do
        cached = @provider_tokens[config.key_id]
        return cached[:token] if cached && now - cached[:issued_at] < PROVIDER_TOKEN_TTL

        token = JWT.encode({ iss: config.team_id, iat: now.to_i }, config.signing_key, "ES256", { kid: config.key_id })
        @provider_tokens[config.key_id] = { token: token, issued_at: now }
        token
      end
    end

    def reset_provider_tokens!
      @provider_tokens_mutex.synchronize { @provider_tokens = {} }
    end
  end

  def initialize(config: Apns::Config.current, transport: Transport.new)
    @config = config
    @transport = transport
    @logger = Rails.logger
  end

  # @return [Hash] :sent, :failed, :disabled counts, or `skipped: true` when unconfigured
  def send_to_all(title:, body:, url: nil, data: {})
    unless @config.configured?
      @logger.info("[apns] not configured (missing #{@config.missing.join(', ')}); no iOS push sent")
      return { sent: 0, failed: 0, disabled: 0, skipped: true }
    end

    results = { sent: 0, failed: 0, disabled: 0 }
    payload = build_payload(title: title, body: body, data: data)
    ApnsDevice.deliverable.find_each do |device|
      results[deliver(device, payload, collapse_id: collapse_id(data))] += 1
    end
    @logger.info("[apns] results: #{results.inspect}")
    results
  end

  # @return [Symbol] :sent, :failed or :disabled
  def deliver(device, payload, collapse_id: nil)
    headers = {
      "authorization" => "bearer #{self.class.provider_token(@config)}",
      "apns-topic" => @config.topic,
      "apns-push-type" => "alert",
      "apns-priority" => "10",
      "content-type" => "application/json"
    }
    headers["apns-collapse-id"] = collapse_id if collapse_id
    response = @transport.post("#{HOSTS.fetch(device.environment)}/3/device/#{device.token}", headers: headers, body: payload)
    classify(device, response)
  rescue StandardError => e
    @logger.warn("[apns] delivery to #{device.token_hint} failed: #{e.class}: #{e.message}")
    :failed
  end

  private

  def classify(device, response)
    return mark_delivered(device) if response.status == 200

    reason = (JSON.parse(response.body)["reason"] rescue nil)
    if response.status == 410 || DEAD_TOKEN_REASONS.include?(reason)
      device.disable!(reason || "Unregistered")
      @logger.info("[apns] disabled #{device.token_hint}: #{reason || response.status}")
      :disabled
    else
      self.class.reset_provider_tokens! if PROVIDER_TOKEN_REASONS.include?(reason)
      @logger.warn("[apns] #{device.token_hint} refused: #{response.status} #{reason}")
      :failed
    end
  end

  def mark_delivered(device)
    device.update_column(:last_delivered_at, Time.current)
    :sent
  end

  # The app opens the session the push is about; `thread-id` groups a session's
  # notifications together on the lock screen.
  def build_payload(title:, body:, data:)
    session_id = data[:session_id] || data["session_id"]
    aps = { alert: { title: title.to_s.truncate(120), body: body.to_s.truncate(400) }, sound: "default" }
    aps[:"thread-id"] = "session-#{session_id}" if session_id
    { aps: aps }.merge(data.to_h.transform_keys(&:to_s).slice("session_id", "notification_type")).to_json
  end

  def collapse_id(data)
    session_id = data[:session_id] || data["session_id"]
    type = data[:notification_type] || data["notification_type"]
    "session-#{session_id}-#{type}".first(64) if session_id && type
  end
end

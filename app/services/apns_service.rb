# frozen_string_literal: true

# Sends push notifications to Zimmer's iOS app through Apple's push service, the
# native counterpart of WebPushService. SendPushNotificationJob calls both with
# the same payload.
#
# **No session content leaves for Apple.** A web push is encrypted end to end
# (RFC 8291), so the browser's push service relays ciphertext. An APNs alert is
# readable by Apple. So the alert says only what kind of thing happened ("A
# session needs you") and carries the session id; the session's title, the
# summary of its last message, a failure detail and an agent's custom message all
# stay on the server, and the app shows them when the push is tapped, over its
# authenticated API. `title:` and `body:` are accepted so both services share the
# job's payload, and are deliberately never sent.
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
  # What the lock screen says, by notification type. Generic on purpose: see the
  # class comment.
  ALERT_BODIES = {
    "needs_input" => "A session needs you.",
    "elicitation_pending" => "A session is asking you something.",
    "session_complete" => "A session finished.",
    "session_failed" => "A session failed.",
    "custom_message" => "A session sent you a message."
  }.freeze
  ALERT_TITLE = "Zimmer"

  # The HTTP/2 client, behind a seam so the tests never reach Apple. One client per
  # ApnsService, which is one per job, so a batch reuses a connection per host as
  # Apple asks rather than opening one per phone.
  class Transport
    Response = Data.define(:status, :body)

    def initialize
      @client = HTTPX.plugin(:persistent).with(timeout: { request_timeout: REQUEST_TIMEOUT })
    end

    def post(url, headers:, body:)
      response = @client.post(url, headers: headers, body: body)
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
    @provider_token_reset = false
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
      # Once per batch: a wrong key fails every phone, and minting a token per refusal
      # would trip Apple's TooManyProviderTokenUpdates.
      if PROVIDER_TOKEN_REASONS.include?(reason) && !@provider_token_reset
        self.class.reset_provider_tokens!
        @provider_token_reset = true
      end
      @logger.warn("[apns] #{device.token_hint} refused: #{response.status} #{reason}")
      :failed
    end
  end

  def mark_delivered(device)
    device.update_column(:last_delivered_at, Time.current)
    :sent
  end

  # The app opens the session the push is about; `thread-id` groups a session's
  # notifications together on the lock screen. `title` and `body` are not used.
  def build_payload(title:, body:, data:) # rubocop:disable Lint/UnusedMethodArgument
    session_id = data[:session_id] || data["session_id"]
    type = (data[:notification_type] || data["notification_type"]).to_s
    alert_body = ALERT_BODIES.fetch(type, "Something happened in a session.")
    aps = { alert: { title: ALERT_TITLE, body: alert_body }, sound: "default" }
    aps[:"thread-id"] = "session-#{session_id}" if session_id
    { aps: aps }.merge(data.to_h.transform_keys(&:to_s).slice("session_id", "notification_type")).to_json
  end

  # A newer push of the same kind about the same session replaces the older one on
  # the lock screen. Custom messages each say something different, so never collapse.
  def collapse_id(data)
    session_id = data[:session_id] || data["session_id"]
    type = data[:notification_type] || data["notification_type"]
    return nil if session_id.nil? || type.nil? || type.to_s == "custom_message"

    "session-#{session_id}-#{type}".first(64)
  end
end

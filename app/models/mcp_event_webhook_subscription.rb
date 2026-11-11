# frozen_string_literal: true

# A webhook subscription Zimmer holds on a catalog MCP server for one `mcp_event` condition: the
# MCP Events extension's webhook mode (SEP-3415 @ b08e4f9, "Webhook-Based Delivery").
#
# The server POSTs each event to `callback_url` — `/webhooks/mcp_events/<token>` on Zimmer's public
# base URL — signed with `secret`, which Zimmer generates (the SEP has the client supply it) and
# keeps here encrypted. The token in the path is how Webhooks::McpEventsController picks the secret
# before it reads the body. It also means every condition has its own URL, so the server's
# subscription key `(principal, url, name, arguments)` maps to exactly one row.
#
# The row copies the condition's `server`, `event_name` and `arguments` rather than reading them
# through the association, because those are what an `events/unsubscribe` has to name. When the
# condition is edited to a different subscription, disabled or deleted, the copy is what lets
# McpEventSubscriptionsJob unsubscribe from what was subscribed, and the FK is nullified rather
# than cascaded for the same reason.
#
# `state`:
#
#   pending    created, or terminated by the server; the next sweep subscribes
#   subscribed `events/subscribe` succeeded, and nothing signed has arrived on the URL yet
#   verified   a signed request — the challenge or a delivery — has arrived on the URL, so the
#              path through Cloudflare Access works; only here does the poller slow down
#   suspended  the server's last refresh said it had suspended delivery after repeated failures
#   failed     subscribing failed; retried with backoff, and the condition polls as before
#
# Polling never stops whatever the state — see McpEventTriggerPollerJob.
class McpEventWebhookSubscription < ApplicationRecord
  STATES = %w[pending subscribed verified suspended failed].freeze

  # What the trigger UI and MCP tools call each state. `pending` and `failed` both mean the events
  # still arrive by polling alone.
  DISPLAY_STATES = {
    "pending" => "poll-only", "failed" => "poll-only",
    "subscribed" => "subscribed", "verified" => "verified", "suspended" => "suspended"
  }.freeze

  ENCRYPTION_SALT = "zimmer-mcp-events-webhook-secret-v1"

  belongs_to :trigger_condition, optional: true

  validates :token, :server, :event_name, :callback_url, :secret_ciphertext, presence: true
  validates :state, inclusion: { in: STATES }

  # Mint a row for +condition+, with a fresh token and secret.
  def self.build_for(condition, base_url:)
    token = SecureRandom.urlsafe_base64(24)
    new(
      trigger_condition: condition,
      token: token,
      server: condition.mcp_event_server,
      event_name: condition.mcp_event_name,
      arguments: condition.mcp_event_arguments,
      callback_url: "#{base_url.to_s.chomp('/')}/webhooks/mcp_events/#{token}",
      secret: Webhooks::StandardWebhooksSignature.generate_secret
    )
  end

  def self.encryptor
    key = Rails.application.key_generator.generate_key(ENCRYPTION_SALT, ActiveSupport::MessageEncryptor.key_len)
    ActiveSupport::MessageEncryptor.new(key)
  end

  def secret
    self.class.encryptor.decrypt_and_verify(secret_ciphertext)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def secret=(value)
    self.secret_ciphertext = self.class.encryptor.encrypt_and_sign(value)
  end

  # Whether this row still describes what +condition+ listens for, at +callback_url+.
  def matches?(condition, base_url: nil)
    return false if condition.nil?
    return false if base_url && !callback_url.start_with?("#{base_url.to_s.chomp('/')}/")

    [ server, event_name, arguments ] == condition.mcp_event_subscription
  end

  # Whether deliveries on this row should still fire anything: its condition exists, its trigger is
  # enabled, and it still listens for what this row subscribed to.
  def live?
    condition = trigger_condition
    condition.present? && condition.trigger&.status == "enabled" && matches?(condition)
  end

  # Whether push is carrying this condition's events, so the poller can fall back to a slow
  # catch-up cadence: a signed request has arrived on the URL, the server has not reported suspended
  # delivery, and the grant has not run out.
  def healthy?(now = Time.current)
    state == "verified" && (refresh_before.nil? || refresh_before > now)
  end

  def display_state
    return "suspended" if state != "failed" && state != "pending" && refresh_before && refresh_before <= Time.current

    DISPLAY_STATES.fetch(state, "poll-only")
  end

  # What the trigger page, the API and search_triggers show for the condition.
  def status_summary
    {
      "state" => display_state,
      "subscribed_at" => subscribed_at&.iso8601,
      "refresh_before" => refresh_before&.iso8601,
      "verified_at" => verified_at&.iso8601,
      "last_delivery_at" => last_delivery_at&.iso8601,
      "last_error" => last_error
    }.compact
  end

  # A signed request arrived on the URL — the challenge, an event, or a control envelope.
  def note_signed_request!(remote_id: nil, cursor: :unchanged, delivered: false)
    attrs = { verified_at: Time.current }
    attrs[:state] = "verified" if %w[subscribed suspended].include?(state)
    attrs[:remote_id] = remote_id if remote_id.present? && remote_id.to_s.length <= 255 && self.remote_id.blank?
    attrs[:cursor] = cursor unless cursor == :unchanged
    attrs[:last_delivery_at] = Time.current if delivered
    update_columns(attrs.merge(updated_at: Time.current))
  end
end

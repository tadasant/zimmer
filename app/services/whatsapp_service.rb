# frozen_string_literal: true

# Zimmer's client for a WhatsApp bridge: an MCP server that holds a WhatsApp linked-device
# session and answers `whatsapp_status`, `whatsapp_list_chats` and `whatsapp_get_messages`.
#
# Zimmer never speaks WhatsApp's protocol itself. A linked-device client is a long-lived,
# stateful socket with key material that changes on every message, and it has to be exactly
# one process, so it lives beside the other MCP servers (on the Tadasant deployment, strad's
# `whatsapp-zimmer` slug) rather than in a Rails worker that is restarted on every deploy.
# The same server is what a session uses to read the chat and post into it, so the poller and
# the agent see one account's view of one chat.
#
# Zimmer POLLS it. `/webhooks/*` has no public way in (see limitations.md), and a bridge that
# pushed would need one.
#
# Two settings, resolved through SecretProviders.chain (Parameter Store, then encrypted
# credentials, then ENV):
#
#   WHATSAPP_MCP_URL    the bridge's Streamable HTTP endpoint. Unset means WhatsApp is not
#                       configured, and the poller does nothing.
#   WHATSAPP_MCP_TOKEN  sent as `Authorization: Bearer`. Falls back to STRAD_API_KEY, which is
#                       the key a strad-served bridge already accepts from Zimmer.
class WhatsappService
  class Error < StandardError; end

  # The bridge answered but is not logged in to WhatsApp — the phone unlinked it, or it was
  # never paired. Distinct from Error because it is a setup problem, not a transport one.
  class NotConnectedError < Error; end

  URL_KEY = "WHATSAPP_MCP_URL"
  TOKEN_KEY = "WHATSAPP_MCP_TOKEN"
  TOKEN_FALLBACK_KEY = "STRAD_API_KEY"

  # The most `whatsapp_get_messages` returns per call, by the bridge's contract.
  MAX_PAGE = 200

  # One message, as the bridge describes it. Every field is read off the bridge's JSON; none of
  # it is trusted beyond its shape — `text` and `sender_name` are whatever a person typed.
  Message = Data.define(
    :id, :chat_id, :timestamp, :sender_jid, :sender_name, :from_me, :sent_by_bridge,
    :text, :type, :quoted_message_id, :mentions_self, :reply_to_self
  ) do
    def self.from_json(hash)
      new(
        id: hash["id"].to_s,
        chat_id: hash["chat_id"].to_s,
        timestamp: hash["timestamp"].to_i,
        sender_jid: hash["sender_jid"].presence,
        sender_name: hash["sender_name"].presence,
        from_me: hash["from_me"] == true,
        sent_by_bridge: hash["sent_by_bridge"] == true,
        text: hash["text"],
        type: hash["type"].presence || "other",
        quoted_message_id: hash["quoted_message_id"].presence,
        mentions_self: hash["mentions_self"] == true,
        reply_to_self: hash["reply_to_self"] == true
      )
    end
  end

  Page = Data.define(:chat_id, :chat_name, :self_jid, :messages, :has_more)
  Status = Data.define(:connected, :paired, :self_jid, :self_name, :last_event_at) do
    def ready?
      connected && paired
    end
  end

  class << self
    def configured?
      url.present?
    end

    def url
      setting(URL_KEY)
    end

    def token
      setting(TOKEN_KEY) || setting(TOKEN_FALLBACK_KEY)
    end

    private

    def setting(key)
      SecretProviders.chain.get(key).presence
    end
  end

  def initialize(client: nil)
    @client = client
  end

  # @return [Status]
  def status
    json = call("whatsapp_status", {})
    Status.new(
      connected: json["connected"] == true,
      paired: json["paired"] == true,
      self_jid: json["self_jid"].presence,
      self_name: json["self_name"].presence,
      last_event_at: json["last_event_at"]
    )
  end

  # Raises NotConnectedError unless the bridge is logged in. The poller asks once per sweep:
  # a bridge that lost its link still answers get_messages from its buffer, and a poll that
  # reads a frozen buffer is not a poll of WhatsApp.
  def ensure_ready!
    current = status
    return current if current.ready?

    raise NotConnectedError, current.paired ? "the WhatsApp bridge is paired but not connected" : "the WhatsApp bridge is not paired to an account"
  end

  # Messages in +chat_id+ with a timestamp at or after +after+, oldest first.
  #
  # @return [Page]
  def get_messages(chat_id, after: nil, limit: 50)
    arguments = { "chat_id" => chat_id, "limit" => limit.clamp(1, MAX_PAGE) }
    arguments["after"] = after.to_i if after
    json = call("whatsapp_get_messages", arguments)

    messages = Array(json["messages"]).filter_map { |m| Message.from_json(m) if m.is_a?(Hash) && m["id"].present? }
    Page.new(
      chat_id: json["chat_id"].presence || chat_id,
      chat_name: json["chat_name"].presence,
      self_jid: json["self_jid"].presence,
      messages: messages.sort_by(&:timestamp),
      has_more: json["has_more"] == true
    )
  end

  # @return [Array<Hash>] the chats the account is in, newest activity first
  def list_chats(limit: 50, query: nil)
    arguments = { "limit" => limit }
    arguments["query"] = query if query.present?
    Array(call("whatsapp_list_chats", arguments)["chats"]).select { |chat| chat.is_a?(Hash) }
  end

  private

  def client
    @client ||= begin
      raise Error, "#{URL_KEY} is not set" unless self.class.configured?

      headers = {}
      token = self.class.token
      headers["Authorization"] = "Bearer #{token}" if token
      McpApps::Client.new(url: self.class.url, headers: headers)
    end
  end

  # A gateway fronting several servers namespaces their tools (`whatsapp-zimmer__whatsapp_status`),
  # a bridge served on its own does not, so the name is looked up rather than assumed.
  def tool_name(name)
    @tool_names ||= client.tools_list.filter_map { |tool| tool["name"] if tool.is_a?(Hash) }
    @tool_names.find { |candidate| candidate == name } ||
      @tool_names.find { |candidate| candidate.end_with?("__#{name}") } ||
      raise(Error, "the WhatsApp bridge does not offer #{name}")
  end

  def call(name, arguments)
    result = client.call_tool(tool_name(name), arguments)
    json = result_json(result)
    raise Error, "#{name} failed: #{error_text(result)}" if result["isError"]

    json
  rescue McpApps::Client::Error => e
    raise Error, "#{name}: #{e.message}"
  end

  # The bridge returns its answer as `structuredContent` and as JSON in the first text item.
  def result_json(result)
    return result["structuredContent"] if result["structuredContent"].is_a?(Hash)

    text = Array(result["content"]).find { |item| item.is_a?(Hash) && item["type"] == "text" }&.dig("text")
    parsed = text.present? ? JSON.parse(text) : {}
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def error_text(result)
    Array(result["content"]).filter_map { |item| item["text"] if item.is_a?(Hash) }.join(" ").truncate(300).presence || "no detail"
  end
end

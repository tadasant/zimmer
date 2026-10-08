# frozen_string_literal: true

# Zimmer's client for a mailbox: an MCP server that speaks the Gmail tool contract of
# `pulsemcp/mcp-servers/experimental/gmail` — `search_email_conversations` and
# `get_email_conversation`, among others. On the Tadasant deployment that is a strad gmail slug
# (`gmail-zimmer-ro`, a read-only mount of zimmer@tadasant.com), but nothing here names a mailbox:
# whichever account the server reads is the one the `email` trigger watches.
#
# Zimmer POLLS it, for the same reason it polls the WhatsApp bridge: `/webhooks/*` has no public
# way in (see limitations.md), and Gmail push needs one.
#
# The server answers in markdown, not JSON, so this class parses the fields the contract prints
# (`**ID:** …`, `**Thread ID:** …`, `## Body`). Everything it returns except the two ids is what
# the SENDER wrote — subject, From, body, even the To line — and is never trusted beyond its shape.
#
# Two settings, resolved through SecretProviders.chain (Parameter Store, then encrypted
# credentials, then ENV):
#
#   EMAIL_MCP_URL    the mailbox server's Streamable HTTP endpoint. Unset means email is not
#                    configured, and the poller does nothing.
#   EMAIL_MCP_TOKEN  sent as `Authorization: Bearer`. Falls back to STRAD_API_KEY, which is the
#                    key a strad-served mailbox already accepts from Zimmer.
class EmailService
  class Error < StandardError; end

  URL_KEY = "EMAIL_MCP_URL"
  TOKEN_KEY = "EMAIL_MCP_TOKEN"
  TOKEN_FALLBACK_KEY = "STRAD_API_KEY"

  # The most `search_email_conversations` returns per call, by the server's contract. It has no
  # pagination: a search matching more returns the newest MAX_RESULTS.
  MAX_RESULTS = 100

  # A Gmail message or thread id: lower-case hex on Gmail itself. Anything else the server prints
  # where an id belongs is dropped rather than passed on as one.
  ID_FORMAT = /\A[0-9A-Za-z]{1,128}\z/

  # One search hit: the ids, and the subject as the search printed it. Only the ids are used to
  # decide anything.
  Summary = Data.define(:id, :thread_id, :subject)

  # One message, read in full. `labels` are Gmail's system and category labels (INBOX, SENT,
  # CATEGORY_PROMOTIONS, …), the one field here that Gmail set rather than the sender. `url` is the
  # account-scoped Gmail link the server builds from the id.
  Message = Data.define(:id, :thread_id, :url, :subject, :from, :to, :cc, :date, :labels, :body, :attachments) do
    # The address in the From header, lower-cased: `Name <a@b.c>` and bare `a@b.c` alike.
    def from_address
      (from.to_s[/<([^<>\s]+@[^<>\s]+)>/, 1] || from.to_s[/[^\s<>"]+@[^\s<>"]+/]).to_s.downcase.presence
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

  # Messages matching a Gmail search +query+, newest first as Gmail returns them.
  #
  # @return [Array<Summary>]
  def search(query, count: MAX_RESULTS)
    text = call("search_email_conversations", { "query" => query, "count" => count.clamp(1, MAX_RESULTS) })
    return [] if text.start_with?("No emails found")

    # Records are separated by a `---` line, and each one prints its ids first, ahead of anything
    # the sender wrote — so the first ID and Thread ID lines of a record are the server's own.
    text.split(/^---$/).filter_map do |record|
      id = field(record, "ID")
      thread_id = field(record, "Thread ID")
      next unless id&.match?(ID_FORMAT) && thread_id&.match?(ID_FORMAT)

      Summary.new(id: id, thread_id: thread_id, subject: field(record, "Subject"))
    end.uniq(&:id)
  end

  # One message in full.
  #
  # @return [Message]
  def get_message(id)
    text = call("get_email_conversation", { "email_id" => id })

    # The server prints the ids and the link, then `## Headers`, then `## Body` and, last, an
    # optional `## Attachments (n)`. Headers are read from the part above the body only; the body is
    # everything after the first `## Body`, minus a trailing attachment list.
    head, body = text.split(/^## Body[ \t]*$/, 2)
    raise Error, "get_email_conversation returned no message for #{id}" if head.blank? || field(head, "ID") != id

    body = body.to_s
    attachments = []
    if (at = body.rindex(/^## Attachments \(\d+\)[ \t]*$/))
      attachments = body[at..].lines.drop(1).filter_map { |line| line.strip[/\A\d+\.\s+(.+)\z/, 1] }
      body = body[...at]
    end

    thread_id = field(head, "Thread ID")
    Message.new(
      id: id,
      thread_id: thread_id&.match?(ID_FORMAT) ? thread_id : nil,
      url: field(head, "Gmail URL")&.then { |url| url if url.start_with?("https://mail.google.com/") },
      subject: field(head, "Subject"),
      from: field(head, "From"),
      to: field(head, "To"),
      cc: field(head, "Cc"),
      date: field(head, "Date"),
      # The LAST Labels line above the body: the server prints it after every header the sender
      # wrote, so a Subject that smuggled in a line of its own comes earlier.
      labels: head.scan(/^\*\*Labels:\*\*[ \t]*(.*)$/).last&.first.to_s.split(",").map(&:strip).reject { |label| label.blank? || label == "None" },
      body: body.strip,
      attachments: attachments
    )
  end

  private

  def field(text, name)
    text[/^\*\*#{Regexp.escape(name)}:\*\*[ \t]*(.*)$/, 1]&.strip.presence
  end

  def client
    @client ||= begin
      raise Error, "#{URL_KEY} is not set" unless self.class.configured?

      headers = {}
      token = self.class.token
      headers["Authorization"] = "Bearer #{token}" if token
      McpApps::Client.new(url: self.class.url, headers: headers)
    end
  end

  # A gateway fronting several servers namespaces their tools (`gmail-zimmer-ro__get_email_conversation`),
  # a server reached on its own does not, so the name is looked up rather than assumed.
  def tool_name(name)
    @tool_names ||= client.tools_list.filter_map { |tool| tool["name"] if tool.is_a?(Hash) }
    @tool_names.find { |candidate| candidate == name } ||
      @tool_names.find { |candidate| candidate.end_with?("__#{name}") } ||
      raise(Error, "the mailbox server does not offer #{name}")
  end

  # The text of the tool's answer. A tool error — an unconsented or revoked Google token among
  # them — is raised, with the server's message.
  def call(name, arguments)
    result = client.call_tool(tool_name(name), arguments)
    text = Array(result["content"]).filter_map { |item| item["text"] if item.is_a?(Hash) && item["type"] == "text" }.join("\n")
    raise Error, "#{name} failed: #{text.truncate(300).presence || 'no detail'}" if result["isError"]

    text
  rescue McpApps::Client::Error => e
    raise Error, "#{name}: #{e.message}"
  end
end

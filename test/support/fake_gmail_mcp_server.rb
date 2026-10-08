# frozen_string_literal: true

require "socket"

# A mailbox MCP server for tests, reached over real HTTP through McpApps::Client.
#
# It follows the tool contract of `pulsemcp/mcp-servers/experimental/gmail` (the tree strad vendors
# verbatim for its gmail slugs): the same tool names, served under a gateway's `<slug>__` prefix,
# and the same markdown answers, byte for byte where it matters — `formatEmail` for
# `search_email_conversations` and `formatFullEmail` for `get_email_conversation`. The search
# understands the few Gmail operators EmailTriggerPollerJob writes: `in:inbox`, `-from:me`,
# `after:<unix seconds>`, `-category:<name>`, and a parenthesised group of those.
#
#   server = FakeGmailMcpServer.start
#   server.deliver(id: "18c1", thread_id: "18c1", subject: "Hi", from: "A <a@x.com>", body: "…")
#   EmailService.stubs(:url).returns(server.url)
#   server.stop
class FakeGmailMcpServer
  ACCOUNT = "zimmer@example.com"
  SLUG = "gmail-zimmer-ro"
  TOOLS = %w[list_email_conversations get_email_conversation search_email_conversations download_email_attachments list_draft_emails].freeze

  Mail = Struct.new(:id, :thread_id, :subject, :from, :to, :cc, :date, :labels, :body, :snippet, :received_at, :attachments, keyword_init: true)

  attr_reader :mails, :calls
  attr_accessor :refuse

  def self.start
    new.tap(&:start)
  end

  def initialize
    @mails = []
    @calls = []
    @refuse = nil
    @mutex = Mutex.new
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { loop { serve(@server.accept) } rescue IOError }
    self
  end

  def stop
    @server&.close
    @thread&.join(2)
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}/mcp?servers=#{SLUG}"
  end

  def deliver(id:, thread_id: id, subject: "Hello", from: "Ada <ada@example.org>", to: ACCOUNT, cc: nil,
              labels: %w[INBOX UNREAD CATEGORY_PERSONAL], body: "Hi there.", received_at: Time.current.to_i, attachments: [])
    @mutex.synchronize do
      @mails << Mail.new(id: id, thread_id: thread_id, subject: subject, from: from, to: to, cc: cc,
                         date: Time.zone.at(received_at).rfc2822, labels: labels, body: body,
                         snippet: body.to_s.squish.first(100), received_at: received_at, attachments: attachments)
    end
  end

  private

  def serve(socket)
    request_line = socket.gets.to_s
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = socket.read(headers["content-length"].to_i)
    status, payload = request_line.start_with?("POST") ? dispatch(JSON.parse(body)) : [ 405, nil ]

    text = payload ? JSON.generate(payload) : ""
    reason = { 200 => "OK", 202 => "Accepted", 405 => "Method Not Allowed" }.fetch(status)
    socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
  ensure
    socket.close
  end

  def dispatch(message)
    return [ 202, nil ] unless message.key?("id")

    result = case message["method"]
    when "initialize"
      { "protocolVersion" => "2025-06-18", "capabilities" => { "tools" => {} }, "serverInfo" => { "name" => "fake-gmail", "version" => "0" } }
    when "tools/list"
      { "tools" => TOOLS.map { |name| { "name" => "#{SLUG}__#{name}", "inputSchema" => { "type" => "object" } } } }
    when "tools/call"
      call_tool(message.dig("params", "name").delete_prefix("#{SLUG}__"), message.dig("params", "arguments") || {})
    end
    [ 200, { "jsonrpc" => "2.0", "id" => message["id"], "result" => result } ]
  end

  def call_tool(name, arguments)
    @mutex.synchronize { @calls << [ name, arguments ] }
    return error("Error searching emails: #{refuse}") if refuse

    case name
    when "search_email_conversations" then search(arguments)
    when "get_email_conversation" then get(arguments["email_id"])
    else error("not faked: #{name}")
    end
  end

  def search(arguments)
    query = arguments["query"].to_s
    matching = @mutex.synchronize { @mails.dup }.select { |mail| matches?(mail, query) }
      .sort_by { |mail| -mail.received_at }
      .first(arguments["count"] || 10)
    return text("No emails found matching query: \"#{query}\"") if matching.empty?

    text("Found #{matching.size} email(s) matching \"#{query}\":\n\n#{matching.map { |mail| format_email(mail) }.join("\n\n---\n\n")}")
  end

  def matches?(mail, query)
    terms = query.delete("()").split
    terms.all? do |term|
      case term
      when "in:inbox" then mail.labels.include?("INBOX")
      when "-from:me" then !mail.labels.include?("SENT")
      when /\Aafter:(\d+)\z/ then mail.received_at > $1.to_i
      when /\A-category:(\w+)\z/ then !mail.labels.include?("CATEGORY_#{$1.upcase}")
      else true
      end
    end
  end

  def get(id)
    mail = @mutex.synchronize { @mails.find { |candidate| candidate.id == id } }
    return error("Error retrieving email: Requested entity was not found.") unless mail

    text(format_full_email(mail))
  end

  # formatEmail in upstream's shared/src/utils/email-helpers.ts.
  def format_email(mail)
    "**ID:** #{mail.id}\n**Thread ID:** #{mail.thread_id}\n**Subject:** #{mail.subject}\n**From:** #{mail.from}\n" \
      "**Date:** #{mail.date}\n**Preview:** #{mail.snippet}\n**Gmail URL:** #{gmail_url(mail)}"
  end

  # formatFullEmail in upstream's shared/src/tools/get-email-conversation.ts.
  def format_full_email(mail)
    output = +"# Email Details\n\n**ID:** #{mail.id}\n**Thread ID:** #{mail.thread_id}\n**Gmail URL:** #{gmail_url(mail)}"
    output << "\n\n## Headers\n**Subject:** #{mail.subject}\n**From:** #{mail.from}\n**To:** #{mail.to}"
    output << "\n**Cc:** #{mail.cc}" if mail.cc
    output << "\n**Date:** #{mail.date}\n**Labels:** #{mail.labels.join(', ').presence || 'None'}\n\n## Body\n\n#{mail.body}"
    if mail.attachments.any?
      output << "\n\n## Attachments (#{mail.attachments.size})\n"
      mail.attachments.each_with_index { |name, index| output << "#{index + 1}. #{name} (application/pdf, 12 KB)\n" }
    end
    output
  end

  def gmail_url(mail)
    "https://mail.google.com/mail/?authuser=#{ACCOUNT}#all/#{mail.id}"
  end

  def text(value)
    { "content" => [ { "type" => "text", "text" => value } ] }
  end

  def error(value)
    text(value).merge("isError" => true)
  end
end

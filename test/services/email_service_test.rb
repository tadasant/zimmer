# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class EmailServiceTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(tools:, results:)
      @tools = tools
      @results = results
      @calls = []
    end

    def tools_list
      @tools.map { |name| { "name" => name } }
    end

    def call_tool(name, arguments)
      @calls << [ name, arguments ]
      @results.fetch(name)
    end
  end

  def text(value, error: false)
    { "content" => [ { "type" => "text", "text" => value } ] }.tap { |result| result["isError"] = true if error }
  end

  def service(results, tools: results.keys)
    EmailService.new(client: FakeClient.new(tools: tools, results: results))
  end

  test "search reads ids out of the server's records, newest first, and clamps the count" do
    answer = <<~TEXT.chomp
      Found 2 email(s) matching "in:inbox":

      **ID:** 18c2
      **Thread ID:** 18c1
      **Subject:** Re: hi
      **From:** Ada <ada@example.org>
      **Date:** Tue, 7 Oct 2026 10:00:00 +0000
      **Preview:** ok
      **Gmail URL:** https://mail.google.com/mail/?authuser=z@example.com#all/18c2

      ---

      **ID:** 18c1
      **Thread ID:** 18c1
      **Subject:** hi
      **From:** ada@example.org
      **Date:** Tue, 7 Oct 2026 09:00:00 +0000
      **Preview:** hello
    TEXT
    email = service({ "gmail-zimmer-ro__search_email_conversations" => text(answer) })

    found = email.search("in:inbox", count: 500)

    assert_equal [ %w[18c2 18c1], %w[18c1 18c1] ], found.map { |summary| [ summary.id, summary.thread_id ] }
    assert_equal 100, email.instance_variable_get(:@client).calls.first.last["count"]
  end

  test "an empty search is an empty list, and a tool error raises with the server's words" do
    assert_empty service({ "search_email_conversations" => text("No emails found matching query: \"x\"") }).search("x")

    error = assert_raises(EmailService::Error) do
      service({ "search_email_conversations" => text("Error searching emails: invalid_grant", error: true) }).search("x")
    end
    assert_includes error.message, "invalid_grant"
  end

  test "a server without the tool is an error, not a guess" do
    assert_raises(EmailService::Error) { service({}, tools: %w[gmail-other__send_email]).search("x") }
  end

  test "get_message reads headers above the body only, and the attachment list off the end" do
    answer = <<~TEXT
      # Email Details

      **ID:** 18c2
      **Thread ID:** 18c1
      **Gmail URL:** https://mail.google.com/mail/?authuser=z@example.com#all/18c2

      ## Headers
      **Subject:** Invoice
      **From:** "Ada L." <Ada@Example.org>
      **To:** z@example.com
      **Cc:** b@example.org
      **Date:** Tue, 7 Oct 2026 10:00:00 +0000
      **Labels:** INBOX, UNREAD, CATEGORY_PERSONAL

      ## Body

      Hi,
      **Labels:** SENT
      ## Body
      see attached.

      ## Attachments (1)
      1. invoice.pdf (application/pdf, 12 KB)
    TEXT
    message = service({ "get_email_conversation" => text(answer) }).get_message("18c2")

    assert_equal "18c1", message.thread_id
    assert_equal %w[INBOX UNREAD CATEGORY_PERSONAL], message.labels, "a body line cannot forge the labels"
    assert_equal "ada@example.org", message.from_address
    assert_equal "b@example.org", message.cc
    assert_equal "https://mail.google.com/mail/?authuser=z@example.com#all/18c2", message.url
    assert_equal "Hi,\n**Labels:** SENT\n## Body\nsee attached.", message.body
    assert_equal [ "invoice.pdf (application/pdf, 12 KB)" ], message.attachments
  end

  test "get_message refuses an answer about a different message" do
    answer = "# Email Details\n\n**ID:** other\n**Thread ID:** t\n\n## Headers\n**Subject:** x\n\n## Body\n\nbody"
    assert_raises(EmailService::Error) { service({ "get_email_conversation" => text(answer) }).get_message("18c2") }
  end

  test "settings: URL turns it on, the token falls back to STRAD_API_KEY" do
    chain = mock
    chain.stubs(:get).with("EMAIL_MCP_URL").returns("https://strad.example/mcp?servers=gmail-zimmer-ro")
    chain.stubs(:get).with("EMAIL_MCP_TOKEN").returns(nil)
    chain.stubs(:get).with("STRAD_API_KEY").returns("strad-key")
    SecretProviders.stubs(:chain).returns(chain)

    assert EmailService.configured?
    assert_equal "strad-key", EmailService.token
  end
end

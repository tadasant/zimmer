# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpApps::FragmentTest < ActiveSupport::TestCase
  include McpAppsSettingsHelpers

  HTML = "<!DOCTYPE html><html><body>hi</body></html>"

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @session = Session.create!(
      agent_runtime: "claude_code", prompt: "x", mcp_servers: [ "notion" ],
      git_root: "https://github.com/test/repo.git", branch: "main"
    )
    enable_mcp_apps

    @client = mock("client")
    @connection = McpApps::ServerConnection.new(@session, "notion")
    @connection.stubs(:client).returns(@client)
  end

  teardown do
    Rails.cache = @original_cache
  end

  def contents(text: HTML, mime: "text/html;profile=mcp-app", meta: nil)
    entry = { "uri" => "ui://demo/panel.html", "mimeType" => mime, "text" => text }
    entry["_meta"] = meta if meta
    { "contents" => [ entry ] }
  end

  test "reads a view and carries the CSP the content block declared" do
    @client.expects(:resources_read).with("ui://demo/panel.html")
      .returns(contents(meta: { "ui" => { "csp" => { "connectDomains" => [ "https://api.example.com" ] } } }))

    fragment = McpApps::Fragment.for(@connection, "ui://demo/panel.html")

    assert_equal HTML, fragment.html
    assert_equal({ "connectDomains" => [ "https://api.example.com" ] }, fragment.csp)
    assert_includes fragment.content_security_policy.header_value, "connect-src https://api.example.com"
  end

  test "falls back to the resources/list entry when the content block carries no metadata" do
    @client.expects(:resources_read).returns(contents)
    @client.expects(:resources_list).returns([
      { "uri" => "ui://other/thing", "_meta" => { "ui" => { "csp" => { "connectDomains" => [ "https://wrong.example" ] } } } },
      { "uri" => "ui://demo/panel.html",
        "_meta" => { "io.modelcontextprotocol/ui" => { "csp" => { "resourceDomains" => [ "https://cdn.example.com" ] } } } }
    ])

    fragment = McpApps::Fragment.for(@connection, "ui://demo/panel.html")

    assert_includes fragment.content_security_policy.header_value, "https://cdn.example.com"
    refute_includes fragment.content_security_policy.header_value, "wrong.example"
  end

  test "a server that declares nothing anywhere gets the restrictive default" do
    @client.expects(:resources_read).returns(contents)
    @client.expects(:resources_list).returns([])

    header = McpApps::Fragment.for(@connection, "ui://demo/panel.html").content_security_policy.header_value

    assert_includes header, "default-src 'none'"
    assert_includes header, "connect-src 'none'"
  end

  test "only a ui:// resource is readable" do
    @client.expects(:resources_read).never

    [ "https://evil.example/x.html", "file:///etc/passwd", "", nil ].each do |uri|
      assert_raises(McpApps::Fragment::UnavailableError) { McpApps::Fragment.for(@connection, uri) }
    end
  end

  test "a resource that is not html is refused rather than framed anyway" do
    @client.expects(:resources_read).returns(contents(mime: "application/pdf"))

    error = assert_raises(McpApps::Fragment::UnavailableError) do
      McpApps::Fragment.for(@connection, "ui://demo/panel.html")
    end
    assert_match "not text/html", error.message
  end

  test "a view larger than the cap is refused" do
    @client.expects(:resources_read).returns(contents(text: "x" * (McpApps::Fragment::MAX_HTML_BYTES + 1)))

    assert_raises(McpApps::Fragment::UnavailableError) { McpApps::Fragment.for(@connection, "ui://demo/panel.html") }
  end

  test "a content block with no text at all is refused" do
    @client.expects(:resources_read).returns({ "contents" => [ { "uri" => "ui://demo/panel.html", "blob" => "abc" } ] })

    assert_raises(McpApps::Fragment::UnavailableError) { McpApps::Fragment.for(@connection, "ui://demo/panel.html") }
  end

  test "a transport failure surfaces as UnavailableError rather than a Client error" do
    @client.expects(:resources_read).raises(McpApps::Client::Error, "could not reach MCP server")

    assert_raises(McpApps::Fragment::UnavailableError) { McpApps::Fragment.for(@connection, "ui://demo/panel.html") }
  end

  test "the read is cached, so a second panel on the same page costs nothing" do
    @client.expects(:resources_read).once.returns(contents(meta: { "ui" => { "csp" => {} } }))

    2.times { McpApps::Fragment.for(@connection, "ui://demo/panel.html") }
  end

  test "repointing a server at another host does not serve the old host's view" do
    @client.expects(:resources_read).twice.returns(contents(meta: { "ui" => { "csp" => {} } }))

    McpApps::Fragment.for(@connection, "ui://demo/panel.html")

    moved = McpApps::ServerConnection.new(@session, "notion")
    moved.stubs(:client).returns(@client)
    moved.stubs(:server).returns(stub(url: "https://somewhere-else.example/mcp", type: "streamable-http"))

    McpApps::Fragment.for(moved, "ui://demo/panel.html")
  end
end

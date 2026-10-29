# frozen_string_literal: true

# Puts a `slack-zimmer` streamable-http server into the MCP catalog for a test, pointing at a
# FakeEventsMcpServer — the rest of the catalog is left as it is, so everything else that reads it
# still resolves.
module McpEventCatalogHelper
  def stub_events_catalog_server(url, name: FakeEventsMcpServer::SLUG)
    fake = ServersConfig::Server.new(name, { "title" => "Slack (fake)", "type" => "streamable-http", "url" => url, "headers" => {} })
    real = Array(ServersConfig.all).reject { |server| server.name == name }
    ServersConfig.stubs(:all).returns(real + [ fake ])
    fake
  end
end

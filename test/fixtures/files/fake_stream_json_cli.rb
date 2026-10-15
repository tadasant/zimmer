# frozen_string_literal: true

# A stand-in for `claude -p --input-format stream-json` in WarmProcessPool tests:
# a real child process that answers control requests on stdout and records every
# line it is sent, in order, to the file named by its first argument. It exits on
# stdin EOF, as the CLI does. FAKE_CLI_REFUSE names a control subtype to answer
# with an error, FAKE_CLI_SET_SERVERS_ERROR makes `mcp_set_servers` report a
# failed server, and FAKE_CLI_MCP_STATUS sets every server's status.
require "json"

received = File.open(ARGV.fetch(0), "a")
received.sync = true
$stdout.sync = true

$stdin.each_line do |line|
  received.write(line)
  message = JSON.parse(line)
  next unless message["type"] == "control_request"

  subtype = message.dig("request", "subtype")
  response = if subtype == ENV["FAKE_CLI_REFUSE"]
    { subtype: "error", request_id: message["request_id"], error: "refused by the fake" }
  else
    body = case subtype
    when "mcp_status"
      { mcpServers: [ { name: "zimmer", status: ENV.fetch("FAKE_CLI_MCP_STATUS", "connected") } ] }
    when "mcp_set_servers"
      errors = ENV["FAKE_CLI_SET_SERVERS_ERROR"] ? { "zimmer" => "connect failed" } : {}
      { added: message.dig("request", "servers").keys, removed: [], errors: errors }
    else
      {}
    end
    { subtype: "success", request_id: message["request_id"], response: body }
  end
  puts({ type: "control_response", response: response }.to_json)
end

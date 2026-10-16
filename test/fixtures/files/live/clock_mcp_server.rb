# frozen_string_literal: true

# A minimal stdio MCP server for the live-conversation tests: newline-delimited
# JSON-RPC, two tools. `env_names` reports the NAMES of the variables it was
# started with, which is how the tests prove the Rails environment is scrubbed.
require "json"
$stdout.sync = true

TOOLS = [
  { name: "current_time", description: "The current time.", inputSchema: { type: "object", properties: {} } },
  { name: "env_names", description: "Environment variable names.", inputSchema: { type: "object", properties: {} } }
].freeze

$stdin.each_line do |line|
  message = JSON.parse(line)
  next unless message["id"]

  result = case message["method"]
  when "initialize"
    { protocolVersion: message.dig("params", "protocolVersion"), capabilities: { tools: {} }, serverInfo: { name: "clock", version: "1" } }
  when "tools/list" then { tools: TOOLS }
  when "tools/call"
    case message.dig("params", "name")
    when "current_time" then { content: [ { type: "text", text: "It is noon. #{ENV['CLOCK_GREETING']}" } ] }
    when "env_names" then { content: [ { type: "text", text: ENV.keys.sort.join(",") } ] }
    else { content: [ { type: "text", text: "no such tool" } ], isError: true }
    end
  else {}
  end
  puts JSON.generate(jsonrpc: "2.0", id: message["id"], result: result)
end

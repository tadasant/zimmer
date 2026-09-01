# frozen_string_literal: true

# The `.mcp.json` file format, as RuntimeConfigPostProcessor's format hooks.
#
# `.mcp.json` — a JSON object with an `mcpServers` map — is not Claude Code's
# private format. It is the de-facto cross-vendor convention, and the Pi MCP
# adapter reads exactly the same file from exactly the same place (its own README
# calls `.mcp.json` the "preferred project config"). Two runtimes needing byte-
# identical parse/serialize behavior is what this module is for: the hooks live
# here once, and each processor supplies only what is genuinely its own.
#
# What is NOT here is the interesting part of either processor — Claude's is the
# whole of its behavior, while Pi additionally has to SEED the file, because
# `air prepare pi` writes no MCP config at all (see PiMcpConfigPostProcessor).
module McpJsonConfigFormat
  MCP_CONFIG_FILENAME = ".mcp.json"
  SERVERS_KEY = "mcpServers"

  private

  def config_path
    File.join(working_directory, MCP_CONFIG_FILENAME)
  end

  def parse_config(raw)
    JSON.parse(raw)
  end

  def empty_config
    { SERVERS_KEY => {} }
  end

  def servers_map(config)
    config[SERVERS_KEY] ||= {}
  end

  def serialize_config(config)
    JSON.pretty_generate(config)
  end

  def http_headers_key
    "headers"
  end

  # Both runtimes key off the explicit `type` to pick a transport; an entry with
  # a url but no type is treated as stdio and fails on the missing command.
  def build_http_entry(url:, headers:)
    { "type" => "http", "url" => url, http_headers_key => headers.dup }
  end

  # JSON has no host-env forwarding tables (that is a Codex TOML concern), so
  # every `${VAR}` is resolved in place on the entry itself.
  def resolve_secrets!(servers)
    servers.each_value do |entry|
      secrets_interpolator.resolve_entry!(entry)
    end
  end
end

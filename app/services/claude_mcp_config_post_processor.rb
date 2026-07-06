# frozen_string_literal: true

# Post-processes the `.mcp.json` file that AIR writes when preparing a Claude
# Code session. Implements RuntimeConfigPostProcessor's format hooks against
# Claude's JSON `mcpServers` object; the shared injection/retarget orchestration
# lives in the base class.
class ClaudeMcpConfigPostProcessor < RuntimeConfigPostProcessor
  MCP_CONFIG_FILENAME = ".mcp.json"

  private

  def config_path
    File.join(working_directory, MCP_CONFIG_FILENAME)
  end

  def parse_config(raw)
    JSON.parse(raw)
  end

  def empty_config
    { "mcpServers" => {} }
  end

  def servers_map(config)
    config["mcpServers"] ||= {}
  end

  def serialize_config(config)
    JSON.pretty_generate(config)
  end

  def build_server_entry(catalog_server)
    if catalog_server.stdio?
      { "command" => catalog_server.command, "args" => catalog_server.args.dup, "env" => catalog_server.env.dup }
    else
      { "url" => catalog_server.url, "headers" => catalog_server.headers.dup }
    end
  end

  def resolve_and_rewrite!(servers)
    servers.each_value do |entry|
      secrets_interpolator.resolve_entry!(entry)
      NpxPrefixRewriter.rewrite!(entry)
    end
  end
end

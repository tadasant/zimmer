# frozen_string_literal: true

# Post-processes the `.codex/config.toml` file that AIR writes when preparing an
# OpenAI Codex CLI session. Implements RuntimeConfigPostProcessor's format hooks
# against Codex's `[mcp_servers.*]` tables; the shared injection/retarget
# orchestration lives in the base class.
#
# Codex's MCP server schema (see @pulsemcp/air-adapter-codex):
#   stdio → { command, args, env, env_vars }
#   http  → { url, http_headers, env_http_headers }
#
# `env`/`http_headers` are literal tables; `env_vars` (array) and
# `env_http_headers` (table of Header => host-var-name) are Codex's native
# host-env forwarding — Codex injects the host process's matching variable at
# launch. AIR translates same-named whole-value refs (`env: { VAR: "${VAR}" }`)
# into that forwarding form during `air prepare`.
#
# The Codex-specific concern: AO's secrets live in Rails encrypted credentials
# (SecretsLoader), NOT in the host process env the Codex CLI inherits. So a
# forwarded var that AO resolves would never reach the server. This processor
# moves every SecretsLoader-backed var OUT of the forwarding fields and INTO the
# literal `env`/`http_headers` tables with the resolved value. Forwarded vars AO
# can't resolve are left in place — those are genuine host-env vars Codex
# forwards at launch.
class CodexConfigTomlPostProcessor < RuntimeConfigPostProcessor
  CONFIG_RELATIVE_PATH = File.join(".codex", "config.toml")
  MCP_SERVERS_KEY = "mcp_servers"

  private

  def config_path
    File.join(working_directory, CONFIG_RELATIVE_PATH)
  end

  def parse_config(raw)
    TomlRB.parse(raw)
  end

  def empty_config
    { MCP_SERVERS_KEY => {} }
  end

  def servers_map(config)
    config[MCP_SERVERS_KEY] ||= {}
  end

  def serialize_config(config)
    TomlRB.dump(config)
  end

  def build_server_entry(catalog_server)
    if catalog_server.stdio?
      { "command" => catalog_server.command, "args" => catalog_server.args.dup, "env" => catalog_server.env.dup }
    else
      { "url" => catalog_server.url, "http_headers" => catalog_server.headers.dup }
    end
  end

  def resolve_and_rewrite!(servers)
    servers.each_value do |entry|
      next unless entry.is_a?(Hash)

      inline_forwarded_secrets!(entry)
      # resolve_entry! handles the literal `env` table, `args`, and `url`. Codex
      # keeps literal HTTP headers under `http_headers` (not `headers`), so
      # resolve those explicitly for any renamed/partial refs AIR left literal.
      secrets_interpolator.resolve_entry!(entry)
      secrets_interpolator.resolve_hash_values!(entry["http_headers"]) if entry["http_headers"].is_a?(Hash)
      NpxPrefixRewriter.rewrite!(entry)
    end
  end

  # Move every SecretsLoader-resolvable var out of Codex's host-env forwarding
  # fields and into the literal tables with the resolved value, since the Codex
  # process's host env does not carry AO's encrypted-credential secrets.
  def inline_forwarded_secrets!(entry)
    inline_forwarded_env_vars!(entry)
    inline_forwarded_env_http_headers!(entry)
  end

  # env_vars = ["VAR", ...] → env = { "VAR" => resolved } for SecretsLoader vars.
  def inline_forwarded_env_vars!(entry)
    forwarded = entry["env_vars"]
    return unless forwarded.is_a?(Array)

    remaining = forwarded.reject do |var|
      next false unless var.is_a?(String) && SecretsLoader.exists?(var)
      (entry["env"] ||= {})[var] = SecretsLoader.get(var)
      true
    end

    if remaining.empty?
      entry.delete("env_vars")
    else
      entry["env_vars"] = remaining
    end
  end

  # env_http_headers = { Header => "VAR" } → http_headers = { Header => resolved }
  # for SecretsLoader vars.
  def inline_forwarded_env_http_headers!(entry)
    forwarded = entry["env_http_headers"]
    return unless forwarded.is_a?(Hash)

    remaining = {}
    forwarded.each do |header, var|
      if var.is_a?(String) && SecretsLoader.exists?(var)
        (entry["http_headers"] ||= {})[header] = SecretsLoader.get(var)
      else
        remaining[header] = var
      end
    end

    if remaining.empty?
      entry.delete("env_http_headers")
    else
      entry["env_http_headers"] = remaining
    end
  end
end

# frozen_string_literal: true

# Resolves ${VAR} and ${VAR:-default} interpolations inside an MCP server
# entry, sourcing values from SecretsLoader (Rails encrypted credentials) first,
# then process ENV.
#
# This is a runtime-agnostic helper: it operates on the `command`/`args`/`env`/
# `headers`/`url` shape that both Claude's `.mcp.json` and Codex's
# `.codex/config.toml` `[mcp_servers.*]` tables share. The per-runtime config
# post-processor (ClaudeMcpConfigPostProcessor, CodexConfigTomlPostProcessor)
# calls into this after deserializing its native config format.
#
# AIR's own @pulsemcp/air-secrets-env transform already resolves ${VAR} from
# process.env during `air prepare`. Zimmer post-processes a second time because its
# secrets live in Rails encrypted credentials (SecretsLoader), which are NOT in
# process.env.
class SecretsInterpolator
  # Raised when a ${VAR} pattern has no resolvable value and no default.
  class MissingVariableError < StandardError; end

  # Environment variable interpolation pattern: ${VAR} or ${VAR:-default}
  ENV_VAR_PATTERN = /\$\{([A-Z_][A-Z0-9_]*)(?::-([^}]*))?\}/

  # Resolve interpolations in every string value of a server entry: its env and
  # headers hashes, its args array, and its url. Mutates the entry in place.
  def resolve_entry!(entry)
    resolve_hash_values!(entry.fetch("env", {}))
    resolve_hash_values!(entry.fetch("headers", {}))

    if entry["args"].is_a?(Array)
      entry["args"] = entry["args"].map { |arg| arg.is_a?(String) ? resolve(arg) : arg }
    end

    entry["url"] = resolve(entry["url"]) if entry["url"].is_a?(String)
  end

  # Resolve interpolations in every string value of a hash, mutating in place.
  # A value that resolves to blank (and wasn't an explicit empty string) is
  # dropped so downstream consumers don't see a key with a meaningless value.
  def resolve_hash_values!(hash)
    hash.each do |key, value|
      next unless value.is_a?(String)
      resolved = resolve(value)
      if resolved.present? || value == ""
        hash[key] = resolved
      else
        hash.delete(key)
      end
    end
  end

  # Resolve ${VAR} / ${VAR:-default} patterns in a single string.
  # Checks SecretsLoader first, then ENV. Raises on required vars that are missing.
  def resolve(str)
    return str unless str.is_a?(String) && str.match?(ENV_VAR_PATTERN)

    str.gsub(ENV_VAR_PATTERN) do
      var_name = Regexp.last_match(1)
      default_value = Regexp.last_match(2)

      value = get_env_value(var_name)

      if value.present?
        value
      elsif default_value
        default_value
      else
        raise MissingVariableError, "Required environment variable '#{var_name}' not set"
      end
    end
  end

  # Look up a variable from SecretsLoader (encrypted credentials), falling back
  # to process ENV. Returns nil when neither source defines it.
  def get_env_value(var_name)
    if SecretsLoader.exists?(var_name)
      SecretsLoader.get(var_name)
    elsif ENV.key?(var_name)
      ENV[var_name]
    end
  end
end

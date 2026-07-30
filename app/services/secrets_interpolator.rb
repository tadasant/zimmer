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

  # Where a variable stands, without handing the caller its value.
  #
  # Precisely what this avoids: it never RETURNS a secret, and it never MINTS or
  # refreshes an X access token as a side effect of rendering a page. It does not
  # promise that no value is read anywhere — the Parameter Store link resolves a
  # whole namespace into its snapshot, because that is the grain the store reads
  # at. What it guarantees is that the value stops at the provider.
  #
  # Three outcomes, kept distinct on purpose. "Not set" and "I could not reach
  # the store to find out" are different things to put in front of a person, and
  # reporting the second as the first sends someone off to set a secret that is
  # already there.
  Resolution = Struct.new(:state, :source, :error, keyword_init: true) do
    def found? = state == :found
    def absent? = state == :absent
    def unavailable? = state == :unavailable

    # Human name of the provider holding it, e.g. "Zimmer's Google Parameter Store".
    def source_label = source.respond_to?(:label) ? source.label : source.to_s

    # Short, fixed badge naming the provider that ACTUALLY resolved the value —
    # not what configuration declares. The three provider strings are shared with
    # strad's Secrets Console so the two lists can be compared by eye.
    def source_badge
      return source.badge if source.respond_to?(:badge)
      return "Unknown" if unavailable?

      "Unresolved"
    end

    def source_badge_title
      return source.badge_title if source.respond_to?(:badge_title)
      return "The secret store did not answer, so this could not be determined" if unavailable?

      "No provider holds this variable"
    end
  end

  # @param var_name [String]
  # @return [Resolution]
  def resolution(var_name)
    return Resolution.new(state: :found, source: X_OAUTH_SOURCE) if XOauthTokenVendor.configured?(var_name)

    provider = SecretProviders.chain.provider_for(var_name)
    return Resolution.new(state: :found, source: provider) if provider

    Resolution.new(state: :absent)
  rescue ParameterStore::StoreError, ParameterStore::AuthError => e
    Resolution.new(state: :unavailable, error: e)
  end

  # True when a variable has a value in any source.
  # @param var_name [String]
  # @return [Boolean]
  def resolvable?(var_name)
    resolution(var_name).found?
  end

  # Look up a variable, in priority order:
  #   1. XOauthTokenVendor — a runtime-writable, self-refreshing token store for
  #      X (Twitter) access tokens. Consulted first because these tokens rotate
  #      at runtime and must reflect the freshest minted value, not a static
  #      git-committed one. The vendor cheaply returns nil for any non-X var.
  #   2. SecretProviders.chain — the Parameter Store (when configured), then
  #      Rails encrypted credentials, then process ENV. See SecretProviders for
  #      why the store goes first and why a store outage raises rather than
  #      falling through.
  # Returns nil when no source defines it.
  def get_env_value(var_name)
    dynamic = XOauthTokenVendor.resolve(var_name)
    return dynamic if dynamic.present?

    SecretProviders.chain.get(var_name)
  end

  # The one source that is not a chain provider. Given the same badge surface as
  # the providers so callers never special-case it.
  X_OAUTH_SOURCE = Struct.new(:label, :badge, :badge_title).new(
    "Zimmer's X OAuth token store", "X OAuth", "Minted by Zimmer's X OAuth token store"
  ).freeze
end

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
# The Codex-specific concern: Zimmer's secrets live in Rails encrypted credentials
# (SecretsLoader), NOT in the host process env the Codex CLI inherits. So a
# forwarded var that Zimmer resolves would never reach the server. This processor
# moves every SecretsLoader-backed var OUT of the forwarding fields and INTO the
# literal `env`/`http_headers` tables with the resolved value. Forwarded vars Zimmer
# can't resolve are left in place — those are genuine host-env vars Codex
# forwards at launch.
class CodexConfigTomlPostProcessor < RuntimeConfigPostProcessor
  CONFIG_RELATIVE_PATH = File.join(".codex", "config.toml")
  MCP_SERVERS_KEY = "mcp_servers"

  # Host env var naming the operator SSH key file, forwarded to every stdio server
  # (see forward_operator_ssh_key!). Not a secret — a path.
  OPERATOR_SSH_KEY_PATH_VAR = "SSH_PRIVATE_KEY_PATH"

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

  def http_headers_key
    "http_headers"
  end

  # Codex infers the transport from the presence of `url` (vs `command`), so no
  # type discriminator is written.
  def build_http_entry(url:, headers:)
    { "url" => url, http_headers_key => headers.dup }
  end

  # AIR converts a whole-value ${VAR} header ref into an env_http_headers
  # forwarding rule, which inline_forwarded_env_http_headers! later resolves into
  # http_headers. For a retargeted Zimmer entry that rule still names the
  # catalog's (production) key, so it must go or it would clobber the retargeted
  # value.
  def drop_forwarded_credential_header!(entry, header)
    forwarded = entry["env_http_headers"]
    return unless forwarded.is_a?(Hash)

    forwarded.delete(header)
    entry.delete("env_http_headers") if forwarded.empty?
  end

  def resolve_and_rewrite!(servers)
    servers.each_value do |entry|
      next unless entry.is_a?(Hash)

      forward_operator_ssh_key!(entry)
      inline_forwarded_secrets!(entry)
      # resolve_entry! handles the literal `env` table, `args`, and `url`. Codex
      # keeps literal HTTP headers under `http_headers` (not `headers`), so
      # resolve those explicitly for any renamed/partial refs AIR left literal.
      secrets_interpolator.resolve_entry!(entry)
      secrets_interpolator.resolve_hash_values!(entry["http_headers"]) if entry["http_headers"].is_a?(Hash)
      NpxPrefixRewriter.rewrite!(entry)
    end
  end

  # Ask Codex to forward SSH_PRIVATE_KEY_PATH — the path of the operator SSH key
  # (OperatorSshKeyProvisioner) — to every stdio MCP server.
  #
  # Claude Code hands a stdio MCP server its own environment, so exporting the variable
  # in the spawn env (CliSpawnEnv#apply_operator_ssh_key) is enough there. Codex does
  # NOT: it builds each server's environment from a fixed whitelist (HOME, PATH, LANG,
  # …) plus exactly the variables the entry names in `env_vars`. SSH_PRIVATE_KEY_PATH is
  # in neither, so without this an `ssh-*` server under a Codex session sees no key and
  # fails its health check — the very bug the provisioner exists to fix, half-fixed.
  #
  # Only stdio servers have an environment at all (an HTTP entry has `url`, not
  # `command`), and only when a key was actually provisioned — a deployment with no
  # operator key configured gets no forwarding line pointing at a file that isn't there.
  # The value is a path, never key material.
  def forward_operator_ssh_key!(entry)
    return if entry["command"].blank?
    return unless operator_ssh_key?

    forwarded = entry["env_vars"]
    forwarded = [] unless forwarded.is_a?(Array)
    entry["env_vars"] = forwarded | [ OPERATOR_SSH_KEY_PATH_VAR ]
  end

  # Memoized across the entries of one post_process! run (the provisioner is idempotent
  # but touches the filesystem, and a session can attach many servers).
  def operator_ssh_key?
    return @operator_ssh_key if defined?(@operator_ssh_key)

    @operator_ssh_key = OperatorSshKeyProvisioner.ensure!.present?
  end

  # Move every SecretsLoader-resolvable var out of Codex's host-env forwarding
  # fields and into the literal tables with the resolved value, since the Codex
  # process's host env does not carry Zimmer's encrypted-credential secrets.
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

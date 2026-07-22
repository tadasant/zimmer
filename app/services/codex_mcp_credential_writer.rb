# frozen_string_literal: true

# Writes resolved MCP OAuth credentials into the store the OpenAI Codex CLI
# reads, so MCP servers configured for a Codex-runtime session authenticate the
# same way they do for Claude Code. This is the Codex implementation of the
# RuntimeMcpCredentialWriter contract (see #3782); the OAuth machinery that
# produces ResolvedMcpCredential objects stays runtime-agnostic.
#
# == Codex bug workarounds (remove when fixed upstream) ==
#
# Zimmer writes Codex's credential store DIRECTLY from McpOauthCredential on every
# session spawn (and refreshes tokens every 30 min via RefreshMcpOauthTokensJob),
# rather than trusting the Codex CLI's own `codex mcp login` persistence or its
# token auto-refresh. This works around two open Codex bugs:
#
#   * openai/codex#15122 — credentials written by `codex mcp login` don't reliably
#     persist / read back across restarts. Zimmer never relies on Codex's own login
#     persistence: it writes the file itself before each spawn.
#   * openai/codex#17265 — Codex doesn't use the stored refresh_token to refresh an
#     expired access_token, so MCP calls fail with "Authorization required". Zimmer
#     refreshes tokens itself and writes fresh ones at every session start, so the
#     access_token Codex reads is always current and Codex never has to refresh.
#
# When both issues are fixed upstream, this "rewrite on every spawn" behavior can
# be relaxed — Codex's own login/refresh would suffice.
#
# == Schema of ~/.codex/.credentials.json ==
#
# Top-level JSON object keyed by "<server_name>|<hash>" (see #credential_key_for).
# Each value is a FLAT token entry with snake_case keys:
#
#   {
#     "asana|3f9a1c4b7e2d8f06": {
#       "server_name": "asana",
#       "server_url": "https://mcp.asana.com/sse",
#       "client_id": "codex_dyn_client_abc123",
#       "access_token": "eyJhbGci...",
#       "expires_at": 1764547200000,        // unix epoch MILLISECONDS, optional
#       "refresh_token": "rt_9f8e7d6c5b4a",  // optional
#       "scopes": ["openid", "profile"]      // array of strings (default [])
#     }
#   }
#
# Note `server_url` (not `url`) and the plural `scopes` ARRAY — this differs from
# the macOS Keychain blob below. expires_at is milliseconds since epoch, not
# ISO8601. token_type is not stored (Codex defaults to Bearer on load).
#
# Verified against codex-rs/rmcp-client/src/oauth.rs @ rust-v0.133.0 and at
# runtime: writing this file and running `codex mcp list` flips the server's Auth
# column from "Unsupported" to "OAuth".
#
# == macOS Keychain ==
#
# Codex's mcp_oauth_credentials_store defaults to "auto": keyring if available
# (macOS), else the file. On a macOS worker with the default, Codex reads the
# Keychain FIRST, so the file alone would be missed. This writer therefore also
# writes the Keychain on macOS. The Keychain item is service "Codex MCP
# Credentials", account "<server_name>|<hash>" (one item per server), and its
# value is the RAW (unencoded — Codex does not hex-encode like Claude Code does)
# JSON of Codex's in-memory StoredOAuthTokens struct, whose shape DIFFERS from
# the file entry: the URL field is `url`, and the tokens nest under
# `token_response` with a space-delimited `scope` string and lowercase
# token_type "bearer":
#
#   {"server_name":"asana","url":"https://mcp.asana.com/sse","client_id":"...",
#    "token_response":{"access_token":"...","token_type":"bearer",
#                      "refresh_token":"...","scope":"openid profile"},
#    "expires_at":1764547200000}
#
# Keychain format verified against codex-rs/rmcp-client/src/oauth.rs and the
# oauth2 5.0.0 StandardTokenResponse serialization @ rust-v0.133.0 (source-read;
# not runtime-verified, as Zimmer's CI/staging/production workers are all Linux where
# the file store is used). expires_in is intentionally omitted from token_response
# — Codex makes refresh decisions from the top-level expires_at (millis), so the
# original grant duration is not needed once persisted.
class CodexMcpCredentialWriter
  include RuntimeMcpCredentialWriter

  # Resolved through the shared CodexHome resolver so MCP credentials land in the
  # same CODEX_HOME the rest of Zimmer (and the Codex CLI) uses.
  CODEX_CREDENTIALS_PATH = File.join(CodexHome.path, ".credentials.json").freeze
  KEYCHAIN_SERVICE_NAME = "Codex MCP Credentials".freeze

  # Persists the resolved credentials to Codex's credential store. On macOS,
  # writes both the Keychain (one item per server, primary under the default
  # "auto" store) and the file. On Linux, writes the file only. Credentials go to
  # ~/.codex regardless of the working directory, so working_directory is accepted
  # for the interface but unused here.
  #
  # @param working_directory [String] the session clone (unused by Codex)
  # @param credentials [Array<ResolvedMcpCredential>]
  # @return [String, nil] path to the credentials file, or nil if none written
  def write!(working_directory:, credentials:)
    return nil if credentials.blank?

    codex_credentials = credentials.each_with_object({}) do |credential, hash|
      hash[credential.credential_key] = codex_file_entry(credential)
    end

    write_credentials_to_keychain(credentials) if macos?
    write_credentials_to_file(codex_credentials)
  end

  # No-op: Codex has no negative auth cache. Claude Code suppresses a server for
  # every later connection once it records an auth failure (see
  # ClaudeMcpCredentialWriter#needs_auth_cache_path), so a freshly-injected token
  # there is invisible until the entry is cleared. Codex re-reads its credential
  # store on every connection attempt, so writing the token is sufficient.
  # (Claude's cache lives at ClaudeMcpCredentialWriter#needs_auth_cache_path.)
  #
  # @param server_names [Array<String>]
  # @return [Array<String>] always empty — nothing to clear
  def clear_needs_auth_cache(server_names)
    []
  end

  # Codex keys each MCP OAuth entry by "<server_name>|<hash>" where hash is the
  # first 16 hex chars of SHA256 over the compact JSON
  # {"type":"http","url":<url>,"headers":{}}. Unlike Claude's key (and the
  # runtime-agnostic McpOauthCredential.compute_credential_key), Codex ALWAYS
  # hashes with the literal type "http" and an empty headers object, regardless of
  # the server's real transport ("sse", "streamable-http") or configured headers.
  # The exact JSON serialization (key order type, url, headers; no whitespace)
  # must match or Codex won't find the entry it looks up at connection time.
  def credential_key_for(server_name, server_config)
    config_for_hash = {
      type: "http",
      url: server_config[:url],
      headers: {}
    }
    compact_json = config_for_hash.to_json.gsub(": ", ":").gsub(", ", ",")
    hash_val = Digest::SHA256.hexdigest(compact_json)[0, 16]

    "#{server_name}|#{hash_val}"
  end

  # Reads the token entries Codex currently has in ~/.codex/.credentials.json,
  # keyed by the same "<server_name>|<hash>" key #write! stores them under.
  #
  # Zimmer writes Codex's store from the DB on every spawn and Codex does not
  # refresh MCP tokens itself (see the class header — openai/codex#17265), so in
  # practice this never surfaces a token newer than the DB. It is implemented for
  # contract symmetry so McpOauthRuntimeReconciler can run uniformly across
  # runtimes; the Keychain is not read here because the file is authoritative on
  # Zimmer's Linux workers.
  #
  # @return [Hash{String => RuntimeMcpTokenSnapshot}] empty when nothing is stored
  def read_runtime_credentials
    data = read_credentials_from_file
    return {} unless data.is_a?(Hash)

    data.each_with_object({}) do |(key, entry), snapshots|
      next unless entry.is_a?(Hash)

      snapshots[key] = RuntimeMcpTokenSnapshot.new(
        access_token: entry["access_token"],
        refresh_token: entry["refresh_token"],
        expires_at: millis_to_time(entry["expires_at"])
      )
    end
  end

  private

  # Reads and parses ~/.codex/.credentials.json, or {} if absent/corrupt.
  def read_credentials_from_file
    return {} unless File.exist?(CODEX_CREDENTIALS_PATH)

    JSON.parse(File.read(CODEX_CREDENTIALS_PATH))
  rescue JSON::ParserError => e
    Rails.logger.warn "[CodexMcpCredentialWriter] Failed to parse existing credentials: #{e.message}"
    {}
  end

  # Converts Codex's millisecond-epoch expires_at to a Time, or nil.
  def millis_to_time(millis)
    return nil if millis.nil?

    Time.at(millis.to_i / 1000.0).utc
  end

  # Builds the flat ~/.codex/.credentials.json entry (snake_case) for a resolved
  # credential. expires_at is milliseconds since epoch. scopes is an array.
  def codex_file_entry(credential)
    entry = {
      "server_name" => credential.server_name,
      "server_url" => credential.server_url,
      "client_id" => credential.client_id,
      "access_token" => credential.access_token,
      "scopes" => scopes_array(credential.scope)
    }

    entry["expires_at"] = expires_at_millis(credential.expires_at) if credential.expires_at.present?
    entry["refresh_token"] = credential.refresh_token if credential.refresh_token.present?

    entry
  end

  # Builds the macOS Keychain blob (Codex's StoredOAuthTokens shape). The URL
  # field is `url`, tokens nest under `token_response`, and scope is a single
  # space-delimited string.
  def codex_keychain_blob(credential)
    token_response = {
      "access_token" => credential.access_token,
      "token_type" => "bearer"
    }
    token_response["refresh_token"] = credential.refresh_token if credential.refresh_token.present?
    scope = scopes_string(credential.scope)
    token_response["scope"] = scope if scope.present?

    {
      "server_name" => credential.server_name,
      "url" => credential.server_url,
      "client_id" => credential.client_id,
      "token_response" => token_response,
      "expires_at" => credential.expires_at.present? ? expires_at_millis(credential.expires_at) : nil
    }
  end

  # OAuth scopes are stored as a single space-delimited string on
  # McpOauthCredential. Codex's file format wants an array.
  def scopes_array(scope)
    scopes_string(scope).to_s.split(/\s+/).reject(&:blank?)
  end

  # Normalizes the stored scope value (string today, but tolerate an array) to a
  # space-delimited string for the Keychain blob.
  def scopes_string(scope)
    return scope.join(" ") if scope.is_a?(Array)

    scope.to_s.strip
  end

  # Codex stores expiry as integer milliseconds since epoch.
  def expires_at_millis(expires_at)
    (expires_at.to_f * 1000).to_i
  end

  # Writes credentials to ~/.codex/.credentials.json, merging with any existing
  # entries (atomic rename, 0600 perms).
  def write_credentials_to_file(credentials)
    codex_dir = File.dirname(CODEX_CREDENTIALS_PATH)
    FileUtils.mkdir_p(codex_dir)

    existing_data = read_credentials_from_file

    # The Codex file is a flat map of "<name>|<hash>" => entry (no envelope key).
    existing_data = {} unless existing_data.is_a?(Hash)
    existing_data.merge!(credentials)

    temp_path = "#{CODEX_CREDENTIALS_PATH}.tmp"
    File.write(temp_path, JSON.pretty_generate(existing_data))
    File.chmod(0o600, temp_path)
    File.rename(temp_path, CODEX_CREDENTIALS_PATH)

    Rails.logger.info "[CodexMcpCredentialWriter] Wrote #{credentials.size} credentials to #{CODEX_CREDENTIALS_PATH}"

    CODEX_CREDENTIALS_PATH
  end

  # Writes one Keychain item per server on macOS, where Codex's default "auto"
  # store reads the Keychain first. Codex stores each server under the generic
  # password (service "Codex MCP Credentials", account "<server_name>|<hash>"),
  # one item per server — unlike Claude Code, which uses a single item keyed by
  # the OS username. Each item's value is the raw JSON of Codex's StoredOAuthTokens
  # (no hex/base64 encoding). Best-effort and rescued — the file write is the
  # authoritative path on Zimmer's Linux workers.
  def write_credentials_to_keychain(credentials)
    credentials.each do |credential|
      blob = JSON.generate(codex_keychain_blob(credential))

      # Use security -i with stdin to avoid shell-escaping the token blob.
      # -U updates the item if it already exists for this service+account.
      stdin_command = "add-generic-password -U -a \"#{credential.credential_key}\" -s \"#{KEYCHAIN_SERVICE_NAME}\" -w \"#{blob}\"\n"
      result = Open3.capture3("security", "-i", stdin_data: stdin_command)

      unless result[2].success?
        Rails.logger.warn "[CodexMcpCredentialWriter] Failed to write #{credential.credential_key} to macOS Keychain: #{result[1]}"
      end
    end

    Rails.logger.info "[CodexMcpCredentialWriter] Wrote #{credentials.size} credentials to macOS Keychain"
  rescue => e
    Rails.logger.warn "[CodexMcpCredentialWriter] Keychain write error: #{e.message}"
  end

  def macos?
    RUBY_PLATFORM.include?("darwin")
  end
end

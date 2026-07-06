# frozen_string_literal: true

# Writes resolved MCP OAuth credentials into the stores Claude Code reads.
#
# On macOS, Claude Code reads credentials from the macOS Keychain (primary) with
# ~/.claude/.credentials.json as a fallback. On Linux, it uses the file only.
# This writer writes to both stores on macOS, and to the file on Linux.
#
# The on-disk format matches what Claude Code expects:
# {
#   "mcpOAuth": {
#     "server_name|hash": {
#       "serverName": "server_name",
#       "serverUrl": "https://...",
#       "clientId": "...",
#       "accessToken": "...",
#       "expiresAt": 1768098636150,  // milliseconds since epoch
#       "refreshToken": "...",
#       "scope": ""
#     }
#   }
# }
class ClaudeMcpCredentialWriter
  include RuntimeMcpCredentialWriter

  CLAUDE_CREDENTIALS_PATH = File.expand_path("~/.claude/.credentials.json").freeze
  KEYCHAIN_SERVICE_NAME = "Claude Code-credentials".freeze

  # Persists the resolved credentials to Claude Code's credential stores.
  # On macOS, writes to both the Keychain (primary) and the file (fallback).
  # On Linux, writes to the file only. Credentials go to ~/.claude regardless of
  # the working directory, so working_directory is accepted for the interface but
  # unused here.
  #
  # @param working_directory [String] the session clone (unused by Claude)
  # @param credentials [Array<ResolvedMcpCredential>]
  # @return [String, nil] path to the credentials file, or nil if none written
  def write!(working_directory:, credentials:)
    return nil if credentials.blank?

    claude_credentials = credentials.each_with_object({}) do |credential, hash|
      hash[credential.credential_key] = claude_credential_entry(credential)
    end

    write_credentials_to_keychain(claude_credentials) if macos?
    write_credentials_to_file(claude_credentials)
  end

  # Claude Code keys mcpOAuth entries by "server_name|hash" where hash is the
  # first 16 chars of SHA256(compact_json({type, url, headers})). This is the
  # same format McpOauthCredential persists as its runtime-agnostic DB identity,
  # so it delegates to the model's protocol-level computation.
  def credential_key_for(server_name, server_config)
    McpOauthCredential.compute_credential_key(server_name, server_config)
  end

  private

  # Merges AO's freshly-resolved mcpOAuth entries into the on-disk/keychain map
  # without clobbering a fresher, still-valid token Claude Code wrote at runtime
  # under the same `server_name|hash` key.
  #
  # AgentSessionJob re-injects credentials on every spawn and follow-up. A plain
  # `merge!` would overwrite whatever Claude Code refreshed in-session with AO's
  # (possibly older) copy. For each key we keep the existing entry only when it
  # is still valid AND strictly newer than AO's; otherwise AO's entry wins.
  #
  # @param existing [Hash] the current mcpOAuth map (mutated in place)
  # @param incoming [Hash] AO's resolved entries keyed by credential_key
  def merge_preserving_fresher!(existing, incoming)
    incoming.each do |key, incoming_entry|
      existing[key] = preferred_entry(existing[key], incoming_entry)
    end
    existing
  end

  # Chooses between an existing (runtime-written) entry and AO's incoming entry.
  # Returns the existing entry only when it is still valid and strictly fresher
  # than AO's; otherwise returns AO's incoming entry.
  def preferred_entry(existing_entry, incoming_entry)
    return incoming_entry if existing_entry.blank?

    existing_expires = existing_entry["expiresAt"]
    # No expiry recorded on the existing entry → not demonstrably fresher, AO wins.
    return incoming_entry if existing_expires.nil?

    now_ms = (Time.current.to_f * 1000).to_i
    # Existing token already expired → AO's entry wins.
    return incoming_entry if existing_expires <= now_ms

    incoming_expires = incoming_entry["expiresAt"]
    # Existing is still valid; keep it unless AO's token is newer (or AO has no
    # expiry, in which case the known-valid existing one is preferred).
    return existing_entry if incoming_expires.nil? || incoming_expires <= existing_expires

    incoming_entry
  end

  # Builds the Claude Code credential entry (camelCase keys) for a resolved
  # credential. expiresAt is milliseconds since epoch (not ISO8601). scope is
  # always emitted empty to match Claude Code's stored shape.
  def claude_credential_entry(credential)
    entry = {
      "serverName" => credential.server_name,
      "serverUrl" => credential.server_url,
      "clientId" => credential.client_id,
      "accessToken" => credential.access_token,
      "scope" => ""
    }

    entry["expiresAt"] = (credential.expires_at.to_f * 1000).to_i if credential.expires_at.present?
    entry["refreshToken"] = credential.refresh_token if credential.refresh_token.present?

    entry
  end

  # Writes credentials to ~/.claude/.credentials.json, merging with existing credentials
  def write_credentials_to_file(credentials)
    # Ensure the ~/.claude directory exists
    claude_dir = File.dirname(CLAUDE_CREDENTIALS_PATH)
    FileUtils.mkdir_p(claude_dir)

    # Read existing credentials file if it exists
    existing_data = if File.exist?(CLAUDE_CREDENTIALS_PATH)
      begin
        JSON.parse(File.read(CLAUDE_CREDENTIALS_PATH))
      rescue JSON::ParserError => e
        Rails.logger.warn "[ClaudeMcpCredentialWriter] Failed to parse existing credentials: #{e.message}"
        {}
      end
    else
      {}
    end

    # Merge our MCP OAuth credentials with existing ones, preserving any fresher,
    # still-valid token Claude Code wrote at runtime under the same key.
    existing_data["mcpOAuth"] ||= {}
    merge_preserving_fresher!(existing_data["mcpOAuth"], credentials)

    # Write back atomically
    temp_path = "#{CLAUDE_CREDENTIALS_PATH}.tmp"
    File.write(temp_path, JSON.pretty_generate(existing_data))
    File.chmod(0o600, temp_path)
    File.rename(temp_path, CLAUDE_CREDENTIALS_PATH)

    Rails.logger.info "[ClaudeMcpCredentialWriter] Wrote #{credentials.size} credentials to #{CLAUDE_CREDENTIALS_PATH}"

    CLAUDE_CREDENTIALS_PATH
  end

  # Writes credentials to macOS Keychain where Claude Code reads them on macOS.
  # Claude Code uses: security find-generic-password -a "$USER" -w -s "Claude Code-credentials"
  # and stores data as hex-encoded JSON.
  def write_credentials_to_keychain(credentials)
    username = ENV.fetch("USER") { Open3.capture3("whoami")[0].strip }

    # Read existing keychain data
    existing_data = read_keychain_data(username) || {}

    # Merge our MCP OAuth credentials, preserving any fresher, still-valid token
    # Claude Code wrote at runtime under the same key.
    existing_data["mcpOAuth"] ||= {}
    merge_preserving_fresher!(existing_data["mcpOAuth"], credentials)

    # Write back to keychain as hex-encoded JSON (matching Claude Code's format)
    json_data = JSON.generate(existing_data)
    hex_data = json_data.bytes.map { |b| b.to_s(16).rjust(2, "0") }.join

    # Use security -i with stdin to avoid shell escaping issues
    stdin_command = "add-generic-password -U -a \"#{username}\" -s \"#{KEYCHAIN_SERVICE_NAME}\" -X \"#{hex_data}\"\n"
    result = Open3.capture3("security", "-i", stdin_data: stdin_command)

    if result[2].success?
      Rails.logger.info "[ClaudeMcpCredentialWriter] Wrote #{credentials.size} credentials to macOS Keychain"
    else
      Rails.logger.warn "[ClaudeMcpCredentialWriter] Failed to write to macOS Keychain: #{result[1]}"
    end
  rescue => e
    Rails.logger.warn "[ClaudeMcpCredentialWriter] Keychain write error: #{e.message}"
  end

  # Reads existing credential data from macOS Keychain
  def read_keychain_data(username)
    output, _stderr, status = Open3.capture3(
      "security", "find-generic-password",
      "-a", username,
      "-s", KEYCHAIN_SERVICE_NAME,
      "-w"
    )

    return nil unless status.success? && output.present?

    JSON.parse(output.strip)
  rescue JSON::ParserError => e
    Rails.logger.warn "[ClaudeMcpCredentialWriter] Failed to parse keychain data: #{e.message}"
    nil
  rescue => e
    Rails.logger.warn "[ClaudeMcpCredentialWriter] Keychain read error: #{e.message}"
    nil
  end

  def macos?
    RUBY_PLATFORM.include?("darwin")
  end
end

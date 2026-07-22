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

  # Claude Code's negative auth cache filename. When a server's connection fails
  # authorization, the CLI records the server here and every later attempt logs
  # "Skipping connection (cached needs-auth)" and never reaches the network. The
  # file is HOST-GLOBAL, so one session's auth failure suppresses that server for
  # every subsequent session on the worker — including sessions that were handed
  # a perfectly good token. A freshly-injected credential is invisible until the
  # entry is removed, which is why #clear_needs_auth_cache is part of injecting.
  #
  # It lives alongside .credentials.json, and the lock file below guards the
  # read-modify-write of both — all three derive from the credentials directory
  # so a test that relocates CLAUDE_CREDENTIALS_PATH relocates the whole set.
  NEEDS_AUTH_CACHE_FILENAME = "mcp-needs-auth-cache.json"
  CREDENTIAL_STORE_LOCK_FILENAME = ".zimmer-credential-store.lock"

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

  # Removes the named servers from Claude Code's host-global needs-auth cache so
  # the CLI retries them with the token Zimmer just wrote instead of skipping the
  # connection outright. Best-effort: a missing or unparseable cache means there
  # is nothing suppressing the server, never an error.
  #
  # @param server_names [Array<String>]
  # @return [Array<String>] the names actually removed from the cache
  def clear_needs_auth_cache(server_names)
    names = Array(server_names).compact.map(&:to_s).uniq
    return [] if names.empty?
    return [] unless File.exist?(needs_auth_cache_path)

    cleared = []
    with_credential_store_lock do
      data = read_json_file(needs_auth_cache_path)
      next unless data.is_a?(Hash)

      cleared = names & data.keys
      next if cleared.empty?

      cleared.each { |name| data.delete(name) }
      write_json_atomically(needs_auth_cache_path, data)
    end

    Rails.logger.info "[ClaudeMcpCredentialWriter] Cleared needs-auth cache for: #{cleared.join(', ')}" if cleared.any?
    cleared
  rescue => e
    Rails.logger.warn "[ClaudeMcpCredentialWriter] Failed to clear needs-auth cache: #{e.message}"
    []
  end

  # Claude Code keys mcpOAuth entries by "server_name|hash" where hash is the
  # first 16 chars of SHA256(compact_json({type, url, headers})). This is the
  # same format McpOauthCredential persists as its runtime-agnostic DB identity,
  # so it delegates to the model's protocol-level computation.
  def credential_key_for(server_name, server_config)
    McpOauthCredential.compute_credential_key(server_name, server_config)
  end

  # Reads the mcpOAuth entries Claude Code currently has on disk, keyed by the
  # same "server_name|hash" key #write! stores them under. This is how Zimmer
  # captures a token Claude Code refreshed (and, for rotating providers, rotated)
  # mid-session back into its DB. On macOS the Keychain is Claude Code's primary
  # store, so its entries win over the file; on Linux only the file exists.
  #
  # @return [Hash{String => RuntimeMcpTokenSnapshot}] empty when nothing is stored
  def read_runtime_credentials
    entries = mcp_oauth_map(read_credentials_from_file)
    entries = entries.merge(mcp_oauth_map(read_keychain_data(keychain_username))) if macos?

    entries.each_with_object({}) do |(key, entry), snapshots|
      next unless entry.is_a?(Hash)

      snapshots[key] = RuntimeMcpTokenSnapshot.new(
        access_token: entry["accessToken"],
        refresh_token: entry["refreshToken"],
        expires_at: millis_to_time(entry["expiresAt"])
      )
    end
  end

  private

  # Extracts the mcpOAuth sub-map from a parsed credentials blob, tolerating a nil
  # or non-Hash blob (missing file / unexpected shape).
  def mcp_oauth_map(data)
    return {} unless data.is_a?(Hash)

    map = data["mcpOAuth"]
    map.is_a?(Hash) ? map : {}
  end

  # Reads and parses ~/.claude/.credentials.json, or {} if absent/corrupt.
  def read_credentials_from_file
    return {} unless File.exist?(CLAUDE_CREDENTIALS_PATH)

    JSON.parse(File.read(CLAUDE_CREDENTIALS_PATH))
  rescue JSON::ParserError => e
    Rails.logger.warn "[ClaudeMcpCredentialWriter] Failed to parse existing credentials: #{e.message}"
    {}
  end

  # Parses a JSON file, or returns {} when it is absent or corrupt. A store we
  # cannot read means "nothing recorded", never an error.
  def read_json_file(path)
    return {} unless File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    Rails.logger.warn "[ClaudeMcpCredentialWriter] Failed to parse #{path}: #{e.message}"
    {}
  end

  # Writes JSON through a temp file + rename so a reader never observes a
  # half-written store. The temp path is process-unique because the same
  # host-global path is written by every session on the worker.
  def write_json_atomically(path, data)
    temp_path = "#{path}.#{Process.pid}.tmp"
    File.write(temp_path, JSON.pretty_generate(data))
    File.chmod(0o600, temp_path)
    File.rename(temp_path, path)
  end

  # The ~/.claude directory that holds the credential file, the needs-auth cache,
  # and the lock. Derived from CLAUDE_CREDENTIALS_PATH so relocating that one path
  # (as tests do) relocates the whole set.
  def claude_dir
    File.dirname(CLAUDE_CREDENTIALS_PATH)
  end

  def needs_auth_cache_path
    File.join(claude_dir, NEEDS_AUTH_CACHE_FILENAME)
  end

  def credential_store_lock_path
    File.join(claude_dir, CREDENTIAL_STORE_LOCK_FILENAME)
  end

  # Serializes read-modify-write access to the host-global credential stores
  # (~/.claude/.credentials.json and the needs-auth cache) across every session
  # on the worker. A dedicated lock file is used so the lock is never the file
  # being atomically replaced by rename.
  def with_credential_store_lock
    FileUtils.mkdir_p(claude_dir)
    File.open(credential_store_lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  # Converts Claude Code's millisecond-epoch expiresAt to a Time, or nil.
  def millis_to_time(millis)
    return nil if millis.nil?

    Time.at(millis.to_i / 1000.0).utc
  end

  def keychain_username
    ENV.fetch("USER") { Open3.capture3("whoami")[0].strip }
  end

  # Merges Zimmer's freshly-resolved mcpOAuth entries into the on-disk/keychain map
  # without clobbering a fresher, still-valid token Claude Code wrote at runtime
  # under the same `server_name|hash` key.
  #
  # AgentSessionJob re-injects credentials on every spawn and follow-up. A plain
  # `merge!` would overwrite whatever Claude Code refreshed in-session with Zimmer's
  # (possibly older) copy. For each key we keep the existing entry only when it
  # is still valid AND strictly newer than Zimmer's; otherwise Zimmer's entry wins.
  #
  # @param existing [Hash] the current mcpOAuth map (mutated in place)
  # @param incoming [Hash] Zimmer's resolved entries keyed by credential_key
  def merge_preserving_fresher!(existing, incoming)
    incoming.each do |key, incoming_entry|
      existing[key] = preferred_entry(existing[key], incoming_entry)
    end
    existing
  end

  # Chooses between an existing (runtime-written) entry and Zimmer's incoming entry.
  # Returns the existing entry only when it is still valid and strictly fresher
  # than Zimmer's; otherwise returns Zimmer's incoming entry.
  def preferred_entry(existing_entry, incoming_entry)
    return incoming_entry if existing_entry.blank?

    existing_expires = existing_entry["expiresAt"]
    # No expiry recorded on the existing entry → not demonstrably fresher, Zimmer wins.
    return incoming_entry if existing_expires.nil?

    now_ms = (Time.current.to_f * 1000).to_i
    # Existing token already expired → Zimmer's entry wins.
    return incoming_entry if existing_expires <= now_ms

    incoming_expires = incoming_entry["expiresAt"]
    # Existing is still valid; keep it unless Zimmer's token is newer (or Zimmer has no
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

    # The file is host-global and every concurrent session read-modify-writes it,
    # so the read and the write must be one critical section. Without the lock two
    # overlapping injections each merge their own subset into the snapshot they
    # read and the last writer wins — silently dropping the other's entry and
    # stranding that session with no token for a server it just authorized.
    with_credential_store_lock do
      # Read existing credentials file if it exists
      existing_data = read_credentials_from_file

      # Merge our MCP OAuth credentials with existing ones, preserving any fresher,
      # still-valid token Claude Code wrote at runtime under the same key.
      existing_data["mcpOAuth"] ||= {}
      merge_preserving_fresher!(existing_data["mcpOAuth"], credentials)

      write_json_atomically(CLAUDE_CREDENTIALS_PATH, existing_data)
    end

    Rails.logger.info "[ClaudeMcpCredentialWriter] Wrote #{credentials.size} credentials to #{CLAUDE_CREDENTIALS_PATH}"

    CLAUDE_CREDENTIALS_PATH
  end

  # Writes credentials to macOS Keychain where Claude Code reads them on macOS.
  # Claude Code uses: security find-generic-password -a "$USER" -w -s "Claude Code-credentials"
  # and stores data as hex-encoded JSON.
  def write_credentials_to_keychain(credentials)
    username = keychain_username

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

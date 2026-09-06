# frozen_string_literal: true

require "digest"
require "json"
require "open3"

# PiMcpCredentialWriter — the RuntimeMcpCredentialWriter for the Pi coding agent.
#
# == The gap this closes ==
#
# Pi's bundle carried `mcp_credential_writer_class: nil`, on the argument that
# `pi-mcp-adapter` "keeps its MCP OAuth tokens in its own state, not in a
# host-global file Zimmer writes". The first half is true and the conclusion did
# not follow: Zimmer holds a valid OAuth token for the server, the adapter has
# a documented way to be handed one, and nothing was carrying it across. So an
# OAuth-credentialed MCP server was simply unusable on Pi — the adapter answered
# every connect with
#
#   Server "granola" requires OAuth authentication. Run mcp({ action:
#   "auth-start", server: "granola" }) ... or /mcp-auth granola in an
#   interactive local session.
#
# and neither of those routes exists for an unattended session: there is no
# browser and nobody to click. Every other MCP auth class works on Pi
# (`${VAR}`-injected stdio, no-auth stdio, strad-proxied HTTP with a bearer
# header, Zimmer's own injected entries); this was the one that did not.
#
# == How a token is handed over ==
#
# The adapter's own ingest path, from `mcp-auth.ts`:
#
#   "Persistent OAuth entries are stored in the operating system credential
#    store. Legacy plaintext entries are imported from
#    $MCP_OAUTH_DIR/sha256-<server-hash>/tokens.json when set, otherwise
#    <Pi agent dir>/mcp-oauth/sha256-<server-hash>/tokens.json, then the
#    plaintext file is removed."
#
# So Zimmer writes that file. `<server-hash>` is SHA-256 of the `.mcp.json`
# server key, and the JSON is the adapter's `AuthEntry`: `serverUrl`, `tokens`
# (accessToken / refreshToken / expiresAt / scope) and `clientInfo` (clientId /
# clientSecret). `McpOauthCredential` holds all of it, so nothing is synthesized.
# On the next read the adapter imports the file into the OS credential store and
# deletes it, which is the intended lifecycle rather than a leftover.
#
# == The ordering hazard, and why the keyring is cleared first ==
#
# `readAuthEntryFromStore` reads the OS credential store FIRST. When it finds an
# entry there it returns it and deletes the plaintext file **without reading
# it**. A file written beside an existing keyring entry is therefore discarded
# in silence — the failure mode where Zimmer believes it rotated a credential
# and the runtime keeps using the old one indefinitely.
#
# So #write! clears the server's credential-store account before writing the
# file, through the adapter's own `mcp-keyring-helper.cjs` (a stable
# JSON-over-stdin read/write/remove helper it ships for exactly this kind of
# out-of-process access). Chunked entries — the adapter splits a payload over
# ~1KB across `<account>.chunk.<digest>.<n>` accounts — are removed by reading
# the manifest and deleting each chunk, so a large entry does not leave a
# fragment behind that reassembles into the stale token.
#
# Clearing first also states the ownership rule plainly: **Zimmer is the source
# of truth for these credentials, and it re-stamps the runtime's copy at every
# spawn.** That is what makes #read_runtime_credentials's answer correct rather
# than lazy — see below.
#
# == Why #read_runtime_credentials returns {} ==
#
# The read side exists so Zimmer can adopt a token the runtime refreshed and
# rotated mid-session. For Pi it deliberately adopts nothing, for two reasons
# that point the same way:
#
#   * **It cannot enumerate.** After import the entries live in the OS credential
#     store, which is keyed by `sha256(server_name)` and offers no listing — the
#     contract's zero-argument reader has nothing to iterate. Guessing from the
#     session's servers would make a host-global reader depend on one session.
#   * **It should not adopt.** Zimmer overwrites the runtime's copy at every
#     spawn (above), so the DB is authoritative by construction. Adopting the
#     runtime's copy back would make two writers of one value with no ordering
#     between them.
#
# The honest consequence, recorded in docs/limitations.md rather than left to be
# discovered: if a provider rotates the REFRESH token on a refresh Pi performed,
# Zimmer's stored refresh token goes stale and the credential needs
# re-authorizing through Zimmer. `{}` is the contract's documented answer for
# "nothing to adopt", not a stub.
class PiMcpCredentialWriter
  include RuntimeMcpCredentialWriter

  # The keyring service name the adapter stores every MCP OAuth entry under
  # (`AUTH_SECRET_SERVICE` in `mcp-auth.ts`).
  KEYRING_SERVICE = "pi-mcp-adapter.oauth"

  # The adapter's marker key on a chunk manifest (`AUTH_CHUNK_MANIFEST_KEY`).
  CHUNK_MANIFEST_KEY = "__piMcpAdapterOAuthChunked"

  # The helper the adapter ships for out-of-process credential-store access.
  # Relative to the installed package, so it moves with a version bump.
  KEYRING_HELPER_RELATIVE = File.join("pi-mcp-adapter", "mcp-keyring-helper.cjs")

  # The helper loads a native binding; a couple of seconds is generous and keeps
  # a wedged store from holding up a spawn.
  HELPER_TIMEOUT_SECONDS = 10

  def initialize(logger: nil, file_system: nil)
    @logger = logger || StructuredLogger.new({ service: "PiMcpCredentialWriter" })
    @file_system = file_system || RealFileSystemAdapter.new
  end

  # Pi keys its credential store by the MCP server name as it appears in
  # `.mcp.json` — `getAuthEntryAccount` hashes that string and nothing else. So
  # unlike Claude Code (which hashes the server CONFIG into the key), the key
  # here is the plain name.
  #
  # @param server_name [String]
  # @param _server_config [Hash] unused; Pi's store does not key on it
  # @return [String]
  def credential_key_for(server_name, _server_config = nil)
    server_name.to_s
  end

  # Write each credential where pi-mcp-adapter will import it.
  #
  # @param working_directory [String, nil] unused — Pi's OAuth store is
  #   host-global under PI_CODING_AGENT_DIR, not per-clone.
  # @param credentials [Array<ResolvedMcpCredential>]
  # @return [String, nil] the directory written, or nil when nothing was written
  def write!(working_directory: nil, credentials: [])
    credentials = Array(credentials)
    return nil if credentials.empty?

    written = credentials.count { |credential| write_one(credential) }
    return nil if written.zero?

    @logger.info("Wrote #{written} Pi MCP OAuth credential(s) for import", directory: oauth_dir)
    oauth_dir
  end

  # Nothing to adopt — see the class comment.
  #
  # @return [Hash{String => RuntimeMcpTokenSnapshot}] always empty
  def read_runtime_credentials
    {}
  end

  # Drop the named entries from both halves of the store: the pending plaintext
  # file, and the credential-store account it would have been imported into.
  #
  # @param credential_keys [Array<String>] server names (see #credential_key_for)
  # @return [Array<String>] the keys something was actually removed for
  def delete_credentials(credential_keys)
    Array(credential_keys).filter_map do |key|
      server_name = key.to_s
      next if server_name.empty?

      removed_keyring = clear_keyring_entry(server_name)
      removed_file = remove_pending_file(server_name)
      server_name if removed_keyring || removed_file
    end
  end

  # Pi has no "this server needs auth" memo to clear. The adapter re-reads the
  # credential store on every connect attempt, so a freshly written token is
  # picked up without anything being invalidated. Returns [] rather than raising
  # — the contract's answer for "nothing is suppressing it".
  #
  # @param _server_names [Array<String>]
  # @return [Array<String>] always empty
  def clear_needs_auth_cache(_server_names)
    []
  end

  # Where the adapter looks for a pending plaintext entry:
  # `$MCP_OAUTH_DIR` when set, else `<Pi agent dir>/mcp-oauth`. Zimmer exports
  # PI_CODING_AGENT_DIR (PiRuntimeAdapter#ensure_pi_home) and sets no
  # MCP_OAUTH_DIR, so PiHome resolves the same directory the adapter will.
  def oauth_dir
    ENV["MCP_OAUTH_DIR"].presence || PiHome.mcp_oauth_dir_path
  end

  private

  def write_one(credential)
    server_name = credential.server_name.to_s
    return false if server_name.empty? || credential.access_token.blank?

    # Order matters: a credential-store entry SHADOWS the file and would make
    # this write a silent no-op. See the class comment.
    clear_keyring_entry(server_name)

    path = pending_file_path(server_name)
    @file_system.mkdir_p(File.dirname(path))
    @file_system.write(path, JSON.pretty_generate(auth_entry(credential)))
    # The file holds a bearer token in plaintext until the adapter imports it.
    # Owner-only for the window in between.
    @file_system.chmod(0o600, path)
    true
  rescue => e
    # A credential that cannot be handed over costs one server, never the spawn.
    @logger.warn("Could not stage Pi MCP OAuth credential", server: credential.server_name, error: e.message)
    false
  end

  # The adapter's AuthEntry shape (`toAuthEntry` in `mcp-auth.ts`). Only fields
  # it actually parses are emitted: an unknown key makes the whole entry
  # unparseable in some versions, and there is nothing to gain by sending one.
  def auth_entry(credential)
    tokens = { "accessToken" => credential.access_token }
    tokens["refreshToken"] = credential.refresh_token if credential.refresh_token.present?
    # `expiresAt` is seconds since the epoch, not milliseconds — `toOAuthTokens`
    # computes `expiresAt - Date.now() / 1000`.
    tokens["expiresAt"] = credential.expires_at.to_i if credential.expires_at.present?
    tokens["scope"] = credential.scope if credential.scope.present?

    client_info = { "clientId" => credential.client_id.to_s }

    { "serverUrl" => credential.server_url.to_s, "tokens" => tokens, "clientInfo" => client_info }
  end

  # `getAuthEntryFilePath`: <oauth dir>/sha256-<hex>/tokens.json
  def pending_file_path(server_name)
    File.join(oauth_dir, keyring_account(server_name), "tokens.json")
  end

  # `getAuthEntryAccount` in `mcp-auth.ts`.
  def keyring_account(server_name)
    "sha256-#{Digest::SHA256.hexdigest(server_name)}"
  end

  def remove_pending_file(server_name)
    path = pending_file_path(server_name)
    return false unless @file_system.exists?(path)

    @file_system.rm_rf(path)
    true
  rescue => e
    @logger.warn("Could not remove pending Pi MCP OAuth credential", server: server_name, error: e.message)
    false
  end

  # Remove a server's credential-store entry, including the chunk accounts a
  # large payload is split across (`getAuthEntryChunkAccount`).
  #
  # @return [Boolean] whether anything was removed
  def clear_keyring_entry(server_name)
    account = keyring_account(server_name)
    payload = keyring_call("read", account)
    return false unless payload.is_a?(Hash) && payload["found"]

    chunk_accounts(account, payload["value"]).each { |chunk| keyring_call("remove", chunk) }
    keyring_call("remove", account)
    true
  rescue => e
    # A store Zimmer cannot reach must not stop a spawn. The consequence is that
    # a stale entry may shadow this write, which is what the log line says.
    @logger.warn(
      "Could not clear Pi MCP OAuth credential-store entry; a stale entry may shadow the new token",
      server: server_name, error: e.message
    )
    false
  end

  # A manifest payload names how many chunks the real entry was split over.
  def chunk_accounts(account, payload)
    manifest = JSON.parse(payload.to_s)
    return [] unless manifest.is_a?(Hash) && manifest[CHUNK_MANIFEST_KEY] == 1

    count = manifest["chunkCount"].to_i
    digest = manifest["chunkDigest"]
    return [] if count <= 0 || digest.blank?

    Array.new(count) { |index| "#{account}.chunk.#{digest}.#{index}" }
  rescue JSON::ParserError
    []
  end

  # Drive the adapter's helper. Returns the parsed response, or nil when the
  # helper is not installed (an image without the extension — PiExtensions#missing
  # already reports that through CliStatusService, so this stays quiet).
  #
  # Bounded rather than a plain Open3.capture3: the helper loads a native
  # credential-store binding, and a store that hangs rather than answering would
  # otherwise hold up the spawn indefinitely. BoundedSubprocess is not reusable
  # here because it closes the child's stdin, and this helper's whole protocol is
  # a JSON request on stdin.
  def keyring_call(operation, account)
    helper = helper_path
    return nil unless helper && @file_system.exists?(helper)

    request = JSON.generate({ operation: operation, service: KEYRING_SERVICE, account: account })
    stdout, stderr, status = run_helper(helper, request)

    unless status&.success?
      raise "pi-mcp-adapter keyring helper failed (#{operation}): #{stderr.strip.presence || stdout.strip}"
    end

    JSON.parse(stdout.lines.last.to_s)
  end

  # @return [Array(String, String, Process::Status, nil)] stdout, stderr, status
  def run_helper(helper, request)
    Open3.popen3("node", helper) do |stdin, stdout, stderr, wait_thr|
      stdin.write(request)
      stdin.close

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HELPER_TIMEOUT_SECONDS
      out = +""
      err = +""
      buffers = { stdout => out, stderr => err }

      until buffers.empty?
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          Process.kill("KILL", wait_thr.pid)
          wait_thr.value # reap, so the killed child does not linger as a zombie
          raise "pi-mcp-adapter keyring helper timed out after #{HELPER_TIMEOUT_SECONDS}s"
        end

        ready, = IO.select(buffers.keys, nil, nil, remaining)
        next if ready.nil?

        ready.each do |io|
          buffers[io] << io.readpartial(65_536)
        rescue EOFError
          io.close
          buffers.delete(io)
        end
      end

      [ out, err, wait_thr.value ]
    end
  rescue Errno::ENOENT, Errno::ESRCH => e
    raise "pi-mcp-adapter keyring helper could not run: #{e.message}"
  end

  def helper_path
    File.join(PiExtensions::INSTALL_DIR, "node_modules", KEYRING_HELPER_RELATIVE)
  end
end

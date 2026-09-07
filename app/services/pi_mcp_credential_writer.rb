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
# (accessToken / refreshToken / expiresAt / scope) and `clientInfo` (clientId).
# Every field is taken from `ResolvedMcpCredential`, so nothing is synthesized.
# On the next read the adapter imports the file into the OS credential store and
# deletes it, which is the intended lifecycle rather than a leftover.
#
# The client SECRET is deliberately absent, because `ResolvedMcpCredential` does
# not carry one — the injector resolves it, uses it to refresh, and does not
# publish it. For a confidential client on a `client_secret_post` provider that
# means the adapter cannot perform its own refresh against the entry Zimmer
# stages, and re-authorizing goes through Zimmer instead. Zimmer refreshing on
# its own schedule and re-stamping at every spawn is what covers that. A PUBLIC
# client — the DCR-registered default for MCP — has no secret to withhold, so
# the adapter refreshes those perfectly well, which is what
# "Why #read_runtime_credentials probes by key" below is about.
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
# spawn** — with the read side below supplying the one thing a re-stamp alone
# cannot, which is a way to notice when Pi got there first.
#
# == Why #read_runtime_credentials probes by key ==
#
# The read side exists so Zimmer can adopt a token the runtime refreshed and
# rotated mid-session. Pi needs it for the same reason Claude Code does: the
# adapter hands the MCP SDK an OAuth provider whose `saveTokens` writes straight
# back into the credential store, so when an access token lapses mid-session the
# SDK runs `grant_type=refresh_token` and persists the new pair. Against a
# provider that rotates refresh tokens that leaves Zimmer's DB holding a revoked
# one, and the next cron refresh gets `invalid_grant`.
#
# It cannot be written as a listing. After import the entries live in the OS
# credential store, which is addressed by `sha256(server_name)` and offers no
# enumeration, so a zero-argument reader has nothing to iterate. The reconciler
# does not want a listing — it reconciles one named credential at a time — so
# the contract's read side takes the keys the caller wants
# (RuntimeMcpCredentialWriter#read_runtime_credentials), this writer probes
# exactly those accounts through the same helper #write! already drives, and
# #enumerable_store? returns false so the reconciler asks per key rather than
# once.
#
# Re-stamping the runtime's copy at every spawn is not on its own enough to make
# Zimmer the sole authority, because that would need the runtime's own refresh
# turned off and pi-mcp-adapter has no such switch: `oauth: false` disables OAuth
# for the server outright rather than pinning the staged token, and no
# environment variable narrows it. Two writers of one value therefore need an
# ordering, and McpOauthRuntimeReconciler supplies a real one: it adopts only a
# **strictly later access-token expiry**, so the chain moves in one direction and
# a re-stamp of an older pair can never win.
#
# Reads are ordered against #write! by the caller, not by luck: the injector
# reconciles inside #collect_credentials, before it writes, and #write! is what
# clears the account. A read that ran after the clear would see nothing and
# adopt nothing — never a wrong adoption.
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

  # The helper loads a native binding, which is fast; the budget is for a store
  # that hangs rather than answering. Kept small on purpose: the credential-retire
  # path (`McpOauthCredentialInjector#delete_runtime_credentials`) instantiates
  # EVERY registered runtime's writer, not the session's, so this runs on Claude
  # and Codex sessions too and its worst case is charged to them.
  HELPER_TIMEOUT_SECONDS = 5

  # Adoption probes get a tighter budget than the write and delete paths, because
  # they are the only ones that can be skipped without consequence. A spawn whose
  # keyring clear times out may hand the runtime a stale token; a spawn whose
  # adoption probe times out just leaves Zimmer's own copy in place, and the next
  # spawn or cron run reconciles. The pre-spawn OAuth gate builds several
  # McpOauthCredentialInjectors and each holds its own reconciler, so a hanging
  # store is charged once per (server × injector) — worth two seconds, not five.
  READ_TIMEOUT_SECONDS = 2

  # The adapter validates a chunk manifest (`chunkCount` a safe integer,
  # `chunkDigest` 16 lowercase hex) before trusting it; so does this, because a
  # manifest claiming a large count would otherwise become that many sequential
  # `node` spawns.
  MAX_CHUNKS = 64
  CHUNK_DIGEST = /\A[a-f0-9]{16}\z/

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

  # Pi's store is addressable but not listable, so the reconciler probes it a
  # key at a time. See the class comment.
  #
  # @return [Boolean] always false
  def enumerable_store?
    false
  end

  # Pi keys its store by the bare `.mcp.json` server name, not the
  # protocol-level credential key the file-store runtimes use.
  #
  # @param credential [McpOauthCredential]
  # @return [String]
  def runtime_key_for(credential)
    credential.server_name.to_s
  end

  # Read back whatever pi-mcp-adapter currently holds for the named servers.
  #
  # @param credential_keys [Array<String>, nil] server names (see
  #   #credential_key_for). nil means "enumerate", which this store cannot do,
  #   so it answers {} — the contract's documented "nothing to adopt".
  # @return [Hash{String => RuntimeMcpTokenSnapshot}] only the keys an entry was
  #   found and parsed for
  def read_runtime_credentials(credential_keys = nil)
    Array(credential_keys).uniq.each_with_object({}) do |key, snapshots|
      server_name = key.to_s
      next if server_name.empty?

      snapshot = read_one(server_name)
      snapshots[server_name] = snapshot if snapshot
    end
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
    write_one_file(credential)
    true
  rescue => e
    # A credential that cannot be handed over costs one server, never the spawn.
    @logger.warn("Could not stage Pi MCP OAuth credential", server: credential.server_name, error: e.message)
    false
  end

  # The file half of #write_one, split out so the ordering against
  # #clear_keyring_entry is assertable — the two are only correct in that order,
  # and nothing about the code shape says so.
  def write_one_file(credential)
    path = pending_file_path(credential.server_name.to_s)
    @file_system.mkdir_p(File.dirname(path))
    # The file holds a bearer token in plaintext until the adapter imports it, so
    # it is created owner-only rather than created at the umask and narrowed after
    # — the gap between the two is a readable token.
    @file_system.write(path, JSON.pretty_generate(auth_entry(credential)), perm: 0o600)
  end

  # The credential-store half of #read_runtime_credentials, for one server.
  #
  # Only the OS credential store is read, never the pending plaintext file: the
  # file only ever holds what Zimmer itself staged and the adapter has not yet
  # imported, so reading it back could only echo the DB — never a rotation. The
  # store is where a token Pi refreshed actually lands.
  #
  # @return [RuntimeMcpTokenSnapshot, nil] nil when there is no entry, the store
  #   cannot be reached, or the payload does not parse
  def read_one(server_name)
    account = keyring_account(server_name)
    payload = keyring_call("read", account, timeout: READ_TIMEOUT_SECONDS)
    return nil unless payload.is_a?(Hash) && payload["found"]

    entry = parse_auth_entry(account, payload["value"])
    return nil unless entry.is_a?(Hash)

    tokens = entry["tokens"]
    return nil unless tokens.is_a?(Hash)
    # The adapter type-checks these before trusting an entry (`toAuthEntry`); so
    # does this, because a numeric or object accessToken is `present?` and would
    # otherwise be adopted into the DB as a token.
    return nil unless tokens["accessToken"].is_a?(String)
    return nil unless tokens["refreshToken"].nil? || tokens["refreshToken"].is_a?(String)

    RuntimeMcpTokenSnapshot.new(
      access_token: tokens["accessToken"],
      refresh_token: tokens["refreshToken"],
      expires_at: seconds_to_time(tokens["expiresAt"]),
      # Carried so the reconciler can refuse an entry that belongs to a different
      # row with the same server name — see McpOauthRuntimeReconciler#adoptable?.
      server_url: entry["serverUrl"].is_a?(String) ? entry["serverUrl"] : nil
    )
  rescue => e
    # A store Zimmer cannot read means "nothing to adopt", never a failed spawn
    # or a failed cron run — the same rule #clear_keyring_entry follows.
    @logger.warn("Could not read Pi MCP OAuth credential-store entry", server: server_name, error: e.message)
    nil
  end

  # A stored payload is either the AuthEntry JSON or a chunk manifest naming the
  # accounts the real payload was split across (`readChunkedAuthEntry`).
  def parse_auth_entry(account, payload)
    manifest = chunk_manifest(account, payload)
    if manifest
      payload = manifest[:accounts].map do |chunk|
        response = keyring_call("read", chunk, timeout: READ_TIMEOUT_SECONDS)
        # A manifest whose chunks are gone reassembles into garbage rather than
        # nothing, so a missing one has to abort the whole entry.
        return nil unless response.is_a?(Hash) && response["found"]

        response["value"].to_s
      end.join
      # The adapter computes this digest over the payload it split, so checking it
      # is how a partial or reordered reassembly fails as "nothing to adopt"
      # instead of as a JSON parse that happens to succeed.
      return nil unless Digest::SHA256.hexdigest(payload)[0, 16] == manifest[:digest]
    end

    JSON.parse(payload.to_s)
  rescue JSON::ParserError
    nil
  end

  # `expiresAt` is seconds since the epoch — `toOAuthTokens` computes
  # `expiresAt - Date.now() / 1000`. Mirrors #auth_entry's write side.
  def seconds_to_time(value)
    return nil unless value.is_a?(Numeric)
    return nil unless value.positive?

    Time.zone.at(value)
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
    chunk_manifest(account, payload)&.fetch(:accounts) || []
  end

  # The parsed form of the above: the chunk accounts plus the digest the adapter
  # recorded over the payload it split, or nil when this payload is not a
  # manifest. Split out because the read side verifies the digest and the delete
  # side only needs the accounts.
  def chunk_manifest(account, payload)
    manifest = JSON.parse(payload.to_s)
    return nil unless manifest.is_a?(Hash) && manifest[CHUNK_MANIFEST_KEY] == 1

    count = manifest["chunkCount"].to_i
    digest = manifest["chunkDigest"].to_s
    return nil if count <= 0 || count > MAX_CHUNKS || !digest.match?(CHUNK_DIGEST)

    { digest: digest, accounts: Array.new(count) { |index| "#{account}.chunk.#{digest}.#{index}" } }
  rescue JSON::ParserError
    nil
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
  def keyring_call(operation, account, timeout: HELPER_TIMEOUT_SECONDS)
    # The OS credential store is host-global and out of process: on a developer
    # box that is the login keychain, and on a Zimmer droplet it is the running
    # fleet's. The shared contract test constructs every writer and calls
    # #delete_credentials on it, so without this guard a unit test would spawn
    # `node` against the real store wherever the extension happens to be
    # installed — which is exactly the class of accident that put a fixture token
    # into a live store once already.
    return nil if Rails.env.test?

    helper = helper_path
    return nil unless helper && @file_system.exists?(helper)

    request = JSON.generate({ operation: operation, service: KEYRING_SERVICE, account: account })
    stdout, stderr, status = run_helper(helper, request, timeout)

    unless status&.success?
      raise "pi-mcp-adapter keyring helper failed (#{operation}): #{stderr.strip.presence || stdout.strip}"
    end

    JSON.parse(stdout.lines.last.to_s)
  end

  # @return [Array(String, String, Process::Status)] stdout, stderr, status
  def run_helper(helper, request, timeout = HELPER_TIMEOUT_SECONDS)
    Open3.popen3("node", helper) do |stdin, stdout, stderr, wait_thr|
      stdin.write(request)
      stdin.close

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      out = +""
      err = +""
      buffers = { stdout => out, stderr => err }

      until buffers.empty?
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          Process.kill("KILL", wait_thr.pid)
          wait_thr.value # reap, so the killed child does not linger as a zombie
          raise "pi-mcp-adapter keyring helper timed out after #{timeout}s"
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

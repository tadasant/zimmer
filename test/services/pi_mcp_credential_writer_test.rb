# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests for PiMcpCredentialWriter — the Pi runtime's MCP OAuth credential sink.
#
# Pi's MCP client is the `pi-mcp-adapter` extension, which imports a plaintext
# entry from `<oauth dir>/sha256-<sha256(server)>/tokens.json` into the OS
# credential store and then deletes it. This writer stages that file.
#
# The keyring half is driven through the adapter's `mcp-keyring-helper.cjs`, so
# these tests stub `keyring_call` rather than shelling out: a unit test must not
# depend on a native credential store being present on the box.
class PiMcpCredentialWriterTest < ActiveSupport::TestCase
  setup do
    @oauth_dir = Dir.mktmpdir("pi-mcp-oauth")
    @writer = PiMcpCredentialWriter.new
    @writer.stubs(:oauth_dir).returns(@oauth_dir)
    # Default: the credential store holds nothing for this server.
    @writer.stubs(:keyring_call).returns({ "ok" => true, "found" => false })
  end

  teardown do
    FileUtils.remove_entry(@oauth_dir) if @oauth_dir && File.directory?(@oauth_dir)
  end

  def credential(server_name: "notion", **overrides)
    ResolvedMcpCredential.new(
      server_name: server_name,
      server_url: "https://mcp.notion.com/mcp",
      client_id: "client-abc",
      access_token: "access-123",
      refresh_token: "refresh-456",
      expires_at: Time.zone.at(1_800_000_000),
      scope: "read write",
      headers: {},
      credential_key: server_name,
      **overrides
    )
  end

  # `getAuthEntryAccount` in the adapter's mcp-auth.ts.
  def account_for(server_name)
    "sha256-#{Digest::SHA256.hexdigest(server_name)}"
  end

  def entry_path(server_name)
    File.join(@oauth_dir, account_for(server_name), "tokens.json")
  end

  test "credential_key_for is the plain server name" do
    # Pi hashes the .mcp.json server KEY, not the server config — unlike Claude
    # Code, whose key is a hash of {type, url, headers}.
    assert_equal "notion", @writer.credential_key_for("notion", { type: "streamable-http", url: "https://x/mcp", headers: {} })
  end

  test "write! stages the entry at the path the adapter imports from" do
    assert_equal @oauth_dir, @writer.write!(working_directory: "/clone", credentials: [ credential ])

    assert_path_exists entry_path("notion")
  end

  test "the staged entry carries the adapter's AuthEntry shape" do
    @writer.write!(working_directory: "/clone", credentials: [ credential ])
    entry = JSON.parse(File.read(entry_path("notion")))

    assert_equal "https://mcp.notion.com/mcp", entry["serverUrl"]
    assert_equal "access-123", entry.dig("tokens", "accessToken")
    assert_equal "refresh-456", entry.dig("tokens", "refreshToken")
    assert_equal "read write", entry.dig("tokens", "scope")
    assert_equal "client-abc", entry.dig("clientInfo", "clientId")
  end

  test "expiresAt is seconds since the epoch, not milliseconds" do
    # `toOAuthTokens` computes `expiresAt - Date.now() / 1000`, so milliseconds
    # here would put every token ~50,000 years in the future and it would never
    # be refreshed.
    @writer.write!(working_directory: "/clone", credentials: [ credential ])
    entry = JSON.parse(File.read(entry_path("notion")))

    assert_equal 1_800_000_000, entry.dig("tokens", "expiresAt")
  end

  test "optional token fields are omitted rather than written null" do
    @writer.write!(
      working_directory: "/clone",
      credentials: [ credential(refresh_token: nil, expires_at: nil, scope: nil) ]
    )
    tokens = JSON.parse(File.read(entry_path("notion")))["tokens"]

    assert_equal({ "accessToken" => "access-123" }, tokens)
  end

  test "the staged file is owner-only while it holds a bearer token in plaintext" do
    @writer.write!(working_directory: "/clone", credentials: [ credential ])

    assert_equal "600", (File.stat(entry_path("notion")).mode & 0o777).to_s(8)
  end

  test "write! clears the credential-store entry first, because it would shadow the file" do
    # readAuthEntryFromStore reads the OS store FIRST and deletes the plaintext
    # file WITHOUT reading it when it finds one there. Writing beside a stale
    # entry would silently keep the old token.
    account = account_for("notion")
    order = sequence("clear-then-write")
    @writer.unstub(:keyring_call)
    @writer.expects(:keyring_call).with("read", account)
      .returns({ "ok" => true, "found" => true, "value" => "{}" }).in_sequence(order)
    @writer.expects(:keyring_call).with("remove", account).returns({ "ok" => true }).in_sequence(order)
    # Ordering is the whole point: a file written BEFORE the clear is read by the
    # adapter, found shadowed by the store entry, and deleted unread.
    @writer.expects(:write_one_file).in_sequence(order)

    @writer.write!(working_directory: "/clone", credentials: [ credential ])
  end

  test "a chunked credential-store entry has every chunk removed" do
    # The adapter splits a payload over ~1KB across `<account>.chunk.<digest>.<n>`.
    # Leaving one behind lets the stale entry reassemble.
    account = account_for("notion")
    manifest = JSON.generate({ "__piMcpAdapterOAuthChunked" => 1, "chunkCount" => 2, "chunkDigest" => "0123456789abcdef" })
    @writer.unstub(:keyring_call)
    @writer.stubs(:keyring_call).with("read", account).returns({ "ok" => true, "found" => true, "value" => manifest })
    @writer.expects(:keyring_call).with("remove", "#{account}.chunk.0123456789abcdef.0").returns({ "ok" => true })
    @writer.expects(:keyring_call).with("remove", "#{account}.chunk.0123456789abcdef.1").returns({ "ok" => true })
    @writer.expects(:keyring_call).with("remove", account).returns({ "ok" => true })

    @writer.write!(working_directory: "/clone", credentials: [ credential ])
  end

  test "an implausible chunk manifest is refused rather than becoming N subprocesses" do
    account = account_for("notion")
    bogus = JSON.generate({ "__piMcpAdapterOAuthChunked" => 1, "chunkCount" => 100_000, "chunkDigest" => "0123456789abcdef" })
    @writer.unstub(:keyring_call)
    @writer.stubs(:keyring_call).with("read", account).returns({ "ok" => true, "found" => true, "value" => bogus })
    # Only the base account is removed: no chunk accounts are derived from a
    # manifest whose count is out of range, even though its digest is well-formed.
    @writer.expects(:keyring_call).with("remove", account).returns({ "ok" => true })

    @writer.write!(working_directory: "/clone", credentials: [ credential ])
  end

  test "the credential store is never touched from a test" do
    # The store is host-global and out of process. #keyring_call short-circuits in
    # the test environment so no test — including the shared writer contract test,
    # which calls #delete_credentials on every writer — can spawn `node` against
    # a developer's login keychain or a droplet's live store.
    writer = PiMcpCredentialWriter.new
    writer.expects(:run_helper).never

    assert_nil writer.send(:keyring_call, "read", "sha256-abc")
  end

  test "a credential store Zimmer cannot reach does not stop the spawn" do
    @writer.unstub(:keyring_call)
    @writer.stubs(:keyring_call).raises(RuntimeError, "keyring helper timed out")

    assert_equal @oauth_dir, @writer.write!(working_directory: "/clone", credentials: [ credential ])
    assert_path_exists entry_path("notion")
  end

  test "write! returns nil when there is nothing to write" do
    assert_nil @writer.write!(working_directory: "/clone", credentials: [])
    assert_nil @writer.write!(working_directory: "/clone", credentials: [ credential(access_token: nil) ])
  end

  test "one unwritable credential does not lose the others" do
    good = credential(server_name: "notion")
    bad = credential(server_name: "linear")
    @writer.stubs(:pending_file_path).with("linear").raises(Errno::EACCES)
    @writer.stubs(:pending_file_path).with("notion").returns(entry_path("notion"))

    assert_equal @oauth_dir, @writer.write!(working_directory: "/clone", credentials: [ bad, good ])
    assert_path_exists entry_path("notion")
  end

  # The AuthEntry shape pi-mcp-adapter stores (`toAuthEntry` in mcp-auth.ts).
  def stored_entry(access_token: "pi-rotated-access", refresh_token: "pi-rotated-refresh", expires_at: 1_900_000_000)
    JSON.generate(
      "serverUrl" => "https://mcp.notion.com/mcp",
      "tokens" => {
        "accessToken" => access_token,
        "refreshToken" => refresh_token,
        "expiresAt" => expires_at,
        "scope" => "read write"
      },
      "clientInfo" => { "clientId" => "client-abc" }
    )
  end

  # Reads carry the tighter adoption budget (see READ_TIMEOUT_SECONDS), so a stub
  # that omitted the keyword would silently stop matching.
  def stub_keyring_read(account, value)
    @writer.unstub(:keyring_call)
    @writer.stubs(:keyring_call).returns({ "ok" => true, "found" => false })
    @writer.stubs(:keyring_call).with("read", account, timeout: PiMcpCredentialWriter::READ_TIMEOUT_SECONDS)
      .returns({ "ok" => true, "found" => true, "value" => value })
  end

  test "the store is probe-only, so the reconciler must ask by key" do
    assert_not @writer.enumerable_store?
  end

  test "runtime_key_for is the bare server name, not the protocol credential key" do
    # Pi hashes the .mcp.json server key; Claude Code and Codex key by
    # "server_name|hash". The cron reconciles one DB row against every runtime's
    # store, so each writer has to name its own entry.
    credential = mcp_oauth_credentials(:notion)

    assert_equal "notion", @writer.runtime_key_for(credential)
    assert_not_equal credential.credential_key, @writer.runtime_key_for(credential)
  end

  test "read_runtime_credentials reads back the pair Pi rotated to" do
    stub_keyring_read(account_for("notion"), stored_entry)

    snapshots = @writer.read_runtime_credentials([ "notion" ])

    assert_equal [ "notion" ], snapshots.keys
    assert_equal "pi-rotated-access", snapshots["notion"].access_token
    assert_equal "pi-rotated-refresh", snapshots["notion"].refresh_token
    assert_equal Time.zone.at(1_900_000_000), snapshots["notion"].expires_at
  end

  test "read_runtime_credentials reassembles a chunked entry" do
    account = account_for("notion")
    payload = stored_entry
    digest = Digest::SHA256.hexdigest(payload)[0, 16]
    manifest = JSON.generate(
      PiMcpCredentialWriter::CHUNK_MANIFEST_KEY => 1,
      "chunkCount" => 2,
      "chunkDigest" => digest
    )
    half = (payload.length / 2.0).ceil

    @writer.unstub(:keyring_call)
    @writer.stubs(:keyring_call).returns({ "ok" => true, "found" => false })
    read_timeout = { timeout: PiMcpCredentialWriter::READ_TIMEOUT_SECONDS }
    @writer.stubs(:keyring_call).with("read", account, **read_timeout).returns({ "ok" => true, "found" => true, "value" => manifest })
    @writer.stubs(:keyring_call).with("read", "#{account}.chunk.#{digest}.0", **read_timeout)
      .returns({ "ok" => true, "found" => true, "value" => payload[0, half] })
    @writer.stubs(:keyring_call).with("read", "#{account}.chunk.#{digest}.1", **read_timeout)
      .returns({ "ok" => true, "found" => true, "value" => payload[half..] })

    assert_equal "pi-rotated-refresh", @writer.read_runtime_credentials([ "notion" ])["notion"].refresh_token
  end

  test "read_runtime_credentials abandons an entry whose chunks have gone missing" do
    # Joining the surviving chunks would reassemble into garbage; a half-read
    # entry must look like "nothing to adopt", never like a token.
    account = account_for("notion")
    manifest = JSON.generate(
      PiMcpCredentialWriter::CHUNK_MANIFEST_KEY => 1,
      "chunkCount" => 2,
      "chunkDigest" => "a" * 16
    )
    @writer.unstub(:keyring_call)
    @writer.stubs(:keyring_call).returns({ "ok" => true, "found" => false })
    read_timeout = { timeout: PiMcpCredentialWriter::READ_TIMEOUT_SECONDS }
    @writer.stubs(:keyring_call).with("read", account, **read_timeout).returns({ "ok" => true, "found" => true, "value" => manifest })
    @writer.stubs(:keyring_call).with("read", "#{account}.chunk.#{'a' * 16}.0", **read_timeout)
      .returns({ "ok" => true, "found" => true, "value" => "{\"serverUrl\":" })

    assert_empty @writer.read_runtime_credentials([ "notion" ])
  end

  test "read_runtime_credentials carries the serverUrl the entry was recorded against" do
    stub_keyring_read(account_for("notion"), stored_entry)

    assert_equal "https://mcp.notion.com/mcp", @writer.read_runtime_credentials([ "notion" ])["notion"].server_url
  end

  test "read_runtime_credentials rejects a token that is not a string" do
    # A numeric or object accessToken is `present?`, so without this it would be
    # adopted into the DB as if it were a token.
    stub_keyring_read(account_for("notion"), JSON.generate(
      "serverUrl" => "https://mcp.notion.com/mcp",
      "tokens" => { "accessToken" => 12_345, "refreshToken" => "r" }
    ))
    assert_empty @writer.read_runtime_credentials([ "notion" ])

    stub_keyring_read(account_for("notion"), JSON.generate(
      "serverUrl" => "https://mcp.notion.com/mcp",
      "tokens" => { "accessToken" => "a", "refreshToken" => { "nested" => true } }
    ))
    assert_empty @writer.read_runtime_credentials([ "notion" ])
  end

  test "read_runtime_credentials rejects chunks that do not reassemble to the recorded digest" do
    # The adapter records sha256(payload)[0,16] over what it split. A reassembly
    # that parses as JSON but does not match it is corruption, not a token.
    account = account_for("notion")
    payload = stored_entry
    manifest = JSON.generate(
      PiMcpCredentialWriter::CHUNK_MANIFEST_KEY => 1,
      "chunkCount" => 1,
      "chunkDigest" => "0" * 16
    )
    @writer.unstub(:keyring_call)
    @writer.stubs(:keyring_call).returns({ "ok" => true, "found" => false })
    @writer.stubs(:keyring_call).with("read", account, timeout: PiMcpCredentialWriter::READ_TIMEOUT_SECONDS)
      .returns({ "ok" => true, "found" => true, "value" => manifest })
    @writer.stubs(:keyring_call).with("read", "#{account}.chunk.#{'0' * 16}.0", timeout: PiMcpCredentialWriter::READ_TIMEOUT_SECONDS)
      .returns({ "ok" => true, "found" => true, "value" => payload })

    assert_empty @writer.read_runtime_credentials([ "notion" ])
  end

  test "read_runtime_credentials answers {} for a key with no entry, a corrupt entry, or no keys" do
    assert_empty @writer.read_runtime_credentials([ "notion" ])
    assert_empty @writer.read_runtime_credentials
    assert_empty @writer.read_runtime_credentials([ nil, "" ])

    stub_keyring_read(account_for("notion"), "not json")
    assert_empty @writer.read_runtime_credentials([ "notion" ])

    stub_keyring_read(account_for("notion"), JSON.generate("serverUrl" => "https://x/mcp"))
    assert_empty @writer.read_runtime_credentials([ "notion" ]), "an entry with no tokens is nothing to adopt"
  end

  test "a credential store that will not answer is nothing to adopt, not a raise" do
    @writer.unstub(:keyring_call)
    @writer.stubs(:keyring_call).raises("keyring helper timed out after 5s")

    assert_empty @writer.read_runtime_credentials([ "notion" ])
  end

  test "read_runtime_credentials only reads the store, never the pending file" do
    # The pending file only ever holds what Zimmer staged, so reading it back
    # could only echo the DB. Reading it as an adoption candidate would let a
    # spawn re-adopt its own write.
    @writer.write!(working_directory: "/clone", credentials: [ credential ])
    assert_path_exists entry_path("notion")

    assert_empty @writer.read_runtime_credentials([ "notion" ])
  end

  test "clear_needs_auth_cache is a no-op — Pi keeps no needs-auth memo" do
    assert_equal [], @writer.clear_needs_auth_cache([ "notion" ])
  end

  test "delete_credentials removes the staged file and reports the key" do
    @writer.write!(working_directory: "/clone", credentials: [ credential ])

    assert_equal [ "notion" ], @writer.delete_credentials([ "notion" ])
    refute_path_exists entry_path("notion")
  end

  test "delete_credentials removes the credential-store entry too" do
    account = account_for("notion")
    @writer.unstub(:keyring_call)
    @writer.stubs(:keyring_call).with("read", account).returns({ "ok" => true, "found" => true, "value" => "{}" })
    @writer.expects(:keyring_call).with("remove", account).returns({ "ok" => true })

    assert_equal [ "notion" ], @writer.delete_credentials([ "notion" ])
  end

  test "delete_credentials reports nothing when there was nothing stored" do
    assert_empty @writer.delete_credentials([ "notion" ])
  end

  test "oauth_dir honours the MCP_OAUTH_DIR override the adapter reads first" do
    writer = PiMcpCredentialWriter.new
    ENV.stubs(:[]).with("MCP_OAUTH_DIR").returns("/custom/oauth")

    assert_equal "/custom/oauth", writer.oauth_dir
  end

  test "oauth_dir otherwise resolves under Pi's agent directory" do
    writer = PiMcpCredentialWriter.new
    ENV.stubs(:[]).with("MCP_OAUTH_DIR").returns(nil)
    PiHome.stubs(:mcp_oauth_dir_path).returns("/home/rails/.pi/agent/mcp-oauth")

    assert_equal "/home/rails/.pi/agent/mcp-oauth", writer.oauth_dir
  end

  test "RuntimeRegistry routes Pi's MCP credentials through this writer" do
    assert_equal PiMcpCredentialWriter, RuntimeRegistry.for("pi").mcp_credential_writer_class
  end
end

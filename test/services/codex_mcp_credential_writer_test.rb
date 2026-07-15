# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CodexMcpCredentialWriterTest < ActiveSupport::TestCase
  setup do
    @writer = CodexMcpCredentialWriter.new
    # Keep tests deterministic across platforms: never touch the real Keychain.
    @writer.stubs(:macos?).returns(false)
    @working_directory = Dir.mktmpdir("codex-mcp-writer-test")
    @credentials_file = File.join(@working_directory, ".credentials.json")
  end

  teardown do
    FileUtils.rm_rf(@working_directory) if @working_directory && File.exist?(@working_directory)
  end

  test "credential_key_for hashes {type:http,url,headers:{}} regardless of real transport" do
    # Codex always hashes with the literal type "http" and empty headers, so an
    # sse server and a streamable-http server with the same URL share a key, and
    # configured headers do not affect it.
    sse_config = { type: "sse", url: "https://mcp.notion.com/sse", headers: { "X-Token" => "secret" } }
    http_config = { type: "streamable-http", url: "https://mcp.notion.com/sse", headers: {} }

    expected_hash = Digest::SHA256.hexdigest('{"type":"http","url":"https://mcp.notion.com/sse","headers":{}}')[0, 16]
    expected_key = "notion|#{expected_hash}"

    assert_equal expected_key, @writer.credential_key_for("notion", sse_config)
    assert_equal expected_key, @writer.credential_key_for("notion", http_config)
  end

  test "credential_key_for differs from the Claude/DB key for non-http transports" do
    # The runtime-agnostic DB key preserves the real type ("sse"); Codex's key
    # forces "http". They must NOT collide for an sse server.
    config = { type: "sse", url: "https://mcp.example.com/sse", headers: {} }

    assert_not_equal McpOauthCredential.compute_credential_key("ex", config),
      @writer.credential_key_for("ex", config)
  end

  test "write! writes the flat Codex file entry format keyed by credential_key" do
    expires_at = Time.at(1_768_098_636).utc
    credential = resolved_credential(
      credential_key: "notion|abc123",
      server_name: "notion",
      server_url: "https://mcp.notion.com/sse",
      client_id: "client-123",
      access_token: "access-token-xyz",
      refresh_token: "refresh-token-123",
      expires_at: expires_at,
      scope: "openid profile"
    )

    with_credentials_path(@credentials_file) do
      path = @writer.write!(working_directory: @working_directory, credentials: [ credential ])
      assert_equal @credentials_file, path
    end

    data = JSON.parse(File.read(@credentials_file))
    # Flat map keyed by "<name>|<hash>" — no envelope wrapper.
    entry = data["notion|abc123"]

    assert_equal "notion", entry["server_name"]
    assert_equal "https://mcp.notion.com/sse", entry["server_url"]
    assert_equal "client-123", entry["client_id"]
    assert_equal "access-token-xyz", entry["access_token"]
    assert_equal "refresh-token-123", entry["refresh_token"]
    # scopes is an ARRAY of strings
    assert_equal [ "openid", "profile" ], entry["scopes"]
    # expires_at is milliseconds since epoch
    assert_equal (expires_at.to_f * 1000).to_i, entry["expires_at"]
  end

  test "write! emits an empty scopes array when scope is blank" do
    credential = resolved_credential(credential_key: "noscope|key", scope: nil)

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ credential ])
    end

    entry = JSON.parse(File.read(@credentials_file))["noscope|key"]
    assert_equal [], entry["scopes"]
  end

  test "write! omits expires_at and refresh_token when absent" do
    credential = resolved_credential(
      credential_key: "noexpiry|def456",
      refresh_token: nil,
      expires_at: nil
    )

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ credential ])
    end

    entry = JSON.parse(File.read(@credentials_file))["noexpiry|def456"]
    assert_not entry.key?("expires_at"), "expires_at should be omitted when expires_at is nil"
    assert_not entry.key?("refresh_token"), "refresh_token should be omitted when refresh_token is nil"
  end

  test "write! merges with existing entries and preserves unrelated keys" do
    File.write(@credentials_file, JSON.pretty_generate({
      "existing|key" => { "server_name" => "existing" }
    }))

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ resolved_credential(credential_key: "new|key") ])
    end

    data = JSON.parse(File.read(@credentials_file))
    assert data["existing|key"].present?, "existing entries must be preserved"
    assert data["new|key"].present?, "new entry must be merged in"
  end

  test "write! writes the file with 0600 permissions" do
    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ resolved_credential ])
    end

    mode = File.stat(@credentials_file).mode & 0o777
    assert_equal 0o600, mode
  end

  test "write! returns nil when there are no credentials" do
    with_credentials_path(@credentials_file) do
      assert_nil @writer.write!(working_directory: @working_directory, credentials: [])
    end
    assert_not File.exist?(@credentials_file), "no file should be written when there are no credentials"
  end

  test "write! on macOS writes one raw-JSON StoredOAuthTokens item per server to the Keychain" do
    @writer.stubs(:macos?).returns(true)

    captured = []
    success_status = mock("status")
    success_status.stubs(:success?).returns(true)
    Open3.stubs(:capture3).with do |*args, **kwargs|
      captured << kwargs[:stdin_data] if args == [ "security", "-i" ]
      true
    end.returns([ "", "", success_status ])

    credential = resolved_credential(
      credential_key: "notion|abc123",
      access_token: "access-token-xyz",
      refresh_token: "refresh-token-123",
      expires_at: Time.at(1_768_098_636).utc,
      scope: "openid profile"
    )

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ credential ])
    end

    assert_equal 1, captured.size, "one Keychain item per server"
    stdin = captured.first
    # Account is the credential_key, service is the Codex service name.
    assert_match(/add-generic-password -U -a "notion\|abc123" -s "Codex MCP Credentials"/, stdin)

    # The value is the raw (unencoded) JSON of StoredOAuthTokens.
    blob = stdin[/-w "(\{.*\})"\s*\z/m, 1]
    decoded = JSON.parse(blob)
    assert_equal "notion", decoded["server_name"]
    # Keychain blob uses `url` (not `server_url`) and nests tokens under token_response.
    assert_equal "https://mcp.notion.com/sse", decoded["url"]
    assert_equal "access-token-xyz", decoded.dig("token_response", "access_token")
    assert_equal "bearer", decoded.dig("token_response", "token_type")
    assert_equal "refresh-token-123", decoded.dig("token_response", "refresh_token")
    # scope is a single space-delimited string in the keychain blob.
    assert_equal "openid profile", decoded.dig("token_response", "scope")
    assert_equal (Time.at(1_768_098_636).utc.to_f * 1000).to_i, decoded["expires_at"]
  end

  test "read_runtime_credentials parses the flat file entries into snapshots" do
    expires_ms = ((Time.current + 42.minutes).to_f * 1000).to_i
    File.write(@credentials_file, JSON.generate(
      "notion|abc123" => {
        "server_name" => "notion",
        "access_token" => "on-disk-access",
        "refresh_token" => "on-disk-refresh",
        "expires_at" => expires_ms
      }
    ))

    snapshots = with_credentials_path(@credentials_file) { @writer.read_runtime_credentials }

    snapshot = snapshots["notion|abc123"]
    assert_equal "on-disk-access", snapshot.access_token
    assert_equal "on-disk-refresh", snapshot.refresh_token
    assert_in_delta expires_ms / 1000, snapshot.expires_at.to_i, 1
  end

  test "read_runtime_credentials returns {} when the file is absent or corrupt" do
    missing = File.join(@working_directory, "does-not-exist.json")
    assert_empty(with_credentials_path(missing) { @writer.read_runtime_credentials })

    File.write(@credentials_file, "{ not json")
    assert_empty(with_credentials_path(@credentials_file) { @writer.read_runtime_credentials })
  end

  private

  def resolved_credential(**overrides)
    defaults = {
      server_name: "notion",
      server_url: "https://mcp.notion.com/sse",
      client_id: "client-123",
      access_token: "access-token-xyz",
      refresh_token: "refresh-token-123",
      expires_at: Time.at(1_768_098_636).utc,
      scope: nil,
      headers: {},
      credential_key: "notion|abc123"
    }
    ResolvedMcpCredential.new(**defaults.merge(overrides))
  end

  # Swaps the frozen credentials-path constant to a temp file for the duration of
  # the block so tests never touch the real ~/.codex/.credentials.json.
  def with_credentials_path(path)
    klass = CodexMcpCredentialWriter
    original = klass::CODEX_CREDENTIALS_PATH
    klass.send(:remove_const, :CODEX_CREDENTIALS_PATH)
    klass.const_set(:CODEX_CREDENTIALS_PATH, path)
    yield
  ensure
    klass.send(:remove_const, :CODEX_CREDENTIALS_PATH)
    klass.const_set(:CODEX_CREDENTIALS_PATH, original)
  end
end

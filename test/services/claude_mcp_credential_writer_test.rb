# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ClaudeMcpCredentialWriterTest < ActiveSupport::TestCase
  setup do
    @writer = ClaudeMcpCredentialWriter.new
    # Keep tests deterministic across platforms: never touch the real Keychain.
    @writer.stubs(:macos?).returns(false)
    @working_directory = Dir.mktmpdir("claude-mcp-writer-test")
    @credentials_file = File.join(@working_directory, ".credentials.json")
  end

  teardown do
    FileUtils.rm_rf(@working_directory) if @working_directory && File.exist?(@working_directory)
  end

  test "credential_key_for delegates to McpOauthCredential.compute_credential_key" do
    server_config = { type: "streamable-http", url: "https://mcp.notion.com/v1/mcp", headers: {} }
    expected = McpOauthCredential.compute_credential_key("notion", server_config)

    assert_equal expected, @writer.credential_key_for("notion", server_config)
  end

  test "write! writes the Claude mcpOAuth entry format to the credentials file" do
    expires_at = Time.at(1_768_098_636).utc
    credential = resolved_credential(
      credential_key: "notion|abc123",
      server_name: "notion",
      server_url: "https://mcp.notion.com/v1/mcp",
      client_id: "client-123",
      access_token: "access-token-xyz",
      refresh_token: "refresh-token-123",
      expires_at: expires_at
    )

    with_credentials_path(@credentials_file) do
      path = @writer.write!(working_directory: @working_directory, credentials: [ credential ])
      assert_equal @credentials_file, path
    end

    data = JSON.parse(File.read(@credentials_file))
    entry = data.dig("mcpOAuth", "notion|abc123")

    assert_equal "notion", entry["serverName"]
    assert_equal "https://mcp.notion.com/v1/mcp", entry["serverUrl"]
    assert_equal "client-123", entry["clientId"]
    assert_equal "access-token-xyz", entry["accessToken"]
    assert_equal "refresh-token-123", entry["refreshToken"]
    assert_equal "", entry["scope"]
    # expiresAt is milliseconds since epoch
    assert_equal (expires_at.to_f * 1000).to_i, entry["expiresAt"]
  end

  test "write! omits expiresAt and refreshToken when absent" do
    credential = resolved_credential(
      credential_key: "noexpiry|def456",
      refresh_token: nil,
      expires_at: nil
    )

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ credential ])
    end

    entry = JSON.parse(File.read(@credentials_file)).dig("mcpOAuth", "noexpiry|def456")
    assert_not entry.key?("expiresAt"), "expiresAt should be omitted when expires_at is nil"
    assert_not entry.key?("refreshToken"), "refreshToken should be omitted when refresh_token is nil"
  end

  test "write! merges with existing credentials and preserves unrelated keys" do
    File.write(@credentials_file, JSON.pretty_generate({
      "claudeAiOauth" => { "accessToken" => "keep-me" },
      "mcpOAuth" => { "existing|key" => { "serverName" => "existing" } }
    }))

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ resolved_credential(credential_key: "new|key") ])
    end

    data = JSON.parse(File.read(@credentials_file))
    assert_equal "keep-me", data.dig("claudeAiOauth", "accessToken"), "unrelated top-level keys must be preserved"
    assert data.dig("mcpOAuth", "existing|key").present?, "existing mcpOAuth entries must be preserved"
    assert data.dig("mcpOAuth", "new|key").present?, "new mcpOAuth entry must be merged in"
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

  test "write! on macOS writes hex-encoded JSON to the Keychain" do
    @writer.stubs(:macos?).returns(true)
    @writer.stubs(:read_keychain_data).returns({})

    captured_stdin = nil
    success_status = mock("status")
    success_status.stubs(:success?).returns(true)
    Open3.stubs(:capture3).with do |*args, **kwargs|
      captured_stdin = kwargs[:stdin_data] if args == [ "security", "-i" ]
      true
    end.returns([ "", "", success_status ])

    credential = resolved_credential(credential_key: "notion|abc123", access_token: "access-token-xyz")

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ credential ])
    end

    assert_match(/add-generic-password -U -a/, captured_stdin)
    # The hex blob decodes back to the merged credentials JSON.
    hex = captured_stdin[/-X "([0-9a-f]+)"/, 1]
    decoded = JSON.parse([ hex ].pack("H*"))
    assert_equal "access-token-xyz", decoded.dig("mcpOAuth", "notion|abc123", "accessToken")
  end

  # --- merge-guard: preserve fresher runtime-written tokens ---

  test "write! preserves an existing entry that is still valid and fresher than Zimmer's" do
    runtime_expiry_ms = (2.hours.from_now.to_f * 1000).to_i
    File.write(@credentials_file, JSON.pretty_generate({
      "mcpOAuth" => {
        "notion|abc123" => {
          "serverName" => "notion",
          "accessToken" => "runtime-fresh-token",
          "expiresAt" => runtime_expiry_ms
        }
      }
    }))

    # Zimmer's incoming token expires sooner than the runtime one.
    zimmer_credential = resolved_credential(
      credential_key: "notion|abc123",
      access_token: "zimmer-stale-token",
      expires_at: 1.hour.from_now
    )

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ zimmer_credential ])
    end

    entry = JSON.parse(File.read(@credentials_file)).dig("mcpOAuth", "notion|abc123")
    assert_equal "runtime-fresh-token", entry["accessToken"], "must keep the fresher runtime token"
  end

  test "write! overwrites an existing entry that Zimmer's token is newer than" do
    runtime_expiry_ms = (1.hour.from_now.to_f * 1000).to_i
    File.write(@credentials_file, JSON.pretty_generate({
      "mcpOAuth" => {
        "notion|abc123" => {
          "serverName" => "notion",
          "accessToken" => "runtime-older-token",
          "expiresAt" => runtime_expiry_ms
        }
      }
    }))

    zimmer_credential = resolved_credential(
      credential_key: "notion|abc123",
      access_token: "zimmer-newer-token",
      expires_at: 3.hours.from_now
    )

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ zimmer_credential ])
    end

    entry = JSON.parse(File.read(@credentials_file)).dig("mcpOAuth", "notion|abc123")
    assert_equal "zimmer-newer-token", entry["accessToken"], "Zimmer's newer token must win"
  end

  test "write! overwrites an existing entry that has already expired" do
    runtime_expiry_ms = (1.hour.ago.to_f * 1000).to_i
    File.write(@credentials_file, JSON.pretty_generate({
      "mcpOAuth" => {
        "notion|abc123" => {
          "serverName" => "notion",
          "accessToken" => "runtime-expired-token",
          "expiresAt" => runtime_expiry_ms
        }
      }
    }))

    zimmer_credential = resolved_credential(
      credential_key: "notion|abc123",
      access_token: "zimmer-token",
      expires_at: 1.hour.from_now
    )

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ zimmer_credential ])
    end

    entry = JSON.parse(File.read(@credentials_file)).dig("mcpOAuth", "notion|abc123")
    assert_equal "zimmer-token", entry["accessToken"], "Zimmer's token must replace the expired runtime token"
  end

  test "write! overwrites an existing entry that has no recorded expiry" do
    File.write(@credentials_file, JSON.pretty_generate({
      "mcpOAuth" => {
        "notion|abc123" => {
          "serverName" => "notion",
          "accessToken" => "runtime-no-expiry-token"
        }
      }
    }))

    zimmer_credential = resolved_credential(
      credential_key: "notion|abc123",
      access_token: "zimmer-token",
      expires_at: 1.hour.from_now
    )

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ zimmer_credential ])
    end

    entry = JSON.parse(File.read(@credentials_file)).dig("mcpOAuth", "notion|abc123")
    assert_equal "zimmer-token", entry["accessToken"], "Zimmer's entry must win when existing has no expiry"
  end

  test "write! keeps a still-valid runtime entry when Zimmer's incoming token has no expiry" do
    runtime_expiry_ms = (2.hours.from_now.to_f * 1000).to_i
    File.write(@credentials_file, JSON.pretty_generate({
      "mcpOAuth" => {
        "notion|abc123" => {
          "serverName" => "notion",
          "accessToken" => "runtime-valid-token",
          "expiresAt" => runtime_expiry_ms
        }
      }
    }))

    # Zimmer's incoming token has no recorded expiry — it is not demonstrably fresher
    # than the still-valid runtime entry, so the runtime entry is preserved.
    zimmer_credential = resolved_credential(
      credential_key: "notion|abc123",
      access_token: "zimmer-no-expiry-token",
      expires_at: nil
    )

    with_credentials_path(@credentials_file) do
      @writer.write!(working_directory: @working_directory, credentials: [ zimmer_credential ])
    end

    entry = JSON.parse(File.read(@credentials_file)).dig("mcpOAuth", "notion|abc123")
    assert_equal "runtime-valid-token", entry["accessToken"], "must keep the still-valid runtime token when Zimmer's has no expiry"
  end

  private

  def resolved_credential(**overrides)
    defaults = {
      server_name: "notion",
      server_url: "https://mcp.notion.com/v1/mcp",
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
  # the block so tests never touch the real ~/.claude/.credentials.json.
  def with_credentials_path(path)
    klass = ClaudeMcpCredentialWriter
    original = klass::CLAUDE_CREDENTIALS_PATH
    klass.send(:remove_const, :CLAUDE_CREDENTIALS_PATH)
    klass.const_set(:CLAUDE_CREDENTIALS_PATH, path)
    yield
  ensure
    klass.send(:remove_const, :CLAUDE_CREDENTIALS_PATH)
    klass.const_set(:CLAUDE_CREDENTIALS_PATH, original)
  end
end

# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "tmpdir"

class ClaudeLoginDriverTest < ActiveSupport::TestCase
  # The authorization URL as `claude auth login --claudeai` prints it, captured
  # byte-for-byte off CLI 2.1.232 under a PTY into a scratch CLAUDE_CONFIG_DIR —
  # the same spawn RuntimeLoginJob performs. The CLI renders the link as an OSC 8
  # hyperlink, so the URL appears twice: once as the escape sequence's target and
  # once as its visible label, with a BEL between them and a closing
  # `ESC ] 8 ; ; BEL` after. Split across constants only so the query string stays
  # readable; concatenated it is exactly what the CLI wrote.
  CAPTURED_URL =
    "https://claude.com/cai/oauth/authorize?code=true" \
    "&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code" \
    "&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback" \
    "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference" \
    "+user%3Asessions%3Aclaude_code+user%3Amcp_servers+user%3Afile_upload" \
    "&code_challenge=wPNXozKm6JTE2heYH0lGD8PzpzWYYbEeJlzzO3UhF2E" \
    "&code_challenge_method=S256&state=r8GeBLJt4jvkaRUllH6fBEMfngSWM6Kfurirlyc6Vn4"

  CAPTURED_LOGIN_OUTPUT =
    "Opening browser to sign in…\r\n" \
    "If the browser didn't open, visit: " \
    "\e]8;;#{CAPTURED_URL}\a#{CAPTURED_URL}\e]8;;\a\r\n" \
    "Paste code here if prompted > "

  setup do
    # capture! probes the freshly-minted token against Anthropic before the
    # account enters the pool. Default to a token Anthropic honours.
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true, utilization_5h: 0.1, utilization_7d: 0.1,
        status_5h: "allowed", status_7d: "allowed"
      )
    )

    @driver = ClaudeLoginDriver.new
    @account = ClaudeAccount.create!(
      email: "claude-login-driver@example.com", runtime: "claude_code",
      status: :needs_reauth, is_current: false, priority: 51, oauth_config: {}
    )
  end

  test "completion_mode is paste and exposes the paste prompt" do
    assert_equal :paste, @driver.completion_mode
    assert_match @driver.paste_prompt, "Paste code here if prompted >"
  end

  test "parse_verification matches the claudeai authorize URL" do
    raw = "Visit https://claude.com/cai/oauth/authorize?code=abc&state=xyz to continue"
    details = @driver.parse_verification(@driver.strip_ansi(raw))
    assert_equal "https://claude.com/cai/oauth/authorize?code=abc&state=xyz", details[:url]
    assert_nil details[:code]
  end

  test "parse_verification extracts the exact URL from live OSC 8 hyperlinked output" do
    # The regression: the CLI started hyperlinking its authorization link, and a
    # `\S+` tail ran straight through the BEL terminator, the duplicated visible
    # label and the closing escape — yielding a 907-character string that no
    # browser could open, so the login could never be completed.
    details = @driver.parse_verification(@driver.strip_ansi(CAPTURED_LOGIN_OUTPUT))
    assert_equal CAPTURED_URL, details[:url]
    assert_nil details[:code]
  end

  test "the paste prompt is still recognized in live hyperlinked output" do
    assert_match @driver.paste_prompt, @driver.strip_ansi(CAPTURED_LOGIN_OUTPUT)
  end

  test "parse_verification stops at a BEL when an unrecognized escape survives stripping" do
    # Defence in depth, independent of what strip_ansi knows how to remove: an
    # APC sequence is deliberately not stripped, so this exercises URL_CHAR alone
    # — whatever decoration a future CLI wraps the link in, the match must end at
    # the first control byte rather than swallow the rest.
    raw = "visit: \x1b_unknown-sequence;https://claude.com/cai/oauth/authorize?state=abc\x07trailing"
    assert_equal "https://claude.com/cai/oauth/authorize?state=abc",
      @driver.parse_verification(@driver.strip_ansi(raw))[:url]
  end

  test "parse_verification matches the platform (console) authorize URL" do
    details = @driver.parse_verification("https://platform.claude.com/oauth/authorize?x=1")
    assert_equal "https://platform.claude.com/oauth/authorize?x=1", details[:url]
  end

  test "capture! stores credentials and activates when the email matches" do
    Dir.mktmpdir do |dir|
      write_claude_config(dir, email: @account.email)
      @driver.capture!(dir, @account)
      @account.reload
      assert @account.active?
      assert_equal "at-1", @account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      assert_equal @account.email, @account.oauth_config.dig("claude_json", "oauthAccount", "emailAddress")
    end
  end

  test "capture! reads credentials nested under .claude/" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      File.write(File.join(dir, ".claude.json"),
        JSON.generate({ "oauthAccount" => { "emailAddress" => @account.email } }))
      File.write(File.join(dir, ".claude", ".credentials.json"),
        JSON.generate({ "claudeAiOauth" => { "accessToken" => "at-nested", "refreshToken" => "rt-nested" } }))
      @driver.capture!(dir, @account)
      assert @account.reload.active?
      assert_equal "at-nested", @account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    end
  end

  test "capture! raises on an email identity mismatch" do
    Dir.mktmpdir do |dir|
      write_claude_config(dir, email: "someone-else@example.com")
      error = assert_raises(RuntimeError) { @driver.capture!(dir, @account) }
      assert_match(/authenticated as someone-else@example.com/, error.message)
      assert_not @account.reload.active?
    end
  end

  test "capture! raises when credentials are missing" do
    Dir.mktmpdir do |dir|
      error = assert_raises(RuntimeError) { @driver.capture!(dir, @account) }
      assert_match(/did not produce credentials/, error.message)
    end
  end

  test "capture! raises when the oauth token pair is incomplete" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".claude.json"),
        JSON.generate({ "oauthAccount" => { "emailAddress" => @account.email } }))
      File.write(File.join(dir, ".credentials.json"),
        JSON.generate({ "claudeAiOauth" => { "accessToken" => "at-only" } }))
      error = assert_raises(RuntimeError) { @driver.capture!(dir, @account) }
      assert_match(/incomplete/, error.message)
    end
  end

  test "capture! raises when Anthropic rejects the freshly-minted token" do
    # A complete token pair is not a working one. Installing it would put an
    # account into the pool that fails the first time rotation reaches it (#239).
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: false, unreachable: false,
        error_message: "No rate-limit headers in response (HTTP 401). Token may be expired or invalid."
      )
    )

    Dir.mktmpdir do |dir|
      write_claude_config(dir, email: @account.email)
      error = assert_raises(RuntimeError) { @driver.capture!(dir, @account) }
      assert_match(/Anthropic rejected/, error.message)
      assert_not @account.reload.active?
      assert_empty @account.oauth_config
    end
  end

  test "capture! completes when the probe cannot reach Anthropic" do
    # Unreachable is evidence about the network, not the credentials — a login the
    # user completed must not be thrown away over an API blip.
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: false, unreachable: true, error_message: "API request timed out: execution expired"
      )
    )

    Dir.mktmpdir do |dir|
      write_claude_config(dir, email: @account.email)
      @driver.capture!(dir, @account)
      assert @account.reload.active?
      assert_equal "at-1", @account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    end
  end

  test "credentials_ready? is true only once a complete oauth token pair is on disk" do
    Dir.mktmpdir do |dir|
      write_identity(dir, email: @account.email)
      assert_not @driver.credentials_ready?(dir), "no credentials file yet"

      # A half-written file (accessToken only) must not trip a premature capture.
      File.write(File.join(dir, ".credentials.json"),
        JSON.generate({ "claudeAiOauth" => { "accessToken" => "at-only" } }))
      assert_not @driver.credentials_ready?(dir), "incomplete token pair is not ready"

      File.write(File.join(dir, ".credentials.json"),
        JSON.generate({ "claudeAiOauth" => { "accessToken" => "at", "refreshToken" => "rt" } }))
      assert @driver.credentials_ready?(dir), "complete token pair is ready"
    end
  end

  test "credentials_ready? stays false until the identity file lands, so capture!'s email guard runs" do
    Dir.mktmpdir do |dir|
      # Complete token pair on disk, but no .claude.json identity yet. Capturing
      # here would skip the email-identity check, so the predicate must hold off.
      File.write(File.join(dir, ".credentials.json"),
        JSON.generate({ "claudeAiOauth" => { "accessToken" => "at", "refreshToken" => "rt" } }))
      assert_not @driver.credentials_ready?(dir), "must not capture before identity is written"

      write_identity(dir, email: @account.email)
      assert @driver.credentials_ready?(dir), "ready once both credentials and identity are present"
    end
  end

  test "credentials_ready? tolerates a mid-write (unparseable) credentials file" do
    Dir.mktmpdir do |dir|
      write_identity(dir, email: @account.email)
      File.write(File.join(dir, ".credentials.json"), '{"claudeAiOauth":{"accessToken"')
      assert_not @driver.credentials_ready?(dir)
    end
  end

  test "credentials_ready? tolerates a non-Hash credentials file without raising" do
    Dir.mktmpdir do |dir|
      write_identity(dir, email: @account.email)
      File.write(File.join(dir, ".credentials.json"), "[]")
      assert_not @driver.credentials_ready?(dir)
    end
  end

  test "login_failure_hint surfaces the CLI's Login failed line (the real DNS/network cause)" do
    raw = "Opening browser to sign in…\n" \
      "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=xyz\n" \
      "Paste code here if prompted > Login failed: getaddrinfo ESERVFAIL platform.claude.com\n"
    assert_equal "Login failed: getaddrinfo ESERVFAIL platform.claude.com",
      @driver.login_failure_hint(@driver.strip_ansi(raw))
  end

  test "login_failure_hint returns the last failure line when the CLI retried" do
    raw = "Paste code here if prompted > Invalid code. Please make sure the full code was copied.\n" \
      "Paste code here if prompted > Login failed: getaddrinfo ESERVFAIL platform.claude.com\n"
    assert_equal "Login failed: getaddrinfo ESERVFAIL platform.claude.com",
      @driver.login_failure_hint(@driver.strip_ansi(raw))
  end

  test "login_failure_hint prefers the most recent failure line across patterns" do
    # A later expired/invalid-code line must win over an earlier "Login failed:"
    # line even though a different pattern matches each — recency, not pattern order.
    raw = "Login failed: token exchange transient blip\n" \
      "The code you entered is invalid or has expired.\n"
    hint = @driver.login_failure_hint(@driver.strip_ansi(raw))
    assert_match(/invalid or has expired/, hint)
    assert_no_match(/transient blip/, hint)
  end

  test "login_failure_hint matches a rejected pasted code" do
    raw = "Paste code here if prompted > Invalid code. Please make sure the full code was copied.\n"
    assert_equal "Invalid code. Please make sure the full code was copied.",
      @driver.login_failure_hint(@driver.strip_ansi(raw))
  end

  test "login_failure_hint returns nil for benign output so URL/prompt noise is never surfaced" do
    raw = "Opening browser to sign in…\n" \
      "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=xyz\n" \
      "Paste code here if prompted > \n"
    assert_nil @driver.login_failure_hint(@driver.strip_ansi(raw))
    assert_nil @driver.login_failure_hint("")
  end

  test "login_failure_hint truncates an overlong failure line" do
    raw = "Login failed: #{"x" * 500}"
    hint = @driver.login_failure_hint(raw)
    assert_operator hint.length, :<=, 200
    assert hint.end_with?("...")
  end

  test "credentials_ready? finds credentials nested under .claude/" do
    Dir.mktmpdir do |dir|
      write_identity(dir, email: @account.email)
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      File.write(File.join(dir, ".claude", ".credentials.json"),
        JSON.generate({ "claudeAiOauth" => { "accessToken" => "at", "refreshToken" => "rt" } }))
      assert @driver.credentials_ready?(dir)
    end
  end

  private

  # ---------------------------------------------- hole 2: capture! reaches disk

  test "capture! writes the shared credentials file when the account is current" do
    tmp_home = Dir.mktmpdir
    original_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    original_credentials = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmp_home, "claude.json"))
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmp_home, ".credentials.json"))

    # The trap this closes: the account being re-authenticated IS the one whose
    # credentials are live, and the live file holds the CLI's blanked tokens.
    # Before the fix, capture! wrote only the DB and every session kept reading
    # the broken file while the UI reported success.
    FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH,
      JSON.generate({ "claudeAiOauth" => { "accessToken" => "", "refreshToken" => "", "expiresAt" => 0 } }))
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    ClaudeAccount.for_runtime("claude_code").update_all(is_current: false)
    @account.update!(is_current: true)

    Dir.mktmpdir do |dir|
      write_claude_config(dir, email: @account.email)
      @driver.capture!(dir, @account)
    end

    on_disk = JSON.parse(File.read(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
    assert_equal "at-1", on_disk.dig("claudeAiOauth", "accessToken")
    assert_equal "rt-1", on_disk.dig("claudeAiOauth", "refreshToken")
    assert_equal @account.email, ClaudeAccount.credentials_owner_email
  ensure
    FileUtils.rm_rf(tmp_home)
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_claude_json)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_credentials)
  end

  test "capture! leaves the filesystem alone for an account that is not current" do
    AccountRotationService.any_instance.expects(:write_config!).never

    Dir.mktmpdir do |dir|
      write_claude_config(dir, email: @account.email)
      @driver.capture!(dir, @account)
    end
  end

  def write_claude_config(dir, email:)
    write_identity(dir, email: email)
    File.write(File.join(dir, ".credentials.json"),
      JSON.generate({ "claudeAiOauth" => { "accessToken" => "at-1", "refreshToken" => "rt-1" } }))
  end

  def write_identity(dir, email:)
    File.write(File.join(dir, ".claude.json"),
      JSON.generate({ "oauthAccount" => { "emailAddress" => email } }))
  end
end

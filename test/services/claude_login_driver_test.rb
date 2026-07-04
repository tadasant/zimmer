# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class ClaudeLoginDriverTest < ActiveSupport::TestCase
  setup do
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

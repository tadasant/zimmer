# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class CodexLoginDriverTest < ActiveSupport::TestCase
  setup do
    @driver = CodexLoginDriver.new
    # A fresh codex account with no credentials, like a placeholder row the user
    # is authenticating for the first time.
    @account = ClaudeAccount.create!(
      email: "codex-login-driver@example.com", runtime: "codex",
      status: :needs_reauth, is_current: false, priority: 50, oauth_config: {}
    )
  end

  test "completion_mode is poll" do
    assert_equal :poll, @driver.completion_mode
  end

  test "parse_verification extracts the device URL and one-time code from real CLI output" do
    # Verbatim shape of `codex login --device-auth` output captured live under a
    # PTY, including the PATH warning that echoes the date-stamped scratch
    # CODEX_HOME and the 4-5 split one-time code.
    raw = <<~OUT
      \e[2J\e[HWARNING: proceeding, even though we could not update PATH: Refusing to create helper binaries under temporary dir "/tmp" (codex_home: AbsolutePathBuf("/tmp/runtime-login-codex-20260601-18255-2oamu"))

      Welcome to Codex [v0.133.0]

      1. Open this link in your browser and sign in to your account

         https://auth.openai.com/codex/device

      2. Enter this one-time code (expires in 15 minutes)

         \e[1mZ0PC-EQL0R\e[0m
    OUT
    details = @driver.parse_verification(@driver.strip_ansi(raw))
    assert_equal "https://auth.openai.com/codex/device", details[:url]
    assert_equal "Z0PC-EQL0R", details[:code], "must extract the 4-5 split code, not the date-stamped scratch path"
  end

  test "parse_verification matches the chatgpt.com device host too" do
    details = @driver.parse_verification("go to https://chatgpt.com/device please")
    assert_equal "https://chatgpt.com/device", details[:url]
  end

  test "capture! stores OAuth auth.json verbatim and activates the account" do
    Dir.mktmpdir do |dir|
      auth = {
        "tokens" => {
          "id_token" => "id", "access_token" => "at",
          "refresh_token" => "rt", "account_id" => "acct"
        },
        "last_refresh" => "2026-06-01T00:00:00Z"
      }
      File.write(File.join(dir, "auth.json"), JSON.generate(auth))

      @driver.capture!(dir, @account)
      @account.reload
      assert @account.active?
      assert_equal auth, @account.oauth_config["auth_json"]
    end
  end

  test "capture! accepts an API-key-only auth.json" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "auth.json"), JSON.generate({ "OPENAI_API_KEY" => "sk-xyz" }))
      @driver.capture!(dir, @account)
      assert @account.reload.active?
      assert_equal "sk-xyz", @account.oauth_config["auth_json"]["OPENAI_API_KEY"]
    end
  end

  test "capture! raises when auth.json is missing" do
    Dir.mktmpdir do |dir|
      error = assert_raises(RuntimeError) { @driver.capture!(dir, @account) }
      assert_match(/did not produce auth.json/, error.message)
    end
  end

  test "capture! raises when auth.json has neither tokens nor an API key" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "auth.json"), JSON.generate({ "tokens" => {} }))
      error = assert_raises(RuntimeError) { @driver.capture!(dir, @account) }
      assert_match(/missing both OAuth tokens and an API key/, error.message)
    end
  end
end

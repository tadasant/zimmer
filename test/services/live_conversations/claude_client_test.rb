# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class LiveConversations::ClaudeClientTest < ActiveSupport::TestCase
  setup { @dir = Dir.mktmpdir("fake_claude_") }
  teardown { FileUtils.rm_rf(@dir) }

  # A stand-in `claude` binary: records its arguments and the credential env it
  # was given, then prints `stdout` and exits with `exit_code`.
  def fake_claude(stdout:, exit_code: 0, sleep_seconds: 0)
    path = File.join(@dir, "claude")
    File.write(path, <<~SH)
      #!/bin/sh
      for arg in "$@"; do printf '%s\\0' "$arg"; done > "#{@dir}/argv"
      cat > "#{@dir}/stdin"
      cp "$(pwd)/mcp.json" "#{@dir}/mcp.json"; cp "$(pwd)/system.txt" "#{@dir}/system.txt"
      stat -c '%a' "$(pwd)/mcp.json" > "#{@dir}/mcp_mode"; pwd > "#{@dir}/cwd"
      printf '%s|%s|%s' "$CLAUDE_CODE_OAUTH_TOKEN" "$ANTHROPIC_API_KEY" "$CLAUDE_CONFIG_DIR" > "#{@dir}/env"
      sleep #{sleep_seconds}
      cat <<'JSON'
      #{stdout}
      JSON
      exit #{exit_code}
    SH
    File.chmod(0o755, path)
    path
  end

  def argv = File.read(File.join(@dir, "argv")).split("\0")

  def client(binary, **options)
    LiveConversations::ClaudeClient.new(claude_binary: binary, mcp_url: "https://zimmer.test/live/delegation_mcp", **options)
  end

  def run_client(binary, **options)
    client(binary, **options).run(prompt: "What needs me?", system: "Answer briefly.", model: "claude-opus-5-5", mcp_token: "tok123")
  end

  SUCCESS = { type: "result", subtype: "success", is_error: false, result: "Two sessions need you.", num_turns: 3, duration_ms: 4200,
              usage: { input_tokens: 12, output_tokens: 40, cache_read_input_tokens: 9000, cache_creation_input_tokens: 300 },
              modelUsage: { "claude-opus-5-5" => {} } }.to_json

  test "runs the real CLI shape on the subscription: the configured model, only the Live tools over MCP, no API key" do
    answer = run_client(fake_claude(stdout: SUCCESS))

    assert_equal "Two sessions need you.", answer.text
    assert_equal 3, answer.num_turns
    assert_equal [ "claude-opus-5-5" ], answer.models
    assert_equal 9000, answer.usage["cache_read_input_tokens"]

    args = argv
    assert_equal "claude-opus-5-5", args[args.index("--model") + 1]
    assert_equal "", args[args.index("--tools") + 1]
    assert_equal "", args[args.index("--setting-sources") + 1]
    assert_includes args, "--strict-mcp-config"
    assert_includes args, "--disable-slash-commands"
    assert_equal "mcp__zimmer_live", args[args.index("--allowedTools") + 1]
    assert_includes args, "--append-system-prompt-file"
    assert_not_includes args, "--system-prompt", "Claude Code's own system prompt is kept"
    assert_equal "-p", args.last
    # Nothing private on the command line, where `ps` shows it.
    assert args.none? { |arg| arg.include?("tok123") || arg.include?("What needs me?") || arg.include?("Answer briefly.") }
    assert_equal "What needs me?", File.read(File.join(@dir, "stdin"))
    assert_equal "Answer briefly.", File.read(File.join(@dir, "system.txt"))
    assert_equal "600", File.read(File.join(@dir, "mcp_mode")).strip
    server = JSON.parse(File.read(File.join(@dir, "mcp.json"))).dig("mcpServers", "zimmer_live")
    assert_equal({ "type" => "http", "url" => "https://zimmer.test/live/delegation_mcp", "headers" => { "Authorization" => "Bearer tok123" } }, server)
    # A run directory TokenUsageIngestionService counts as headless inference, once Claude Code names its project.
    project = File.read(File.join(@dir, "cwd")).strip.gsub(/[^a-zA-Z0-9]/, "-")
    assert_match TokenUsageIngestionService::HEADLESS_DIR, project
    assert_not Dir.exist?(File.read(File.join(@dir, "cwd")).strip), "the run directory is removed"

    token, api_key, config_dir = File.read(File.join(@dir, "env")).split("|", -1)
    assert_equal claude_accounts(:primary).claude_access_token, token
    assert_empty api_key
    assert config_dir.present?
  end

  test "an error result is an Error, kinded for what the voice says" do
    not_logged_in = { type: "result", subtype: "success", is_error: true, result: "Not logged in · Please run /login" }.to_json
    error = assert_raises(LiveConversations::ClaudeClient::Error) { run_client(fake_claude(stdout: not_logged_in, exit_code: 1)) }
    assert_equal :auth, error.kind
    assert_equal 1, error.status

    limited = { type: "result", subtype: "success", is_error: true, result: "API Error: 429 rate_limit_error" }.to_json
    assert_equal :rate_limited, assert_raises(LiveConversations::ClaudeClient::Error) { run_client(fake_claude(stdout: limited, exit_code: 1)) }.kind

    turns = { type: "result", subtype: "error_max_turns", is_error: false, result: "", usage: { input_tokens: 9_000, output_tokens: 70 } }.to_json
    max = assert_raises(LiveConversations::ClaudeClient::Error) { run_client(fake_claude(stdout: turns)) }
    assert_equal :max_turns, max.kind
    assert_equal 9_000, max.usage["input_tokens"], "what a failed run spent is kept"

    garbage = assert_raises(LiveConversations::ClaudeClient::Error) { run_client(fake_claude(stdout: "boom", exit_code: 2)) }
    assert_equal :failed, garbage.kind
    assert_equal 2, garbage.status
  end

  test "a run that cannot start is a failure, not an exception for the client" do
    error = assert_raises(LiveConversations::ClaudeClient::Error) { run_client(File.join(@dir, "no-such-claude")) }

    assert_equal :failed, error.kind
    assert_match(/could not be started/, error.message)
  end

  test "a run past the timeout is stopped and is a timeout" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(LiveConversations::ClaudeClient::Error) { run_client(fake_claude(stdout: SUCCESS, sleep_seconds: 5), timeout: 1) }

    assert_equal :timeout, error.kind
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 4
  end

  test "a current account that cannot serve is unavailable, saying why, like the session spawn path" do
    account = claude_accounts(:primary)

    account.update!(status: :quota_exceeded)
    assert_equal "Zimmer's current Claude Code account is out of quota", LiveConversations::ClaudeClient.unavailable_reason
    assert_raises(LiveConversations::ClaudeClient::NotConfiguredError) { LiveConversations::ClaudeClient.new }

    account.update!(status: :needs_reauth)
    assert_match(/needs re-authenticating/, LiveConversations::ClaudeClient.unavailable_reason)

    account.update!(status: :active, credential_rejected_at: Time.current, credential_verified_at: 1.hour.ago)
    assert_match(/needs re-authenticating/, LiveConversations::ClaudeClient.unavailable_reason)

    account.update!(credential_verified_at: Time.current)
    assert_nil LiveConversations::ClaudeClient.unavailable_reason
  end

  test "no current account is NotConfigured, naming why" do
    without_claude_code_account

    error = assert_raises(LiveConversations::ClaudeClient::NotConfiguredError) { LiveConversations::ClaudeClient.new }
    assert_equal "Zimmer has no current Claude Code account", error.message
    assert_not LiveConversations::ClaudeClient.configured?
  end

  test "the tools are reached at Zimmer's own address" do
    assert_equal "#{AppUrl.base_url}/live/delegation_mcp", LiveConversations::ClaudeClient.mcp_url
  end
end

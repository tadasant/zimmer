# frozen_string_literal: true

require "test_helper"

class RuntimeLoginDriverTest < ActiveSupport::TestCase
  test "for returns the runtime-specific driver" do
    assert_instance_of ClaudeLoginDriver, RuntimeLoginDriver.for("claude_code")
    assert_instance_of CodexLoginDriver, RuntimeLoginDriver.for("codex")
  end

  test "for raises on an unknown runtime" do
    assert_raises(ArgumentError) { RuntimeLoginDriver.for("aider") }
  end

  test "strip_ansi removes escape sequences and normalizes carriage returns" do
    driver = CodexLoginDriver.new
    raw = "\e[2J\e[1;1Hhello\e[0m\rworld\e[?25l"
    assert_equal "hello\nworld", driver.strip_ansi(raw)
  end

  test "strip_ansi tolerates nil" do
    assert_equal "", CodexLoginDriver.new.strip_ansi(nil)
  end

  test "resolved_command prepends the resolved executable to the subcommand argv" do
    driver = CodexLoginDriver.new
    # Pin to a guaranteed-present executable so resolution is deterministic
    # regardless of whether the real codex CLI is installed on this host.
    driver.stub(:executable_candidates, [ "/bin/sh" ]) do
      assert_equal [ "/bin/sh", "login", "--device-auth" ], driver.resolved_command
    end
  end

  test "resolved_command raises a clear error when no login CLI is installed" do
    driver = CodexLoginDriver.new
    driver.stub(:executable_candidates, [ "/nonexistent/codex-xyz" ]) do
      error = assert_raises(RuntimeError) { driver.resolved_command }
      assert_match(/login CLI not found/, error.message)
    end
  end
end

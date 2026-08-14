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

  test "strip_ansi unwraps an OSC 8 hyperlink to its target" do
    driver = CodexLoginDriver.new
    raw = "visit: \e]8;;https://example.com/auth?x=1\aclick here\e]8;;\a\n"
    clean = driver.strip_ansi(raw)
    assert_equal "visit: https://example.com/auth?x=1\nclick here\n", clean
    assert_no_match(/[\x00-\x08\x0b\x0c\x0e-\x1f]/, clean, "no control characters survive")
  end

  test "strip_ansi unwraps an ST-terminated OSC 8 hyperlink" do
    # BEL is the common terminator, but ESC \ (ST) is equally valid OSC.
    driver = CodexLoginDriver.new
    assert_equal "https://example.com/a\nlabel\n",
      driver.strip_ansi("\e]8;;https://example.com/a\e\\label\e]8;;\e\\\n")
  end

  test "strip_ansi drops non-hyperlink OSC sequences" do
    # A window-title set carries nothing worth keeping.
    assert_equal "hello", CodexLoginDriver.new.strip_ansi("\e]0;claude\ahello")
  end

  test "strip_ansi returns valid UTF-8 from a binary buffer" do
    # PTY reads arrive ASCII-8BIT and can be cut mid-character between chunks.
    # This is the boundary where those bytes become text we match and store.
    driver = CodexLoginDriver.new
    clean = driver.strip_ansi("signing in\xE2\x80\xA6 \xE2\x80".b)
    assert_equal Encoding::UTF_8, clean.encoding
    assert clean.valid_encoding?, "truncated multibyte tail must be scrubbed"
    assert_equal "signing in… ", clean
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

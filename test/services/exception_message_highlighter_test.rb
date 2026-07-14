# frozen_string_literal: true

require "test_helper"

class ExceptionMessageHighlighterTest < ActiveSupport::TestCase
  # The motivating prod shape: AIR prefixes the real error with non-fatal
  # deprecation warnings, so the actionable "Error:" line sits well past a
  # leading wall of warning text.
  AIR_MIXED_MESSAGE = <<~MSG.freeze
    AIR prepare failed (exit 1): warning: Plugin "agent-transcript-capture" declares its body inline.
    warning: Inline plugin bodies are deprecated as of v0.13.0.
    warning: Inline plugin bodies will be removed in a future release. Migrate to a path-based plugin body.
    Error: Unresolved variables in /clones/x/agent-roots/zimmer: ${SENTRY_DSN}. Ensure all variables are provided via environment or a secrets transform.
  MSG

  test "extracts the actionable Error line out of leading deprecation warnings" do
    highlights = ExceptionMessageHighlighter.highlights(AIR_MIXED_MESSAGE)

    assert_not_nil highlights, "a mixed warning+error message should produce highlights"
    assert_includes highlights, "Error: Unresolved variables"
    assert_includes highlights, "${SENTRY_DSN}"
  end

  test "highlights exclude the deprecation warning noise" do
    highlights = ExceptionMessageHighlighter.highlights(AIR_MIXED_MESSAGE)

    refute_includes highlights, "deprecated as of v0.13.0"
    refute_includes highlights, "will be removed in a future release"
  end

  test "trims the embedded warning clause off the AIR 'failed (exit N): warning:' wrapper line" do
    # AIR wraps stderr as "AIR prepare failed (exit N): <first line>"; when that
    # first line is a warning, the composite line reads as an error (contains
    # "failed") but trails into warning prose. The callout must keep the error
    # header without the warning text.
    highlights = ExceptionMessageHighlighter.highlights(AIR_MIXED_MESSAGE)

    assert_includes highlights, "AIR prepare failed (exit 1)"
    refute_includes highlights, "declares its body inline"
    # And the real actionable error is still present, on its own line.
    assert_includes highlights, "Error: Unresolved variables"
  end

  test "does not trim the word 'warning' when it is part of the error prose (no colon form)" do
    message = "warning: something benign is deprecated\n" \
              "Error: the warning subsystem failed to initialize"
    highlights = ExceptionMessageHighlighter.highlights(message)

    assert_includes highlights, "Error: the warning subsystem failed to initialize"
  end

  test "actionable error survives even when warnings dominate the byte budget" do
    warning_wall = ([ "warning: Inline plugin bodies are deprecated as of v0.13.0." ] * 500).join("\n")
    message = "#{warning_wall}\nError: the real actionable failure is here"

    highlights = ExceptionMessageHighlighter.highlights(message)

    assert_not_nil highlights
    assert_includes highlights, "the real actionable failure is here"
    # The callout is a summary, not the whole wall.
    assert highlights.length <= ExceptionMessageHighlighter::MAX_HIGHLIGHT_CHARS
  end

  test "returns nil when there are no warnings crowding the error" do
    # A clean single-error message needs no separate callout; the full block
    # already reads correctly.
    assert_nil ExceptionMessageHighlighter.highlights("Error: something broke\n  at line 12")
  end

  test "returns nil when the message is only warnings" do
    only_warnings = "warning: Inline plugin bodies are deprecated as of v0.13.0.\n" \
                    "warning: Something else is deprecated too."
    assert_nil ExceptionMessageHighlighter.highlights(only_warnings)
  end

  test "returns nil for blank input" do
    assert_nil ExceptionMessageHighlighter.highlights(nil)
    assert_nil ExceptionMessageHighlighter.highlights("")
    assert_nil ExceptionMessageHighlighter.highlights("   ")
  end

  test "recognizes fatal: and npm-style error lines amid warnings" do
    message = "npm warn deprecated foo@1.0.0: use bar instead\n" \
              "fatal: unable to access 'https://github.com/...': Could not resolve host"
    highlights = ExceptionMessageHighlighter.highlights(message)

    assert_not_nil highlights
    assert_includes highlights, "fatal: unable to access"
    refute_includes highlights, "npm warn deprecated"
  end

  test "de-duplicates repeated identical error lines" do
    message = "warning: deprecated\n" \
              "Error: boom\n" \
              "Error: boom"
    highlights = ExceptionMessageHighlighter.highlights(message)

    assert_equal "Error: boom", highlights
  end

  test "a line carrying both a deprecation token and a strong Error signature is treated as an error" do
    message = "warning: something benign is deprecated\n" \
              "Error: the plugin API is deprecated and now fails hard"
    highlights = ExceptionMessageHighlighter.highlights(message)

    assert_not_nil highlights
    assert_includes highlights, "the plugin API is deprecated and now fails hard"
  end
end

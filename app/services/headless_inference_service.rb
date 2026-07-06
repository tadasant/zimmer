# frozen_string_literal: true

# Service for making one-off, headless inference calls — a "sprinkle of
# inference" without standing up a full interactive agent session.
#
# This is the runtime-neutral interface AO uses anywhere it needs a single
# short LLM completion (session titles, notification summaries, category
# inference). Callers depend only on #generate(prompt, …); they make no
# assumption about which coding-agent runtime backs it.
#
# Implementation note (honest operational reality): the call is fulfilled by
# the Claude CLI in print mode. Which backend runs is decided in ONE place —
# ClaudePrintRunner.build — based on whether the `pty_transport` extension is
# enabled:
#
#   * native — shells out to `claude -p "<prompt>"` and reads stdout (default).
#   * pty    — drives the interactive Claude TUI in a pseudo-terminal and
#     scrapes the transcript (the reimplemented "claude-p" technique), selected
#     only when the extension is enabled.
#
# This service does not branch on enablement itself; it asks ClaudePrintRunner for
# a runner and consumes the result. Both backends return the same text for the
# same prompt; the PTY backend additionally surfaces token usage, which this
# one-line-completion path discards.
#
# Example usage:
#   service = HeadlessInferenceService.new
#   title = service.generate("Generate a 6-word title for: #{content}")
#
#   # With custom timeout
#   summary = service.generate(prompt, timeout: 15)
class HeadlessInferenceService
  # Default timeout for a headless inference call (in seconds)
  DEFAULT_TIMEOUT = 30
  DEFAULT_MODEL = ModelCatalog.default_for("claude_code")

  # Allow injection of process manager for testing
  attr_accessor :process_manager

  # @param process_manager [ProcessManager] injectable for the native backend
  # @param claude_binary [String] the binary the backends drive (injectable so
  #   tests can point at a deterministic fake)
  # @param pty_override [Boolean, nil] force the backend selection regardless of
  #   the persisted flag (nil = consult AppSetting). For tests/diagnostics.
  def initialize(process_manager: nil, claude_binary: "claude", pty_override: nil)
    @process_manager = process_manager || SystemProcessManager.new
    @claude_binary = claude_binary
    @pty_override = pty_override
  end

  # Generate text for a one-off prompt.
  #
  # @param prompt [String] The prompt to send to the inference backend
  # @param timeout [Integer] Timeout in seconds (default: 30)
  # @param model [String] The model id to run against (default: the runtime
  #   default). Pass a cheaper model (e.g. "haiku") for high-volume, low-stakes
  #   completions like titles and category inference.
  # @param single_line [Boolean] When true (default) the response is reduced to
  #   a single cleaned line — the right shape for a one-line title or a bare
  #   category name. Pass false when the prompt asks for a multi-line structured
  #   answer (e.g. labeled "TITLE:" / "CATEGORY:" lines) that the caller parses
  #   itself; only surrounding whitespace is trimmed in that case.
  # @return [String, nil] The generated text, or nil on failure
  def generate(prompt, timeout: DEFAULT_TIMEOUT, model: DEFAULT_MODEL, single_line: true)
    return nil if prompt.blank?

    ClaudeModelConfigurationAudit.warn_if_pinned!

    raw = run_inference(prompt, timeout: timeout, model: model)
    return nil if raw.nil?

    raw = raw.strip
    single_line ? clean_response(raw) : raw.presence
  end

  private

  # Dispatch through the single flag-aware seam and return the raw response
  # text, or nil on timeout/failure. A headless-inference failure is a tolerated,
  # self-resolving edge case — the caller falls back to a default (e.g. keeps the
  # session's provisional title) — so it is logged at .warn, not .error.
  def run_inference(prompt, timeout:, model:)
    runner = ClaudePrintRunner.build(
      claude_binary: @claude_binary,
      model: model,
      process_manager: @process_manager,
      pty_override: @pty_override
    )
    runner.run(prompt: prompt, timeout: timeout)&.text
  rescue Timeout::Error
    Rails.logger.warn "[HeadlessInferenceService] inference timed out after #{timeout}s"
    nil
  rescue StandardError => e
    Rails.logger.warn "[HeadlessInferenceService] inference failed: #{e.message}"
    nil
  end

  # Clean up the raw response by removing common prefixes and formatting.
  #
  # @param result [String] The raw response from the inference backend
  # @return [String, nil] The cleaned response
  def clean_response(result)
    return nil if result.blank?

    # Remove common prefixes the model might add
    result = result.gsub(/^(Here's|Title:|The title is:|Summary:|Here's the summary:|The summary is:)\s*/i, "")

    # Take only the first line if multi-line
    result = result.lines.first&.strip if result.lines.count > 1

    # Remove surrounding quotes if present
    result = result.gsub(/^["']|["']$/, "")

    result.presence
  end
end

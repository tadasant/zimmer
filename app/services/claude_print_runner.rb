# frozen_string_literal: true

# The single seam through which every one-off, non-interactive Claude CLI
# inference call is dispatched — the "claude -p" family: one prompt in, one
# final response out (session titles, notification summaries, category
# inference, and any future sprinkle of inference).
#
# This module exists so the native-vs-extension decision for print-mode
# inference is made in EXACTLY ONE place (`ClaudePrintRunner.build`). No matter
# which caller needs inference, that decision lives in this one code path;
# callers never make it themselves.
#
# The default backend is always NativeClaudePrintRunner — it shells out to
# `claude -p "<prompt>"` and reads stdout (the historically-proven path). An
# enabled Zimmer Extension may supply an alternative backend via the extension
# registry; the PTY transport extension does, substituting a PtyClaudePrintRunner
# that drives the interactive Claude TUI inside a pseudo-terminal and scrapes the
# transcript. Any backend satisfies the same contract —
# `#run(prompt:, timeout:) -> ClaudePrintRunner::Result`. Because the choice is
# resolved through Ao::ExtensionRegistry, this module names no concrete
# extension: with the PTY extension removed, every call falls back to native.
#
# Scope note: this seam governs print-mode inference only. Interactive
# agent-session execution (a long-lived process that streams a transcript over
# time and supports resume / follow-up / MCP / image input) is a structurally
# different invocation that a single-shot print runner cannot replace. It is
# governed through a separate seam — RuntimeRegistry.cli_adapter_class_for, which
# consults the same extension registry to swap the session's CLI adapter. The
# two seams exist because the invocations differ in shape.
module ClaudePrintRunner
  # The result of one print-mode inference. `text` is the final assistant
  # response (raw, unstripped — the consumer decides how to clean it); `usage`
  # is the model's token usage when the backend can surface it (PTY backend) or
  # nil when it cannot (native `-p` prints text only).
  Result = Struct.new(:text, :usage, keyword_init: true)

  module_function

  # Build the runner for the current configuration. This is the single point at
  # which an extension-provided backend is chosen over the native default.
  #
  # @param claude_binary [String] the binary to drive (injectable for tests)
  # @param model [String, nil] model id passed through as `--model`
  # @param process_manager [ProcessManager, nil] used by the native backend
  #   (injectable for tests); ignored by an extension backend that opens its own
  #   transport (e.g. the PTY backend)
  # @param pty_override [Boolean, nil] force the backend selection regardless of
  #   which extensions are enabled. `true` forces an extension-provided backend
  #   (considering all extensions, ignoring enablement); `false` forces the
  #   native backend; nil consults the enabled extensions. For tests/diagnostics.
  # @param logger [Logger]
  # @return [#run] a runner responding to run(prompt:, timeout:) -> Result
  def build(claude_binary: "claude", model: nil, process_manager: nil, pty_override: nil, logger: Rails.logger)
    backend = extension_backend(
      claude_binary: claude_binary, model: model,
      process_manager: process_manager, logger: logger, override: pty_override
    )
    backend || NativeClaudePrintRunner.new(
      claude_binary: claude_binary, model: model,
      process_manager: process_manager, logger: logger
    )
  end

  # Whether an extension backend is active for print inference. An explicit
  # override wins (tests/diagnostics); otherwise ask the registry whether any
  # enabled extension provides one. Kept for tests/diagnostics that assert which
  # path is live.
  def pty_enabled?(override = nil)
    return override unless override.nil?

    Ao::ExtensionRegistry.print_runner_backend?
  end

  # Resolve an extension-provided backend for the given override, or nil to fall
  # back to native. Not part of the public API — a helper for #build.
  def extension_backend(claude_binary:, model:, process_manager:, logger:, override:)
    return nil if override == false

    Ao::ExtensionRegistry.print_runner_backend(
      force: override == true,
      claude_binary: claude_binary, model: model,
      process_manager: process_manager, logger: logger
    )
  end
end

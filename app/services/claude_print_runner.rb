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
# resolved through Zimmer::ExtensionRegistry, this module names no concrete
# extension: with the PTY extension removed, every call falls back to native.
#
# Every call here is a text completion, never an agent. The prompts carry
# transcripts and last messages, and those hold text from outside the circle of
# trust: Slack messages, inbound email, GitHub comments. So a backend runs with no
# tools and none of the user's or project's configuration (TEXT_ONLY_ARGS), and
# #build refuses an extension backend that does not declare it does the same.
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
  #
  # `exit_status` is the backend's process exit code when it has one, and is the
  # only WORDING-INDEPENDENT evidence that the CLI refused rather than answered.
  # It matters because `claude -p` prints its own error to stdout and exits
  # non-zero: without this, a consumer reading only `text` stores the error as
  # though it were the answer. A backend that cannot produce an exit code (the
  # PTY transport drives a TUI, not a one-shot process) leaves it nil, which
  # consumers must read as "unknown", never as "failed".
  Result = Struct.new(:text, :usage, :exit_status, keyword_init: true) do
    # True only when the backend reported a code AND that code is a failure.
    def failed? = !exit_status.nil? && !exit_status.zero?
  end

  # What makes a `claude` invocation a text completion, as measured against CLI
  # 2.1.318 with a stub API:
  #
  #   --tools ""                  no built-in tools. MCP tools and hooks survive it.
  #   --setting-sources ""        no user, project or local settings: no hooks and
  #                               no CLAUDE.md. Managed settings still apply.
  #
  # Two more are defensive rather than measured to be necessary:
  #
  #   --strict-mcp-config         no MCP server from any config file, whatever
  #                               counts as a setting source.
  #   --disable-slash-commands    a prompt cannot open a skill or command.
  #
  # `--dangerously-skip-permissions` stays out on purpose. Nothing here needs it, and
  # without it a tool needing approval has nobody to grant it: `Bash` was denied when
  # the CLI was given its default tools. Read-only tools may not need approval, so
  # this is a backstop and not a replacement for `--tools ""`.
  #
  # `--no-session-persistence` stays out too: TokenUsageIngestionService reads these
  # calls' transcripts to account for their spend.
  TEXT_ONLY_ARGS = [
    "--tools", "",
    "--strict-mcp-config",
    "--setting-sources", "",
    "--disable-slash-commands"
  ].freeze

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
  # @return [#run] a runner responding to run(prompt:, timeout:) -> Result. An
  #   extension backend that does not declare #text_only? is replaced by native.
  def build(claude_binary: "claude", model: nil, process_manager: nil, pty_override: nil, logger: Rails.logger)
    backend = extension_backend(
      claude_binary: claude_binary, model: model,
      process_manager: process_manager, logger: logger, override: pty_override
    )
    return backend if backend && text_only?(backend)

    if backend
      logger.warn "[ClaudePrintRunner] #{backend.class} does not declare #text_only?; using the native backend"
    end

    NativeClaudePrintRunner.new(
      claude_binary: claude_binary, model: model,
      process_manager: process_manager, logger: logger
    )
  end

  # Whether a backend has declared that it runs with the equivalent of
  # TEXT_ONLY_ARGS. An extension backend is code this repository may not hold, so
  # silence reads as "no": the failure is a cost (no `usage`), not a model with
  # tools reading untrusted text. `pty_override: true` does not skip this.
  def text_only?(backend)
    backend.respond_to?(:text_only?) && backend.text_only? == true
  end

  # Whether an extension backend is active for print inference. An explicit
  # override wins (tests/diagnostics); otherwise ask the registry whether any
  # enabled extension provides one. Kept for tests/diagnostics that assert which
  # path is live. It does not consult #text_only?, so #build can still answer with
  # native while this is true.
  def pty_enabled?(override = nil)
    return override unless override.nil?

    Zimmer::ExtensionRegistry.print_runner_backend?
  end

  # Resolve an extension-provided backend for the given override, or nil to fall
  # back to native. Not part of the public API — a helper for #build.
  def extension_backend(claude_binary:, model:, process_manager:, logger:, override:)
    return nil if override == false

    Zimmer::ExtensionRegistry.print_runner_backend(
      force: override == true,
      claude_binary: claude_binary, model: model,
      process_manager: process_manager, logger: logger
    )
  end
end

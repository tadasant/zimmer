# frozen_string_literal: true

require "test_helper"

class RuntimeRegistryTest < ActiveSupport::TestCase
  test "default runtime is claude_code" do
    assert_equal "claude_code", RuntimeRegistry::DEFAULT_RUNTIME
  end

  test "for resolves the claude_code bundle" do
    bundle = RuntimeRegistry.for("claude_code")
    assert_equal "claude_code", bundle.runtime
    assert_equal "claude", bundle.air_adapter_name
    assert_equal ClaudeCliAdapter, bundle.cli_adapter_class
    assert_equal ClaudeRetryStrategy, bundle.retry_strategy_class
    assert_equal ClaudeTranscriptSource, bundle.transcript_source_class
    assert_equal ClaudeTranscriptNormalizer, bundle.transcript_normalizer_class
    assert_equal McpLogPollerService, bundle.mcp_status_detector_class
    assert_equal ClaudeRuntimePromptContribution, bundle.prompt_contribution_class
    assert_equal ClaudeMcpConfigPostProcessor, bundle.config_post_processor_class
    assert_equal ClaudeMcpCredentialWriter, bundle.mcp_credential_writer_class
  end

  test "for resolves the codex bundle" do
    bundle = RuntimeRegistry.for("codex")
    assert_equal "codex", bundle.runtime
    assert_equal "codex", bundle.air_adapter_name
    assert_equal CodexRuntimeAdapter, bundle.cli_adapter_class
    assert_equal CodexRetryStrategy, bundle.retry_strategy_class
    assert_equal CodexTranscriptSource, bundle.transcript_source_class
    assert_equal CodexTranscriptNormalizer, bundle.transcript_normalizer_class
    assert_equal CodexMcpStatusDetector, bundle.mcp_status_detector_class
    assert_equal CodexConfigTomlPostProcessor, bundle.config_post_processor_class
    assert_equal CodexMcpCredentialWriter, bundle.mcp_credential_writer_class
  end

  test "for falls back to the default runtime when given nil or blank" do
    assert_equal RuntimeRegistry.for("claude_code"), RuntimeRegistry.for(nil)
    assert_equal RuntimeRegistry.for("claude_code"), RuntimeRegistry.for("")
  end

  test "for accepts a symbol runtime" do
    assert_equal RuntimeRegistry.for("claude_code"), RuntimeRegistry.for(:claude_code)
  end

  test "for raises KeyError for an unregistered runtime" do
    error = assert_raises(KeyError) { RuntimeRegistry.for("aider") }
    assert_match(/No runtime registered for "aider"/, error.message)
  end

  test "registered_runtimes lists the known runtimes" do
    assert_equal %w[claude_code codex], RuntimeRegistry.registered_runtimes
  end

  test "label_for returns a human-friendly label for claude_code" do
    assert_equal "Claude Code", RuntimeRegistry.label_for("claude_code")
  end

  test "label_for returns a human-friendly label for codex" do
    assert_equal "Codex", RuntimeRegistry.label_for("codex")
  end

  test "label_for falls back to the default runtime label for blank input" do
    assert_equal "Claude Code", RuntimeRegistry.label_for(nil)
    assert_equal "Claude Code", RuntimeRegistry.label_for("")
  end

  test "label_for returns the raw key when no label is registered" do
    assert_equal "aider", RuntimeRegistry.label_for("aider")
  end

  test "claude_code bundle leaves not-yet-implemented slots nil" do
    bundle = RuntimeRegistry.for("claude_code")
    assert_nil bundle.config_preparer_class
    assert_nil bundle.auth_provider_class
  end

  test "codex bundle leaves sibling-owned slots nil until those issues land" do
    bundle = RuntimeRegistry.for("codex")
    assert_nil bundle.prompt_contribution_class
    assert_nil bundle.config_preparer_class
    assert_nil bundle.auth_provider_class
  end

  # ===== cli_adapter_class_for — the generic extension-override seam =====
  # An enabled extension can swap the interactive CLI adapter without the registry
  # ever naming a concrete extension. Exercised with a FAKE extension so this
  # coverage survives deletion of any real extension directory (the OSS-removal
  # invariant). The concrete pty_transport override is covered alongside the
  # extension in test/extensions/pty_transport/pty_transport_extension_test.rb.
  FakeSwapAdapter = Class.new

  class FakeSwapExtension < Zimmer::Extension
    def id = "fake_swap"
    def cli_adapter_override(runtime) = (runtime.to_s == "claude_code") ? FakeSwapAdapter : nil
  end

  # Register the fake override for these tests, then restore the canonical
  # builtins so the rest of the suite sees the real registry.
  setup do
    AppSetting.delete_all
    Zimmer::ExtensionRegistry.register(FakeSwapExtension.new)
  end

  teardown do
    Zimmer::ExtensionRegistry.reset!
    Zimmer::ExtensionRegistry.register_builtins!
  end

  def enable_swap(on)
    AppSetting.editable.tap { |s| s.set_extension_enabled("fake_swap", on); s.save! }
  end

  test "cli_adapter_class_for returns the bundle default for claude_code when no extension overrides" do
    enable_swap(false)
    assert_equal ClaudeCliAdapter, RuntimeRegistry.cli_adapter_class_for("claude_code")
  end

  test "cli_adapter_class_for swaps in an enabled extension's adapter for claude_code" do
    enable_swap(true)
    assert_equal FakeSwapAdapter, RuntimeRegistry.cli_adapter_class_for("claude_code")
  end

  test "cli_adapter_class_for treats blank/nil runtime as claude_code through the seam" do
    enable_swap(true)
    assert_equal FakeSwapAdapter, RuntimeRegistry.cli_adapter_class_for(nil)
    assert_equal FakeSwapAdapter, RuntimeRegistry.cli_adapter_class_for("")
  end

  test "cli_adapter_class_for never swaps the adapter for codex, extension on or off" do
    enable_swap(true)
    assert_equal CodexRuntimeAdapter, RuntimeRegistry.cli_adapter_class_for("codex")

    enable_swap(false)
    assert_equal CodexRuntimeAdapter, RuntimeRegistry.cli_adapter_class_for("codex")
  end
end

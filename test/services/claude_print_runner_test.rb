# frozen_string_literal: true

require "test_helper"

# Tests the single seam through which all print-mode inference is dispatched. The
# whole point of this module is that the native-vs-extension decision lives in
# exactly one place, so these tests pin that decision.
#
# The seam is tested against a FAKE extension registered into the registry rather
# than any concrete (deletable) extension like pty_transport — so this file keeps
# passing even in an OSS build with the PTY extension removed. PTY-specific
# selection is covered in test/extensions/pty_transport/.
class ClaudePrintRunnerTest < ActiveSupport::TestCase
  # A minimal backend + extension exercising the print-runner seam. The backend
  # only needs to be identifiable; it never actually runs here.
  class FakePrintBackend
    attr_reader :claude_binary, :model

    def initialize(claude_binary:, model:)
      @claude_binary = claude_binary
      @model = model
    end
  end

  class FakePrintExtension < Zimmer::Extension
    def id = "fake_print"
    def provides_print_runner? = true

    def print_runner_backend(claude_binary:, model:, process_manager:, logger:)
      FakePrintBackend.new(claude_binary: claude_binary, model: model)
    end
  end

  setup do
    AppSetting.delete_all
    Zimmer::ExtensionRegistry.reset!
    Zimmer::ExtensionRegistry.register(FakePrintExtension.new)
  end

  teardown do
    # Restore the real built-in registry so we don't leak the fake into other tests.
    Zimmer::ExtensionRegistry.reset!
    Zimmer::ExtensionRegistry.register_builtins!
  end

  def enable_fake(on)
    AppSetting.editable.tap { |s| s.set_extension_enabled("fake_print", on); s.save! }
  end

  test "builds the native backend by default (no extension enabled)" do
    enable_fake(false)

    runner = ClaudePrintRunner.build

    assert_instance_of NativeClaudePrintRunner, runner
  end

  test "builds the extension backend when an enabled extension provides one" do
    enable_fake(true)

    runner = ClaudePrintRunner.build

    assert_instance_of FakePrintBackend, runner
  end

  test "pty_override: false forces native even when an extension is enabled" do
    enable_fake(true)

    runner = ClaudePrintRunner.build(pty_override: false)

    assert_instance_of NativeClaudePrintRunner, runner
  end

  test "pty_override: true forces the extension backend even when disabled" do
    enable_fake(false)

    runner = ClaudePrintRunner.build(pty_override: true)

    assert_instance_of FakePrintBackend, runner
  end

  test "pty_enabled? consults the registry when no override is given" do
    enable_fake(false)
    refute ClaudePrintRunner.pty_enabled?

    enable_fake(true)
    assert ClaudePrintRunner.pty_enabled?
  end

  test "pty_enabled? honors an explicit override over enablement" do
    enable_fake(true)
    refute ClaudePrintRunner.pty_enabled?(false)

    enable_fake(false)
    assert ClaudePrintRunner.pty_enabled?(true)
  end

  test "forwards the injected process_manager, model and binary to the native backend" do
    enable_fake(false)
    pm = Object.new
    runner = ClaudePrintRunner.build(
      claude_binary: "/fake/claude", model: "haiku", process_manager: pm
    )

    assert_instance_of NativeClaudePrintRunner, runner
    assert_same pm, runner.instance_variable_get(:@process_manager)
    assert_equal "haiku", runner.instance_variable_get(:@model)
    assert_equal "/fake/claude", runner.instance_variable_get(:@claude_binary)
  end

  test "forwards the model and binary to the extension backend" do
    enable_fake(true)
    runner = ClaudePrintRunner.build(
      claude_binary: "/fake/claude", model: "haiku", process_manager: Object.new
    )

    assert_instance_of FakePrintBackend, runner
    assert_equal "haiku", runner.model
    assert_equal "/fake/claude", runner.claude_binary
  end
end

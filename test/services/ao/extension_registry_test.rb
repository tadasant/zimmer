# frozen_string_literal: true

require "test_helper"

# Covers the generic registry behavior that every extension relies on:
# registration, enabled-filtering, first-wins hook resolution, force semantics,
# and — critically — that a built-in whose class no longer resolves is skipped
# rather than raising (the OSS-removal path). Uses fake extensions so it doesn't
# depend on any concrete (deletable) extension.
class Ao::ExtensionRegistryTest < ActiveSupport::TestCase
  # Fake adapters/backends the fakes hand back — only identity matters.
  FakeAdapterA = Class.new
  FakeAdapterB = Class.new

  class FakeExtA < Ao::Extension
    def id = "fake_a"
    def cli_adapter_override(runtime) = runtime.to_s == "claude_code" ? FakeAdapterA : nil
    def provides_print_runner? = true
    def print_runner_backend(claude_binary:, model:, process_manager:, logger:) = :backend_a
    def spawn_env_contribution(context = {}) = { "SHARED" => "a", "ONLY_A" => "1" }
  end

  class FakeExtB < Ao::Extension
    def id = "fake_b"
    def cli_adapter_override(runtime) = runtime.to_s == "claude_code" ? FakeAdapterB : nil
    def spawn_env_contribution(context = {}) = { "SHARED" => "b", "ONLY_B" => "1" }
  end

  setup do
    AppSetting.delete_all
    Ao::ExtensionRegistry.reset!
  end

  teardown do
    Ao::ExtensionRegistry.reset!
    Ao::ExtensionRegistry.register_builtins!
  end

  def enable(id, on)
    AppSetting.editable.tap { |s| s.set_extension_enabled(id, on); s.save! }
  end

  # Temporarily swap BUILTIN_EXTENSION_CLASSES (a frozen constant) for the block,
  # restoring it after. Used to simulate a deleted extension directory.
  def with_builtin_classes(list)
    mod = Ao::ExtensionRegistry
    original = mod::BUILTIN_EXTENSION_CLASSES
    mod.send(:remove_const, :BUILTIN_EXTENSION_CLASSES)
    mod.const_set(:BUILTIN_EXTENSION_CLASSES, list.freeze)
    yield
  ensure
    mod.send(:remove_const, :BUILTIN_EXTENSION_CLASSES)
    mod.const_set(:BUILTIN_EXTENSION_CLASSES, original)
  end

  test "register/find/all round-trips an extension" do
    ext = FakeExtA.new
    Ao::ExtensionRegistry.register(ext)
    assert_same ext, Ao::ExtensionRegistry.find("fake_a")
    assert_includes Ao::ExtensionRegistry.all.map(&:id), "fake_a"
  end

  test "reset! empties the registry" do
    Ao::ExtensionRegistry.register(FakeExtA.new)
    Ao::ExtensionRegistry.reset!
    assert_empty Ao::ExtensionRegistry.all
  end

  test "register_builtins! skips a class name that does not resolve" do
    # Simulate a deleted extension directory: a built-in name that no longer
    # resolves must be silently skipped, not raise. This IS the removability
    # mechanism the OSS build depends on.
    with_builtin_classes(%w[McpToolSearchExtension DefinitelyNotARealExtensionConstant]) do
      assert_nothing_raised { Ao::ExtensionRegistry.register_builtins! }
    end
    ids = Ao::ExtensionRegistry.all.map(&:id)
    assert_includes ids, "mcp_tool_search"
    refute_includes ids, "definitely_not_a_real_extension_constant"
  end

  test "enabled filters to extensions whose persisted state is on" do
    Ao::ExtensionRegistry.register(FakeExtA.new)
    Ao::ExtensionRegistry.register(FakeExtB.new)
    enable("fake_a", true)
    enable("fake_b", false)

    assert_equal [ "fake_a" ], Ao::ExtensionRegistry.enabled.map(&:id)
  end

  test "cli_adapter_override_for returns the first enabled extension's adapter" do
    Ao::ExtensionRegistry.register(FakeExtA.new)
    Ao::ExtensionRegistry.register(FakeExtB.new)

    enable("fake_a", false)
    enable("fake_b", false)
    assert_nil Ao::ExtensionRegistry.cli_adapter_override_for("claude_code")

    enable("fake_b", true)
    assert_equal FakeAdapterB, Ao::ExtensionRegistry.cli_adapter_override_for("claude_code")

    # Registration order is first-wins: A registered before B, so with both on A wins.
    enable("fake_a", true)
    assert_equal FakeAdapterA, Ao::ExtensionRegistry.cli_adapter_override_for("claude_code")
  end

  test "cli_adapter_override_for ignores extensions that defer for the runtime" do
    Ao::ExtensionRegistry.register(FakeExtA.new)
    enable("fake_a", true)
    assert_nil Ao::ExtensionRegistry.cli_adapter_override_for("codex")
  end

  test "print_runner_backend? and print_runner_backend consult enablement" do
    Ao::ExtensionRegistry.register(FakeExtA.new)

    enable("fake_a", false)
    refute Ao::ExtensionRegistry.print_runner_backend?
    assert_nil Ao::ExtensionRegistry.print_runner_backend(claude_binary: "c", model: nil)

    enable("fake_a", true)
    assert Ao::ExtensionRegistry.print_runner_backend?
    assert_equal :backend_a, Ao::ExtensionRegistry.print_runner_backend(claude_binary: "c", model: nil)
  end

  test "print_runner_backend force: true ignores enablement" do
    Ao::ExtensionRegistry.register(FakeExtA.new)
    enable("fake_a", false)

    assert_equal :backend_a,
      Ao::ExtensionRegistry.print_runner_backend(force: true, claude_binary: "c", model: nil)
  end

  test "spawn_env_contributions merges enabled extensions, later wins on collision" do
    Ao::ExtensionRegistry.register(FakeExtA.new)
    Ao::ExtensionRegistry.register(FakeExtB.new)
    enable("fake_a", true)
    enable("fake_b", true)

    merged = Ao::ExtensionRegistry.spawn_env_contributions(runtime: "claude_code")
    assert_equal "1", merged["ONLY_A"]
    assert_equal "1", merged["ONLY_B"]
    # B is registered after A, so B wins the shared key.
    assert_equal "b", merged["SHARED"]
  end

  test "spawn_env_contributions excludes disabled extensions" do
    Ao::ExtensionRegistry.register(FakeExtA.new)
    enable("fake_a", false)
    assert_equal({}, Ao::ExtensionRegistry.spawn_env_contributions(runtime: "claude_code"))
  end
end

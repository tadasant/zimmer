# frozen_string_literal: true

require "test_helper"

# Tests the RuntimeAuthProvider base class: the Result value type, the runtime
# registry, the `.for` factory, and the abstract-method / default-hook contract
# every concrete provider inherits.
class RuntimeAuthProviderTest < ActiveSupport::TestCase
  test "Result#ok? reflects the ok field" do
    assert RuntimeAuthProvider::Result.new(ok: true, error: nil).ok?
    refute RuntimeAuthProvider::Result.new(ok: false, error: :transient).ok?
  end

  test ".for resolves Claude Code for its identifier and aliases" do
    [ "claude_code", "claude", :claude_code ].each do |runtime|
      assert_instance_of ClaudeAuthProvider, RuntimeAuthProvider.for(runtime),
        "expected ClaudeAuthProvider for #{runtime.inspect}"
    end
  end

  test ".for defaults nil and blank runtimes to Claude Code" do
    # Every existing call site passes session.agent_runtime, which is "claude_code"
    # today; nil/blank must stay on the unchanged Claude path.
    assert_instance_of ClaudeAuthProvider, RuntimeAuthProvider.for(nil)
    assert_instance_of ClaudeAuthProvider, RuntimeAuthProvider.for("")
  end

  test ".for raises for an unregistered runtime" do
    error = assert_raises(ArgumentError) { RuntimeAuthProvider.for("aider") }
    assert_match(/aider/, error.message)
  end

  test ".registered returns one provider instance per declared runtime" do
    registered = RuntimeAuthProvider.registered
    assert_equal RuntimeAuthProvider::RUNTIMES.size, registered.size
    assert registered.all? { |p| p.is_a?(RuntimeAuthProvider) }
    assert_equal RuntimeAuthProvider::RUNTIMES.sort, registered.map(&:runtime).sort
  end

  test "abstract methods raise NotImplementedError on the base class" do
    provider = RuntimeAuthProvider.new
    %i[runtime accounts current_account rotation_interval].each do |method|
      assert_raises(NotImplementedError) { provider.public_send(method) }
    end
    assert_raises(NotImplementedError) { provider.select_account_for(nil) }
    assert_raises(NotImplementedError) { provider.refresh!(nil) }
    assert_raises(NotImplementedError) { provider.inject_for_session!(nil) }
  end

  test "recover_needs_reauth defaults to false" do
    refute RuntimeAuthProvider.new.recover_needs_reauth(nil)
  end
end

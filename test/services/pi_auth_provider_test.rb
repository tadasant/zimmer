# frozen_string_literal: true

require "test_helper"

# PiAuthProvider is a deliberate no-op provider: Pi resolves a provider API key
# from the session environment per request and Zimmer pools nothing for it. The
# class exists because RuntimeAuthProvider.for RAISES for an unregistered
# runtime, and several runtime-agnostic call sites pass a session's raw
# agent_runtime straight into it.
class PiAuthProviderTest < ActiveSupport::TestCase
  setup do
    @provider = PiAuthProvider.new
  end

  test "is registered so runtime-agnostic call sites do not raise on a Pi session" do
    assert_instance_of PiAuthProvider, RuntimeAuthProvider.for("pi")
  end

  test "reports the pi runtime" do
    assert_equal "pi", @provider.runtime
  end

  # Callers chain `.available.exists?` / `.available.none?` onto this, so it has
  # to be a relation rather than nil or an Array.
  test "accounts is an empty but chainable relation" do
    assert_kind_of ActiveRecord::Relation, @provider.accounts
    assert_empty @provider.accounts
    assert_not @provider.accounts.available.exists?
  end

  test "there is no current or selectable account" do
    assert_nil @provider.current_account
    assert_nil @provider.select_account_for(Session.new(agent_runtime: "pi"))
  end

  # A runtime with no tokens is not a runtime whose tokens are broken.
  test "refresh reports healthy rather than failing" do
    result = @provider.refresh!(nil)

    assert result.ok?
    assert_nil result.error
  end

  test "injection is a no-op — the key arrives via the session env, not a file Zimmer writes" do
    assert_nothing_raised { @provider.inject_for_session!(Session.new(agent_runtime: "pi"), "/tmp") }
  end

  test "rotation is unsupported rather than broken" do
    assert_nil @provider.rotation_interval
    assert_not @provider.rotate_for_quota![:success]
  end

  # Pi has no tokens to refresh and no interactive login, so it must not be swept
  # by the refresh dispatcher or the auth warm-up.
  test "pi is deliberately absent from the runtimes the token dispatcher sweeps" do
    assert_not_includes RuntimeAuthProvider::RUNTIMES, "pi"
    assert_not_includes RuntimeAuthProvider.registered.map(&:runtime), "pi"
  end

  # No ClaudeAccount row can exist for pi, which is what makes #accounts
  # permanently empty rather than merely empty today.
  test "the account pool cannot hold a pi account" do
    assert_not_includes ClaudeAccount::RUNTIMES, "pi"
  end
end

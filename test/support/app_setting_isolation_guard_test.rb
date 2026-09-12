# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Guards the guard: a non-transactional test that leaves an `app_settings` row
# behind must FAIL, and must not take the rest of its worker down with it.
#
# The regression this exists for turned `main` red with two failures in
# `test/models/app_setting_test.rb`, from a class in `test/services/` that never
# mentions it. `AppSetting.new(...).valid?` is false while any row exists — the
# `only_one_row` create-context validation — so a leaked row is not inert state
# a later test can ignore, it is a wrong answer from a model that is working.
# See test/support/app_setting_isolation_guard.rb.
class AppSettingIsolationGuardTest < ActiveSupport::TestCase
  # The premise the whole guard rests on, pinned so a change to the validation
  # cannot quietly make the rest of this file vacuous.
  test "any app_settings row makes a new AppSetting invalid" do
    assert AppSetting.new(default_runtime: "claude_code", default_model: "opus").valid?

    AppSetting.editable.update!(spot_gating_enabled: false)

    refute AppSetting.new(default_runtime: "claude_code", default_model: "opus").valid?,
      "this is why a leaked row fails tests in files that never touch AppSetting"
  end

  test "a non-transactional test that leaks a row fails, and the leak stops there" do
    result = run_probe(transactional: false) { AppSetting.editable.update!(spot_gating_enabled: false) }

    assert_equal 1, result.failures.size, "the leak must fail the test that caused it"
    assert_includes result.failures.first.message, "left an app_settings row behind"
    assert_includes result.failures.first.message, "AppSettingIsolationGuardProbe#test_probe"
    assert_equal 0, AppSetting.count,
      "the guard deletes the leaked row, so the next test in this worker is unaffected"
  end

  test "a non-transactional test that cleans up after itself is left alone" do
    result = run_probe(transactional: false) do
      AppSetting.editable.update!(spot_gating_enabled: false)
      AppSetting.delete_all
      assert_equal 0, AppSetting.count
    end

    assert_empty result.failures
  end

  # The shape both fixed classes actually use — cleanup in a `teardown` block, not
  # in the body. Its innocence depends on a subclass's teardown running before the
  # base's; reverse that and every non-transactional test in the repo starts
  # failing while a body-only probe stays green.
  test "a non-transactional test that cleans up in its own teardown is left alone" do
    result = run_probe_class(transactional: false) do
      setup { AppSetting.editable.update!(spot_gating_enabled: false) }
      teardown { AppSetting.delete_all }
      define_method(:test_probe) { assert_equal 1, AppSetting.count }
    end

    assert_empty result.failures, "the guard must run after the test's own teardown, not before it"
  end

  # The far edge, and the reason the guard has two of them: a teardown that raises
  # after creating the row stops the chain before the check that would blame it.
  # The next test in the worker catches it, is told it is the messenger, and still
  # runs — the guard records its failure rather than raising.
  test "a leak whose teardown raised is caught at the next test's setup" do
    leaking = run_probe_class(transactional: false) do
      setup { AppSetting.editable.update!(spot_gating_enabled: false) }
      teardown { raise "a teardown that dies before it restores anything" }
      define_method(:test_probe) { assert true }
    end
    assert_equal 1, leaking.failures.size, "the raising teardown is reported against the probe"
    assert_kind_of Minitest::UnexpectedError, leaking.failures.first
    assert_equal 1, AppSetting.count, "and the row survives it — which is the whole hazard"

    body_ran = false
    messenger = run_probe(transactional: false) do
      body_ran = true
      assert_equal 0, AppSetting.count, "the body runs with the leak already cleared"
    end

    assert body_ran, "recording the failure rather than raising lets the test's own body run"
    assert_equal 1, messenger.failures.size
    assert_includes messenger.failures.first.message, "messenger, not the cause"
    assert_equal 0, AppSetting.count
  end

  test "a transactional test is not checked at all" do
    # Its row is rolled back, so there is nothing to catch — and the ~16,500 tests
    # that cannot leak must not pay for a query per test. Asserted on the decision
    # as well as on the query, because a rewrite to `AppSetting.ids` would charge
    # every test and still keep a `pluck`-only expectation green.
    AppSetting.expects(:pluck).never

    probe = build_probe(transactional: true) { define_method(:test_probe) { assert true } }
    refute AppSettingIsolationGuard.applies?(probe.new(:test_probe))

    result = probe.new(:test_probe).run

    assert_empty result.failures
  end

  # Rails' own predicate, not the class flag: a per-test opt-out inside a
  # transactional class runs outside a transaction and can leak like any other.
  test "a uses_transaction opt-out inside a transactional class is still guarded" do
    probe = build_probe(transactional: true) do
      uses_transaction :test_probe
      define_method(:test_probe) { assert true }
    end

    assert AppSettingIsolationGuard.applies?(probe.new(:test_probe))
  end

  private

  # Runs `body` as a single test through the whole ActiveSupport::TestCase
  # callback chain and hands back its Minitest result.
  #
  # The subclass is removed from Minitest's runnable list immediately: the run in
  # progress works from a copy, but anything walking it later would otherwise find
  # a test case that fails on purpose.
  def run_probe(transactional:, &body)
    run_probe_class(transactional: transactional) { define_method(:test_probe, &body) }
  end

  # The same, with a class body of its own — for a probe that needs setup and
  # teardown callbacks rather than only a test method.
  def run_probe_class(transactional:, &class_body)
    build_probe(transactional: transactional, &class_body).new(:test_probe).run
  end

  def build_probe(transactional:, &class_body)
    probe = Class.new(ActiveSupport::TestCase) do
      def self.name = "AppSettingIsolationGuardProbe"
    end
    probe.use_transactional_tests = transactional
    # A non-transactional probe would otherwise reset the process-global fixture
    # caches and reload every fixture — ~0.5s each, and it makes the NEXT test in
    # this worker reload them too. A file about worker-global leakage should not
    # leak one of its own.
    probe.fixture_table_names = []
    probe.class_eval(&class_body)
    Minitest::Runnable.runnables.delete(probe)

    probe
  end
end

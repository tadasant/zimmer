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

  test "a transactional test is not checked at all" do
    # Its row is rolled back, so there is nothing to catch — and the ~16,500 tests
    # that cannot leak must not pay for a query per test.
    AppSetting.expects(:pluck).never

    result = run_probe(transactional: true) { assert true }

    assert_empty result.failures
  end

  private

  # Runs `body` as a single test through the whole ActiveSupport::TestCase
  # callback chain and hands back its Minitest result.
  #
  # The subclass is removed from Minitest's runnable list immediately: the run in
  # progress works from a copy, but anything walking it later would otherwise find
  # a test case that fails on purpose.
  def run_probe(transactional:, &body)
    probe = Class.new(ActiveSupport::TestCase) do
      def self.name = "AppSettingIsolationGuardProbe"
    end
    probe.use_transactional_tests = transactional
    probe.send(:define_method, :test_probe, &body)
    Minitest::Runnable.runnables.delete(probe)

    probe.new(:test_probe).run
  end
end

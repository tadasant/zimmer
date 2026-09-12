# frozen_string_literal: true

# Fails the non-transactional test that leaves an `app_settings` row behind,
# instead of letting the row cascade through the rest of the worker.
#
# `AppSetting` is a singleton row with a create-context `only_one_row`
# validation, which makes `AppSetting.new(...).valid?` **false** for as long as
# any row exists. So a row is not inert state a later test can ignore: it is a
# validation result, and every test that asserts a valid pairing — AppSettingTest
# has five — fails on it, blaming a model that is working perfectly.
#
# The idiom that leaks is `AppSetting.editable.update!(...)` in a class that has
# turned transactions off (`order(:id).first || new`, so `update!` CREATES the
# row), with a teardown that puts the sessions back but not the setting.
# `SpotSessionHoldStarvationLaneRaceTest` did exactly that and turned `main` red
# with two failures in a file it does not touch, on a run whose blast radius
# depended entirely on which worker drew which test.
#
# Scoped to non-transactional tests on purpose. A test inside a transaction
# cannot leak — its row is rolled back — so checking one would buy nothing and
# cost a query on each of ~16,500 tests.
#
# Snapshot-based rather than "no row may exist at teardown": the guard blames the
# test that *created* a row, so a database that legitimately carries one is not
# accused by every non-transactional test that runs after it.
#
# Both edges of the test are checked, for the reason CacheIsolationGuard gives:
#
#   * `check!` in teardown blames the test that actually leaked.
#   * `check_boot_baseline!` in setup contains the damage when that check never
#     ran. ActiveSupport stops the `:teardown` chain at the first callback that
#     raises, and a test file's own teardown runs before the base's — so a
#     teardown that raises after creating the row and before restoring it takes
#     the teardown check down with it. That leak has to be catchable from the
#     far side too.
#
# What it does NOT catch: a non-transactional test that MUTATES a row that was
# already there. Both classes writing `app_settings` today capture the columns
# they write and put them back, and the existence hazard is the one that makes an
# unrelated file fail, so the cheaper check is the one that earns its query.
module AppSettingIsolationGuard
  class << self
    # The rows present before `parallelize` forked its workers — the baseline
    # every worker agrees on. Empty on every deployment today; captured rather
    # than assumed so a database that ships a row is not mistaken for a leak.
    attr_reader :boot_ids

    def capture!
      @boot_ids = AppSetting.pluck(:id)
    rescue => e
      Rails.logger.warn "[AppSettingIsolationGuard] could not capture the boot baseline: #{e.class}: #{e.message}"
      @boot_ids = nil
    end

    # Whether this test can leak at all.
    #
    # Rails' own predicate, not the class flag: `use_transactional_tests` is only
    # half of it, and a per-test `uses_transaction :test_foo` opt-out inside a
    # transactional class is the other half.
    def applies?(test)
      return !test.class.use_transactional_tests unless test.respond_to?(:run_in_transaction?, true)

      !test.send(:run_in_transaction?)
    end

    # The rows already there before the test ran, or nil when the table cannot be
    # read (a guard must never be the reason a suite fails).
    def snapshot(test)
      return nil unless applies?(test)

      AppSetting.pluck(:id)
    rescue => e
      Rails.logger.warn "[AppSettingIsolationGuard] could not snapshot app_settings: #{e.class}: #{e.message}"
      nil
    end

    # Deletes any row that appeared during `test` and records a failure on it
    # saying so.
    #
    # Records rather than raises, like CacheIsolationGuard: a raise from a
    # teardown callback skips every teardown declared before it, so the guard
    # would be creating new leaks of its own.
    def check!(test, before)
      return if before.nil?

      delete_and_blame(test, AppSetting.where.not(id: before).pluck(:id)) do
        failure_message(test)
      end
    end

    # The far edge: rows that are here at the START of a test and were not here
    # at boot. Something earlier in this worker created them and its own teardown
    # check never got to say so, so this test is the messenger rather than the
    # cause — and it still runs, because the guard records its failure rather
    # than raising.
    def check_boot_baseline!(test)
      return unless applies?(test)
      return if boot_ids.nil?

      delete_and_blame(test, AppSetting.where.not(id: boot_ids).pluck(:id)) do
        messenger_message
      end
    end

    private

    def delete_and_blame(test, leaked)
      return if leaked.empty?

      AppSetting.where(id: leaked).delete_all
      test.flunk(yield)
    rescue Minitest::Assertion => e
      test.failures << e
    rescue => e
      Rails.logger.warn "[AppSettingIsolationGuard] could not check app_settings: #{e.class}: #{e.message}"
    end

    public

    def failure_message(test)
      <<~MESSAGE.strip
        #{test.class.name}##{test.name} left an app_settings row behind, and this class runs
        with `use_transactional_tests = false`, so nothing rolls it back.

        `AppSetting.new(...).valid?` is false while ANY row exists — `only_one_row` is a
        create-context validation — so the row fails AppSettingTest's positive cases in
        whichever parallel worker draws them, naming a model that is working correctly.

        `AppSetting.editable` is `order(:id).first || new`, so `AppSetting.editable.update!`
        CREATES the row when there is none. Capture what was there and put it back:

            setup do
              existing = AppSetting.order(:id).first
              @previous_setting = existing&.slice(:the_columns_you_write)
              AppSetting.editable.update!(the_columns_you_write)
            end

            teardown do
              if @previous_setting
                AppSetting.editable.update!(@previous_setting)
              else
                AppSetting.delete_all
              end
            end

        The leaked row has been deleted, so the rest of this worker is unaffected.
      MESSAGE
    end

    def messenger_message
      <<~MESSAGE.strip
        An app_settings row was already here when this test started: an earlier test in this
        worker created one and did not remove it, and its teardown never got to say so — a
        teardown that raises stops the chain before the check that would have blamed it.
        This test is the messenger, not the cause.

        `AppSetting.new(...).valid?` is false while ANY row exists, so the row had to go
        before this test ran. It has been deleted; the rest of this worker is unaffected.
        Look for a class with `use_transactional_tests = false` that writes AppSetting.
      MESSAGE
    end
  end
end

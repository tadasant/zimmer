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
# Scoped to non-transactional classes on purpose. A transactional test cannot
# leak — its row is rolled back — so checking one would buy nothing and cost a
# query on each of ~16,500 tests.
#
# Snapshot-based rather than "no row may exist at teardown": the guard blames the
# test that *created* a row, so a deployment whose test database legitimately
# carries one is not accused by every non-transactional test that runs after it.
module AppSettingIsolationGuard
  class << self
    # Whether this test can leak at all.
    def applies?(test)
      !test.class.use_transactional_tests
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

      leaked = AppSetting.where.not(id: before).pluck(:id)
      return if leaked.empty?

      AppSetting.where(id: leaked).delete_all
      test.flunk(failure_message(test))
    rescue Minitest::Assertion => e
      test.failures << e
    rescue => e
      Rails.logger.warn "[AppSettingIsolationGuard] could not check app_settings: #{e.class}: #{e.message}"
    end

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
  end
end

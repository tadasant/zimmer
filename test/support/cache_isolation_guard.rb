# frozen_string_literal: true

# Fails the test that leaves `Rails.cache` swapped out, instead of letting the
# swap cascade through the rest of the worker.
#
# About twenty test files replace the test environment's `:null_store` with a real
# MemoryStore in `setup` and put the original back in `teardown`, because a store
# that agrees with everything cannot exercise a hysteresis streak, a cooldown or a
# heartbeat. That idiom has one failure mode, and it is severe: when the `setup`
# raises BEFORE the line that captures the original store, `@original_cache` is
# nil, the `teardown` runs anyway, and `Rails.cache` is left nil for every test
# that draws a later slot in that parallel worker. Nothing notices until some
# unrelated test calls `Rails.cache.fetch` and gets `NoMethodError` on nil — which
# is how one deleted constant turned into 87 errors across files that had nothing
# to do with it, in a run whose blast radius depended entirely on `--seed`.
#
# So the store is checked on both edges of every test:
#
#   * `teardown` blames the test that actually leaked.
#   * `setup` contains the damage when the teardown check never ran.
#     ActiveSupport stops running `:teardown` callbacks at the first one that
#     raises, and every teardown declared below the shared TestCase's — a test
#     file's, or a helper module's included after the guard — runs before it. One
#     that raises after botching its restore takes the teardown check down with
#     it, so the leak has to be catchable from the far side too. That check
#     records its failure rather than raising, so the test's own `setup` still
#     runs and captures a real store.
#
# Either edge puts the boot store back, which is what keeps one broken file to one
# failing file.
module CacheIsolationGuard
  class << self
    # The store every test starts and ends with: whatever `config.cache_store`
    # resolved to at boot, captured before parallelize() forks its workers so all
    # of them agree on the same object.
    attr_reader :boot_store

    def capture!
      @boot_store = current
    end

    def intact?
      current.equal?(@boot_store)
    end

    # Puts the boot store back and returns what was there, so the caller can say
    # what it found.
    def restore!
      leaked = current
      Rails.cache = @boot_store
      leaked
    end

    # The store Rails actually holds, read past any stub on the reader.
    # `Rails.cache` is a plain attr_accessor, so a leak is an assignment and lands
    # here. A mocha `Rails.stubs(:cache)` replaces the reader, not the value, and
    # mocha takes it off itself — but only after ActiveSupport's teardown
    # callbacks have run, so a check that called the reader would still see the
    # stub and blame a test that leaks nothing (BroadcastServiceTest does exactly
    # this).
    def current
      Rails.instance_variable_get(:@cache)
    end

    def failure_message(found, blame)
      <<~MESSAGE.strip
        Rails.cache was left as #{found.inspect} — #{blame}

        A test that swaps Rails.cache must restore it on every path out, including
        the one where its own setup raises before the store is captured:

            setup do
              @original_cache = Rails.cache          # capture FIRST, before
              Rails.cache = ActiveSupport::Cache::MemoryStore.new  # anything that can raise
            end

            teardown { Rails.cache = @original_cache if @original_cache }

        The boot store has been put back, so the rest of this worker is unaffected.
      MESSAGE
    end
  end
end

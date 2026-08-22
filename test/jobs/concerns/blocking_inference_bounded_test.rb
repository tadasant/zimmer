# frozen_string_literal: true

require "test_helper"

# The bound that keeps blocking inference from taking the whole `default` queue.
#
# The 2026-08-22 backlog incident happened because the previous bound keyed off
# the `headless:` argument while SessionStatusSummaryGenerator chooses the
# blocking path on `headless || pool_exhausted?`. During an account-quota outage
# every generation blocks and almost none of them carry the argument, so the
# limit stopped binding at exactly the moment it was needed.
class BlockingInferenceBoundedTest < ActiveSupport::TestCase
  # Every class that can block a `default` thread inside a one-shot inference
  # call. A new one must be added here and given the concern together.
  BOUNDED_JOBS = [ SessionStatusSummaryJob, SessionTitleJob ].freeze

  test "every blocking-inference job shares one concurrency key" do
    keys = BOUNDED_JOBS.map { |klass| klass.new(1).good_job_concurrency_key }

    assert_equal [ BlockingInferenceBounded::CONCURRENCY_KEY ], keys.uniq,
                 "blocking inference contends for `default`'s threads as one pool, so the " \
                 "classes must share a key — a per-class limit would let two classes take " \
                 "every thread"
  end

  test "the summary job is bounded whether or not the caller asked for headless" do
    # The caller does not decide whether the work blocks; the generator does,
    # off the account pool. So neither shape may be exempt.
    forked = SessionStatusSummaryJob.new(1)
    headless = SessionStatusSummaryJob.new(1, headless: true)

    assert_equal BlockingInferenceBounded::CONCURRENCY_KEY, forked.good_job_concurrency_key
    assert_equal BlockingInferenceBounded::CONCURRENCY_KEY, headless.good_job_concurrency_key
  end

  test "the bound is on perform, so a session's work is delayed and never dropped" do
    BOUNDED_JOBS.each do |klass|
      config = klass.good_job_concurrency_config

      assert_equal BlockingInferenceBounded::PERFORM_LIMIT, config[:perform_limit],
                   "#{klass} should be bounded at the shared perform limit"
      assert_nil config[:enqueue_limit],
                 "#{klass} carries a session id, so refusing an enqueue would drop that " \
                 "session's work rather than delay it"
      assert_nil config[:total_limit],
                 "#{klass} carries a session id, so refusing an enqueue would drop that " \
                 "session's work rather than delay it"
    end
  end

  test "the limit leaves half of the default queue for everything else" do
    # `default` carries three dozen other job classes. The margin between this
    # and ConnectionBudget's thread count is what guarantees they keep moving.
    assert_operator BlockingInferenceBounded::PERFORM_LIMIT, :<,
                    ConnectionBudget.good_job_queue_threads[:default]
  end

  test "both bounded jobs run on the default queue the limit is sized against" do
    BOUNDED_JOBS.each do |klass|
      assert_equal "default", klass.new(1).queue_name
    end
  end
end

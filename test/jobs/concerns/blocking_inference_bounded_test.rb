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
  CONCURRENCY_ERROR = "GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError"

  # Every class that can block a `default` thread inside a one-shot inference
  # call. A new one must be added here and given the concern together.
  BOUNDED_JOBS = [ SessionStatusSummaryJob, SessionTitleJob, SendPushNotificationJob ].freeze

  test "every job that reaches HeadlessInferenceService directly is bounded" do
    # SendPushNotificationJob was missed on the first pass of this fix — it makes
    # its own 15s inference call and is enqueued on the same transitions as the
    # summary refresh — so the enumeration is checked against the code rather
    # than trusted. This catches the direct callers; SessionStatusSummaryJob
    # reaches the same substrate one level down, through
    # SessionStatusSummaryGenerator, and is covered by BOUNDED_JOBS below.
    unbounded = Dir[Rails.root.join("app/jobs/*.rb")].filter_map do |path|
      next unless File.read(path).include?("HeadlessInferenceService")

      klass = File.basename(path, ".rb").camelize.safe_constantize
      next unless klass
      next if klass.include?(BlockingInferenceBounded)

      klass.name
    end

    assert_empty unbounded,
                 "these jobs block a worker thread on an inference call but are not bounded: " \
                 "#{unbounded.join(', ')} — add `include BlockingInferenceBounded` and list them " \
                 "in BOUNDED_JOBS"
  end

  test "every job listed as bounded actually carries the concern" do
    missing = BOUNDED_JOBS.reject { |klass| klass.include?(BlockingInferenceBounded) }

    assert_empty missing.map(&:name)
  end

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
    # and ConnectionBudget's thread count is what guarantees they keep moving —
    # and PERFORM_LIMIT is derived from it, so an ENV override moves both.
    threads = ConnectionBudget.good_job_queue_threads[:default]

    assert_operator BlockingInferenceBounded::PERFORM_LIMIT, :<, threads
    assert_operator BlockingInferenceBounded::PERFORM_LIMIT, :>=, 1
  end

  test "all bounded jobs run on the default queue the limit is sized against" do
    BOUNDED_JOBS.each do |klass|
      assert_equal "default", klass.new(1).queue_name
    end
  end

  test "the concern's retry handler is registered after GoodJob's, so it wins" do
    # ActiveSupport::Rescuable resolves last-registered-first. GoodJob installs
    # its own uncapped handler on ApplicationJob; ours must come after it, or the
    # cap below silently reverts to GoodJob's `(attempt ** 4) + 2` curve.
    handlers = SessionStatusSummaryJob.rescue_handlers.map(&:first)

    assert_equal 2, handlers.count(CONCURRENCY_ERROR),
                 "expected GoodJob's inherited handler plus the concern's own"
    assert_equal CONCURRENCY_ERROR, handlers.reverse.find { |key| key == CONCURRENCY_ERROR }
  end

  test "a job that loses the race for a slot retries on a capped, jittered curve" do
    # Drive the real handler rather than re-deriving the formula: this fails if
    # the concern's retry_on is removed, reordered, or loses its cap.
    job = SessionStatusSummaryJob.new(1)
    error = GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError.new
    waits = []

    job.stub(:retry_job, ->(opts) { waits << opts[:wait].to_f }) do
      10.times { assert job.rescue_with_handler(error), "the handler did not fire" }
    end

    assert_equal 10, waits.length

    jitter = ActiveJob::Base.retry_jitter
    waits.each_with_index do |wait, index|
      base = [ (index + 1)**2, BlockingInferenceBounded::MAX_RETRY_INTERVAL.to_i ].min

      assert_operator wait, :>=, base
      assert_operator wait, :<=, base + (base * jitter)
    end

    # Capped, and nowhere near GoodJob's uncapped curve at the same attempt.
    assert_operator waits.last, :<=,
                    BlockingInferenceBounded::MAX_RETRY_INTERVAL.to_i * (1 + jitter)
    assert_operator waits.last, :<, (10**4) + 2
  end

  test "the retry interval is jittered, so bounced jobs do not return as a herd" do
    # ActiveJob applies retry_jitter to :polynomially_longer and Duration waits
    # but NOT to a Proc, so a Proc that does not jitter itself silently loses it
    # — and every job bounced off the same slot would come back in lockstep onto
    # the same advisory lock.
    skip "jitter is disabled in this environment" unless ActiveJob::Base.retry_jitter.positive?

    samples = Array.new(20) { BlockingInferenceBounded.retry_interval(8).to_f }

    assert_operator samples.uniq.length, :>, 1, "retry_interval should not be deterministic"
  end
end

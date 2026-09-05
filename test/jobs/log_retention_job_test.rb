# frozen_string_literal: true

require "test_helper"

# The check on the only thing that bounds the `logs` table (tadasant/zimmer#437).
#
# Every test here seeds rows on BOTH sides of a boundary and asserts what
# survived, because the failure this job could have is silent in both directions:
# a prune that deletes nothing lets the table refill a disk, and a prune that
# deletes too much destroys timeline history nobody can regenerate.
class LogRetentionJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:running)
    # The fixtures seed logs of their own; this job is global by design, so start
    # from a table whose whole contents each test decides.
    Log.delete_all
    @last_age = nil
  end

  # Seeds one row with an exact age, and insists on oldest-first.
  #
  # That ordering is not fussiness: it is what production looks like, and
  # LogRetentionJob's primary-key ceiling is chosen for it (see the job). A test
  # that seeded a recent row before an old one would be exercising a table
  # Postgres's sequence cannot produce. `seed_unordered` is the deliberate
  # exception, used by the tests about that disagreement.
  def seed(level:, age:, content: "row", session: nil)
    if @last_age && age > @last_age
      raise ArgumentError, "seed oldest-first: #{age.inspect} is older than the #{@last_age.inspect} row before it"
    end
    @last_age = age

    seed_unordered(level: level, age: age, content: content, session: session)
  end

  def seed_unordered(level:, age:, content: "row", session: nil)
    log = Log.create!(session: session || @session, content: content, level: level)
    log.update_columns(created_at: age.ago, updated_at: age.ago)
    log
  end

  test "deletes verbose rows past the verbose window and keeps the ones inside it" do
    stale = seed(level: "verbose", age: Log::VERBOSE_RETENTION + 1.day)
    fresh = seed(level: "verbose", age: Log::VERBOSE_RETENTION - 1.day)

    LogRetentionJob.perform_now

    assert_not Log.exists?(stale.id), "a verbose row older than the verbose window must be pruned"
    assert Log.exists?(fresh.id), "a verbose row inside the verbose window must survive"
  end

  test "keeps non-verbose rows that are past the verbose window but inside the general one" do
    kept = Log::LEVELS.excluding(Log::VERBOSE_LEVEL).map do |level|
      seed(level: level, age: Log::VERBOSE_RETENTION + 1.day, content: "#{level} inside the general window")
    end

    LogRetentionJob.perform_now

    kept.each do |log|
      assert Log.exists?(log.id),
             "#{log.level} rows must be kept for the full #{Log::RETENTION.inspect}, not the verbose window"
    end
  end

  test "deletes every level past the general window" do
    stale = Log::LEVELS.map { |level| seed(level: level, age: Log::RETENTION + 1.day, content: "old #{level}") }
    fresh = Log::LEVELS.excluding(Log::VERBOSE_LEVEL).map do |level|
      seed(level: level, age: Log::RETENTION - 1.day, content: "recent #{level}")
    end

    LogRetentionJob.perform_now

    assert_equal [], Log.where(id: stale.map(&:id)).pluck(:id),
                 "every level must be pruned once it is past the general retention window"
    assert_equal fresh.map(&:id).sort, Log.where(id: fresh.map(&:id)).pluck(:id).sort,
                 "rows inside the general window must survive regardless of level"
  end

  # The exact boundary, both sides, one minute apart. A window enforced with the
  # wrong comparison direction passes every test above and fails this one.
  test "the boundary is the cutoff itself" do
    just_outside = seed(level: "info", age: Log::RETENTION + 1.minute)
    just_inside = seed(level: "info", age: Log::RETENTION - 1.minute)
    verbose_outside = seed(level: "verbose", age: Log::VERBOSE_RETENTION + 1.minute)
    verbose_inside = seed(level: "verbose", age: Log::VERBOSE_RETENTION - 1.minute)

    LogRetentionJob.perform_now

    assert_not Log.exists?(just_outside.id)
    assert Log.exists?(just_inside.id)
    assert_not Log.exists?(verbose_outside.id)
    assert Log.exists?(verbose_inside.id)
  end

  test "reports what it deleted" do
    2.times { seed(level: "info", age: Log::RETENTION + 1.day) }
    3.times { seed(level: "verbose", age: Log::VERBOSE_RETENTION + 1.day) }
    survivor = seed(level: "info", age: 1.hour)

    result = LogRetentionJob.perform_now

    assert_equal 2, result[:expired], "the general pass deletes the two rows past the 90-day window"
    assert_equal 3, result[:verbose], "the verbose pass deletes the three verbose rows past the 7-day window"
    assert_equal 5, result[:total]
    assert_equal [ survivor.id ], Log.pluck(:id)
  end

  test "does nothing, and deletes nothing, when every row is inside its window" do
    fresh = Log::LEVELS.map { |level| seed(level: level, age: 1.hour, content: "fresh #{level}") }

    result = LogRetentionJob.perform_now

    assert_equal({ expired: 0, verbose: 0, total: 0 }, result)
    assert_equal fresh.map(&:id).sort, Log.pluck(:id).sort
  end

  test "is a no-op on an empty table" do
    assert_equal({ expired: 0, verbose: 0, total: 0 }, LogRetentionJob.perform_now)
  end

  # The behaviour that makes the first run on a 124M-row table safe: a tick that
  # cannot finish stops at its budget, leaving the rest for the next tick, rather
  # than holding a worker thread (or one transaction) until the backlog is gone.
  test "a spent budget stops the pass and leaves the remainder for the next tick" do
    12.downto(1) { |i| seed(level: "verbose", age: Log::RETENTION + 1.day + i.minutes) }

    # Budget 0: the first chunk is refused outright, so nothing is deleted and the
    # work is entirely deferred.
    assert_equal({ expired: 0, verbose: 0, total: 0 }, LogRetentionJob.perform_now(budget: 0))
    assert_equal 12, Log.count, "a tick with no budget must delete nothing"

    # Chunked: with a batch of 5, the pass keeps going until the scope is empty,
    # which is what converges a backlog rather than deferring it forever.
    assert_equal 12, LogRetentionJob.perform_now(batch_size: 5)[:total]
    assert_equal 0, Log.count
  end

  test "deletes in chunks of batch_size rather than one statement" do
    10.times { seed(level: "info", age: Log::RETENTION + 1.day) }

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].to_s.start_with?("DELETE")
    end
    begin
      LogRetentionJob.perform_now(batch_size: 4)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 0, Log.count
    assert statements.size >= 3,
           "10 rows at a batch size of 4 must take at least three statements, not one big DELETE (got #{statements.size})"
    assert statements.all? { |sql| sql.include?("LIMIT") },
           "each delete must be bounded by the batch's LIMIT"
  end

  # The primary-key ceiling is an optimization; the cutoff is a predicate on the
  # delete itself. So when ids and timestamps disagree — which a sequence cannot
  # produce, but which these two tests force — the row inside the window survives.
  test "a row inside the window survives even with expired rows on both sides of it in id order" do
    below = seed_unordered(level: "info", age: Log::RETENTION + 10.days)
    inside = seed_unordered(level: "info", age: 1.hour)
    above = seed_unordered(level: "info", age: Log::RETENTION + 10.days)

    # The first tick's binary search stops under `inside` and collects `below`;
    # the second reaches `above` through the head probe. Both ticks leave `inside`
    # alone, which is the property that matters.
    LogRetentionJob.perform_now
    assert Log.exists?(inside.id)
    assert_not Log.exists?(below.id)

    LogRetentionJob.perform_now
    assert Log.exists?(inside.id),
           "a row inside the retention window must survive regardless of what its neighbours' ids say"
    assert_equal [ inside.id ], Log.pluck(:id)
  end

  # The regression that made the head probe necessary.
  #
  # With only the binary search, "the lowest-id row is inside its window" ended the
  # pass — and a single recent row with a low id then hid every expired row above
  # it, permanently. Retention silently never running again is exactly the failure
  # this job exists to prevent, so it has to converge here rather than report a
  # cheerful zero.
  test "a recent row at the head does not hide expired rows above it forever" do
    guard = seed_unordered(level: "info", age: 1.hour)
    stale = 20.times.map { |i| seed_unordered(level: "info", age: Log::RETENTION + 10.days + i.minutes) }

    assert_operator guard.id, :<, stale.map(&:id).min,
                    "the guard row has to sort first by id for this to be the case under test"

    result = LogRetentionJob.perform_now

    assert_equal 20, result[:total], "every expired row above the guard must be collected"
    assert_equal [ guard.id ], Log.pluck(:id)
  end

  # And it must still converge when the backlog is larger than one probe window,
  # which is what turns "stalled forever" into "drains over a few ticks".
  test "a backlog wider than the probe window drains across ticks" do
    guard = seed_unordered(level: "info", age: 1.hour)
    30.times { |i| seed_unordered(level: "info", age: Log::RETENTION + 10.days + i.minutes) }

    ticks = 0
    while Log.expired.exists? && ticks < 10
      LogRetentionJob.perform_now(batch_size: 4)
      ticks += 1
    end

    assert_equal [ guard.id ], Log.pluck(:id), "the backlog above the guard drained in #{ticks} tick(s)"
  end

  test "retention is an age policy, not a per-session one" do
    other = sessions(:waiting)
    stale_theirs = seed(level: "info", age: Log::RETENTION + 1.day, content: "old theirs", session: other)
    mine = seed(level: "info", age: 1.hour)
    theirs = seed(level: "info", age: 1.minute, content: "theirs", session: other)

    LogRetentionJob.perform_now

    assert Log.exists?(mine.id)
    assert Log.exists?(theirs.id)
    assert_not Log.exists?(stale_theirs.id),
               "an expired row is expired whichever session wrote it"
  end

  test "runs on the maintenance lane and is a singleton" do
    assert_equal "maintenance", LogRetentionJob.new.queue_name
    assert_equal 1, LogRetentionJob.good_job_concurrency_config[:total_limit],
                 "a bulk delete must not stack copies of itself when a tick runs long"
  end

  test "is scheduled in every environment that has a cron schedule" do
    CronSchedule::ENVIRONMENTS.each do |environment|
      classes = CronSchedule.for(environment).values.map { |entry| entry[:class] }
      assert_includes classes, "LogRetentionJob",
                      "#{environment} schedules no log retention, so its logs table is unbounded"
    end
  end
end

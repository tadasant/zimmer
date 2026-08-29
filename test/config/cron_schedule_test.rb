# frozen_string_literal: true

require "test_helper"
require "json"

# The GoodJob cron table used to be three copied literals, one per environment file, and
# nothing kept them in step. A job added to one and forgotten in another was scheduled
# there and silently never ran here: no error, no log, no alert.
#
# That is not hypothetical. GithubTriggerPollerJob was added to production.rb only, and
# the omission was invisible until the trigger was exercised end-to-end on staging: the
# UI accepted the trigger, the condition validated, and the poller simply never ticked.
#
# The table now lives once, in config/cron_schedule.rb, and each entry names the
# environments it runs in. This file is the check on that table. Its first job is the
# boring one -- pin the fully resolved hash per environment against a snapshot, so a
# typo'd expression, a dropped entry or a duplicated key fails CI instead of quietly
# stopping a job forever. The snapshot was captured from the three literals as they
# stood before the refactor (tadasant/zimmer#457), which is what makes that refactor
# provably behaviour-preserving; changing a job's schedule now means updating it, on
# purpose, in a diff a reviewer can read.
class CronScheduleTest < ActiveSupport::TestCase
  SCHEDULE_FILE = Rails.root.join("config/cron_schedule.rb")
  PINNED = JSON.parse(Rails.root.join("test/fixtures/files/good_job_cron_schedule.json").read).freeze

  # Entries production schedules and staging does not, each with the reason. Adding to
  # this list should be a conscious decision, not a way to silence the test below.
  #
  # Both of these are inherited, unratified omissions rather than decisions anyone made:
  # the reason recorded here predates tadasant/zimmer#457 and nobody has ruled on whether
  # staging should run them. It is repeated on the entries themselves in
  # config/cron_schedule.rb. Development running SlackTriggerHealthCheckJob is hard to
  # square with the stated reason, which is the strongest sign it wants a human's answer.
  # tadasant/zimmer#686 is the open decision.
  NOT_ON_STAGING = {
    "EgressHealthCheckJob" =>
      "alerting canary: it pages #eng-alerts, and a staging copy would double-page on " \
      "production's own signals",
    "SlackTriggerHealthCheckJob" =>
      "same -- though development schedules it, which the reason does not explain"
  }.freeze

  def resolved(environment)
    CronSchedule.for(environment).to_h { |name, entry| [ name.to_s, entry.transform_keys(&:to_s) ] }
  end

  def job_classes(environment)
    CronSchedule.for(environment).values.map { |entry| entry[:class] }.to_set
  end

  # --- the pin -------------------------------------------------------------------

  test "each environment resolves to exactly the pinned schedule" do
    CronSchedule::ENVIRONMENTS.each do |environment|
      expected = PINNED.fetch(environment.to_s)
      actual = resolved(environment)

      assert_equal expected.keys.to_set, actual.keys.to_set,
                   "the set of cron entries for #{environment} changed. Dropped: " \
                   "#{(expected.keys - actual.keys).sort.inspect}; added: " \
                   "#{(actual.keys - expected.keys).sort.inspect}. If that is intended, update " \
                   "test/fixtures/files/good_job_cron_schedule.json in the same commit."

      expected.each do |name, entry|
        assert_equal entry, actual.fetch(name),
                     "the #{name} cron entry for #{environment} changed. Update " \
                     "test/fixtures/files/good_job_cron_schedule.json in the same commit if intended."
      end
    end
  end

  test "the pin covers every environment that has a schedule, and no others" do
    assert_equal CronSchedule::ENVIRONMENTS.map(&:to_s).to_set, PINNED.keys.to_set
  end

  test "every environment file delegates to the single schedule" do
    CronSchedule::ENVIRONMENTS.each do |environment|
      source = Rails.root.join("config/environments/#{environment}.rb").read

      assert_includes source, "config.good_job.cron = CronSchedule.for(:#{environment})",
                      "config/environments/#{environment}.rb no longer resolves its cron from " \
                      "config/cron_schedule.rb"
      refute_includes source, "config.good_job.cron = {",
                      "config/environments/#{environment}.rb declares a cron literal again. That is the " \
                      "duplication tadasant/zimmer#457 removed; a second copy drifts from the first in silence."
    end
  end

  test "the schedule file is required at boot rather than autoloaded" do
    # config/environments/*.rb runs before eager loading, so an autoloaded constant here
    # would raise NameError during boot -- in the worker process, where a schedule that
    # fails to load is a fleet with no cron at all.
    assert_includes Rails.root.join("config/application.rb").read, %(require_relative "cron_schedule")
  end

  test "no cron entry name is declared twice" do
    # A duplicated key in a Ruby hash literal does not raise: the second silently wins,
    # and the first job is gone. Count the names in the source rather than in the hash.
    names = SCHEDULE_FILE.read.scan(/^    (\w+): \{$/).flatten
    duplicates = names.tally.select { |_, count| count > 1 }.keys

    assert_empty duplicates, "config/cron_schedule.rb declares these entries more than once: #{duplicates.inspect}"
    assert_equal names.size, CronSchedule::ENTRIES.size,
                 "config/cron_schedule.rb has #{names.size} entry names in its source but " \
                 "#{CronSchedule::ENTRIES.size} in ENTRIES"
  end

  # --- what runs where -----------------------------------------------------------

  test "staging schedules every cron job production does, minus the declared exceptions" do
    missing = job_classes(:production) - job_classes(:staging) - NOT_ON_STAGING.keys.to_set

    assert_empty missing,
                 "These cron jobs are scheduled in production but not staging: #{missing.to_a.sort.join(', ')}. " \
                 "Add :staging to their `environments:` in config/cron_schedule.rb, or list them in " \
                 "NOT_ON_STAGING with a reason."
  end

  test "the staging omissions are exactly the ones declared here" do
    # The other direction: an entry that quietly stops running on staging has to be
    # written down before this passes again.
    omitted = (job_classes(:production) - job_classes(:staging)).to_a.sort

    assert_equal NOT_ON_STAGING.keys.sort, omitted,
                 "the set of jobs production runs and staging does not has changed. Every one of them " \
                 "needs an entry in NOT_ON_STAGING saying why."
  end

  test "staging does not schedule cron jobs production has never heard of" do
    extra = job_classes(:staging) - job_classes(:production)

    assert_empty extra,
                 "These cron jobs are scheduled in staging but not production: #{extra.to_a.sort.join(', ')}. " \
                 "A job that only ever runs on staging is almost certainly a mistake."
  end

  test "development schedules nothing production does not" do
    extra = job_classes(:development) - job_classes(:production)

    assert_empty extra, "Scheduled in development but not production: #{extra.to_a.sort.join(', ')}"
  end

  test "the GitHub trigger poller is scheduled in both deployed environments" do
    # The regression that motivated this file: a trigger type is useless in an
    # environment whose cron never runs its poller.
    %i[production staging].each do |environment|
      assert_includes job_classes(environment), "GithubTriggerPollerJob",
                      "GithubTriggerPollerJob is not scheduled in #{environment}; github_label and " \
                      "github_issue conditions would never fire there."
    end
  end

  test "every cron job class actually exists" do
    CronSchedule::ENTRIES.each do |name, entry|
      assert entry[:class].safe_constantize, "#{name} schedules #{entry[:class]}, but no such class exists"
    end
  end

  # --- the resolver --------------------------------------------------------------

  test "for/1 hands GoodJob only the keys it reads" do
    CronSchedule::ENVIRONMENTS.each do |environment|
      CronSchedule.for(environment).each do |name, entry|
        assert_equal CronSchedule::GOOD_JOB_KEYS, entry.keys,
                     "#{name} resolves to #{entry.keys.inspect} in #{environment}; GoodJob reads " \
                     "#{CronSchedule::GOOD_JOB_KEYS.inspect} and `environments` is ours, not its"
      end
    end
  end

  test "for/1 filters by environment and applies a per-environment override" do
    entries = {
      everywhere: {
        cron: "* * * * *", class: "HeartbeatSweepJob", description: "everywhere",
        environments: %i[production staging development]
      },
      production_only: {
        cron: "0 7 * * *", class: "CertExpiryMonitorJob", description: "prod",
        environments: %i[production]
      },
      slower_locally: {
        cron: "*/30 * * * * *", class: "ZombieReaperJob", description: "override",
        environments: %i[production development],
        cron_overrides: { development: "*/10 * * * *" }
      }
    }

    assert_equal %i[everywhere production_only slower_locally], CronSchedule.for(:production, entries).keys
    assert_equal %i[everywhere], CronSchedule.for(:staging, entries).keys
    assert_equal %i[everywhere slower_locally], CronSchedule.for(:development, entries).keys

    assert_equal "*/30 * * * * *", CronSchedule.for(:production, entries).dig(:slower_locally, :cron)
    assert_equal "*/10 * * * *", CronSchedule.for(:development, entries).dig(:slower_locally, :cron)
  end

  test "for/1 accepts a string environment and rejects an unknown one" do
    assert_equal CronSchedule.for(:production), CronSchedule.for("production")
    assert_raises(ArgumentError) { CronSchedule.for(:test) }
  end

  test "validate! rejects a table that would schedule nothing, or nothing that fires" do
    valid = { cron: "* * * * *", class: "HeartbeatSweepJob", description: "d", environments: %i[production] }

    assert_nothing_raised { CronSchedule.validate!({ ok: valid }) }

    CronSchedule::GOOD_JOB_KEYS.each do |key|
      assert_raises(RuntimeError) { CronSchedule.validate!({ broken: valid.except(key) }) }
    end

    assert_raises(RuntimeError) { CronSchedule.validate!({ broken: valid.merge(environments: []) }) }
    assert_raises(RuntimeError) { CronSchedule.validate!({ broken: valid.merge(environments: %i[qa]) }) }
    assert_raises(RuntimeError) do
      CronSchedule.validate!({ broken: valid.merge(cron_overrides: { staging: "0 * * * *" }) })
    end
  end

  # --- cron syntax ---------------------------------------------------------------
  #
  # The seconds field is load-bearing. Three pollers are scheduled with six-field cron
  # ("*/30 * * * * *") and their comments promise a 30-second cadence. GoodJob does not
  # normalize that: CronEntry#next_at hands the expression straight to Fugit::Cron#next_time.
  # If a fugit upgrade ever stopped honoring the leading seconds field, those pollers would
  # quietly drop to some other cadence with no error anywhere. Assert it instead of trusting it.

  def cron_expressions
    CronSchedule::ENTRIES.values.map { |entry| entry[:cron] } +
      CronSchedule::ENTRIES.values.flat_map { |entry| (entry[:cron_overrides] || {}).values }
  end

  test "every cron expression in the schedule parses" do
    refute_empty cron_expressions

    cron_expressions.each do |expression|
      assert_instance_of Fugit::Cron, Fugit.parse_cron(expression),
                         "#{expression.inspect} is not a cron expression GoodJob can schedule"
    end
  end

  # Asserted against the expressions actually in the config, not a literal, so this covers
  # both halves: a fugit that stopped honoring the seconds field, and an edit that quietly
  # demoted one of these pollers to a five-field cron while leaving its "30 seconds" comment.
  test "every six-field cron expression in the schedule fires on second boundaries" do
    scanned = cron_expressions.uniq.select { |expression| expression.split.size == 6 }

    refute_empty scanned,
                 "No six-field cron expressions left in the schedule. If that was deliberate, delete " \
                 "this test and the 'Sub-minute cron works' note in docs/operate/background-jobs.md."

    scanned.each do |expression|
      parsed = Fugit.parse_cron(expression)

      refute_equal [ 0 ], parsed.seconds,
                   "#{expression.inspect} is six-field but resolves to one fire per minute; fugit is no " \
                   "longer reading the leading seconds field"

      from = Time.utc(2026, 1, 1, 0, 0, 0)
      fire_times = 4.times.each_with_object([]) do |_, times|
        from = parsed.next_time(from).to_t.utc
        times << from
      end

      gaps = fire_times.each_cons(2).map { |a, b| b - a }
      assert gaps.all? { |gap| gap < 60 },
             "#{expression.inspect} is six-field but fires no more than once a minute: gaps #{gaps.inspect} " \
             "(#{fire_times.map { |t| t.strftime('%H:%M:%S') }.inspect})"

      # Every six-field entry in the config today is "*/30 * * * * *", and three job comments
      # plus docs/operate/background-jobs.md all state 30 seconds. Pin that exact number for
      # those, while leaving a differently-spaced six-field entry free to be added above.
      next unless expression == "*/30 * * * * *"

      assert_equal [ 30, 30, 30 ], gaps,
                   "expected a 30-second cadence from #{expression.inspect}, got #{gaps.inspect}"
    end
  end

  test "five-field cron is the same expression with seconds pinned to zero" do
    # This is why "* * * * *" means once a minute: not because seconds are unsupported,
    # but because the omitted seconds field defaults to 0.
    assert_equal [ 0 ], Fugit.parse_cron("* * * * *").seconds
  end
end

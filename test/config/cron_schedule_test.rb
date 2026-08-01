# frozen_string_literal: true

require "test_helper"

# The GoodJob cron table is duplicated: config/environments/production.rb and
# config/environments/staging.rb each declare their own `config.good_job.cron` hash.
# Nothing keeps them in step, so a job added to one and forgotten in the other is
# scheduled in that environment and silently never runs in the other.
#
# That is not hypothetical. GithubTriggerPollerJob was added to production.rb only, and
# the omission was invisible until the trigger was exercised end-to-end on staging: the
# UI accepted the trigger, the condition validated, and the poller simply never ticked —
# no error, no alert, just a trigger that never fired.
#
# This test makes that failure loud. Staging must schedule everything production does,
# except for jobs deliberately listed as production-only below.
class CronScheduleTest < ActiveSupport::TestCase
  # Jobs that intentionally run only in production. Adding to this list should be a
  # conscious decision, not a way to silence the test.
  #
  # - EgressHealthCheckJob / SlackTriggerHealthCheckJob: alerting canaries. They page
  #   #eng-alerts, and a staging copy would double-page on production's own signals.
  PRODUCTION_ONLY = %w[
    EgressHealthCheckJob
    SlackTriggerHealthCheckJob
  ].freeze

  def cron_job_classes(env)
    source = Rails.root.join("config/environments/#{env}.rb").read
    source.scan(/class:\s*"([A-Za-z0-9_:]+)"/).flatten.to_set
  end

  test "staging schedules every cron job production does, minus the explicit exceptions" do
    production = cron_job_classes("production")
    staging = cron_job_classes("staging")

    missing = production - staging - PRODUCTION_ONLY.to_set

    assert_empty missing,
                 "These cron jobs are scheduled in production but not staging: #{missing.to_a.sort.join(', ')}. " \
                 "Add them to config/environments/staging.rb, or list them in PRODUCTION_ONLY with a reason."
  end

  test "staging does not schedule cron jobs production has never heard of" do
    production = cron_job_classes("production")
    staging = cron_job_classes("staging")

    extra = staging - production

    assert_empty extra,
                 "These cron jobs are scheduled in staging but not production: #{extra.to_a.sort.join(', ')}. " \
                 "A job that only ever runs on staging is almost certainly a mistake."
  end

  test "the GitHub trigger poller is scheduled in both environments" do
    # The regression that motivated this file: a trigger type is useless in an
    # environment whose cron never runs its poller.
    %w[production staging].each do |env|
      assert_includes cron_job_classes(env), "GithubTriggerPollerJob",
                      "GithubTriggerPollerJob is not scheduled in #{env}; github_label and " \
                      "github_issue conditions would never fire there."
    end
  end

  # The seconds field is load-bearing. Three pollers are scheduled with six-field cron
  # ("*/30 * * * * *") and their comments promise a 30-second cadence. GoodJob does not
  # normalize that: CronEntry#next_at hands the expression straight to Fugit::Cron#next_time.
  # If a fugit upgrade ever stopped honoring the leading seconds field, those pollers would
  # quietly drop to some other cadence with no error anywhere. Assert it instead of trusting it.
  ENVIRONMENTS = %w[production staging development].freeze

  def cron_expressions(env)
    source = Rails.root.join("config/environments/#{env}.rb").read
    source.scan(/cron:\s*"([^"]+)"/).flatten
  end

  test "every cron expression in every environment parses" do
    ENVIRONMENTS.each do |env|
      expressions = cron_expressions(env)
      refute_empty expressions, "No cron expressions found in config/environments/#{env}.rb"

      expressions.each do |expression|
        parsed = Fugit.parse_cron(expression)
        assert_instance_of Fugit::Cron, parsed,
                           "#{expression.inspect} in #{env}.rb is not a cron expression GoodJob can schedule"
      end
    end
  end

  # Asserted against the expressions actually in the config, not a literal, so this covers
  # both halves: a fugit that stopped honoring the seconds field, and an edit that quietly
  # demoted one of these pollers to a five-field cron while leaving its "30 seconds" comment.
  test "every six-field cron expression in the config fires on second boundaries" do
    scanned = ENVIRONMENTS.flat_map { |env| cron_expressions(env) }.uniq.select { |e| e.split.size == 6 }

    refute_empty scanned,
                 "No six-field cron expressions left in any environment. If that was deliberate, delete " \
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

  test "every cron job class named in either environment actually exists" do
    (cron_job_classes("production") | cron_job_classes("staging")).each do |name|
      klass = begin
        name.constantize
      rescue NameError
        nil
      end

      assert klass, "#{name} is scheduled by cron but no such class exists"
    end
  end
end

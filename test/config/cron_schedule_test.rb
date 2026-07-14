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

# frozen_string_literal: true

require "test_helper"

# Holds the line drawn by SingletonSweep.
#
# GoodJob's cron enqueues on schedule whether or not the previous tick has run,
# so an unguarded recurring sweep has a fixed arrival rate that cannot fall under
# load. On 2026-08-22 that put 39 ready HeartbeatSweepJob copies on `default`
# while `pollers` — where every recurring job is already a singleton — sat at 2.
# This test is what stops the next sweep from being added back unguarded.
class RecurringSweepConcurrencyTest < ActiveSupport::TestCase
  # Recurring `default` jobs that must NOT be keyed on their class, each with the
  # reason. An arity check cannot express this — every one of these takes
  # arguments, but so do jobs that should be guarded, and `CertExpiryMonitorJob`
  # slipped through such a check for a whole review cycle because its arguments
  # are test-injection seams. So the exemption is written down instead of
  # inferred, and adding to this list means writing the reason.
  EXEMPT = {
    "RefreshRuntimeAuthTokensJob" =>
      "re-enqueues itself with retry_account_ids/attempt to chain a retry; a " \
      "class-wide key would block the chain behind the cron copy",
    "RefreshMcpOauthTokensJob" =>
      "re-enqueues itself with retry_credential_ids/attempt to chain a retry",
    "RefreshXOauthTokensJob" =>
      "re-enqueues itself with retry_credential_ids/attempt to chain a retry"
  }.freeze

  # Resolved from the real schedule (config/cron_schedule.rb), not from a list kept
  # here, which is what keeps this test honest about what actually ships.
  def self.cron_job_class_names
    names = CronSchedule.for(:production).values.map { |entry| entry[:class] }.uniq
    raise "no cron entries found in config/cron_schedule.rb" if names.empty?

    names
  end

  test "every recurring job named in the production cron table resolves" do
    unresolvable = self.class.cron_job_class_names.reject { |name| name.safe_constantize }

    assert_empty unresolvable,
                 "the production cron schedule names job classes that do not exist: " \
                 "#{unresolvable.join(', ')}"
  end

  test "every recurring sweep on the default queue is a singleton or a documented exemption" do
    unguarded = self.class.cron_job_class_names.filter_map do |name|
      klass = name.safe_constantize
      next unless klass
      next unless klass.new.queue_name == "default"
      next if EXEMPT.key?(name)
      next if klass.good_job_concurrency_config[:total_limit] == 1

      name
    end

    assert_empty unguarded, <<~MESSAGE
      These recurring sweeps run on the shared `default` queue and are not singletons, so
      cron will stack copies of them whenever the queue is congested:

        #{unguarded.join("\n  ")}

      Add `include SingletonSweep`. If a sweep genuinely needs to overlap with itself — it
      re-enqueues itself with arguments to chain a retry, say — add it to EXEMPT above with
      the reason, rather than silencing this test.
    MESSAGE
  end

  test "every exemption still names a job that is actually scheduled" do
    # An exemption for a job that no longer exists is a hole nobody can see.
    scheduled = self.class.cron_job_class_names

    EXEMPT.each_key do |name|
      assert_includes scheduled, name,
                      "#{name} is exempted but no longer appears in the production cron table"
      assert EXEMPT[name].present?, "#{name}'s exemption must carry a reason"
    end
  end

  test "SingletonSweep keys each sweep by its own class so sweeps do not block each other" do
    assert_equal "HeartbeatSweepJob", HeartbeatSweepJob.new.good_job_concurrency_key
    assert_equal "EmptyTrashJob", EmptyTrashJob.new.good_job_concurrency_key
  end

  test "SingletonSweep bounds queued and running copies together" do
    # `total_limit`, not `enqueue_limit`: GoodJob excludes claimed jobs from an
    # enqueue_limit count, which would let a second copy queue behind a sweep
    # that is still running — the pile-up this exists to prevent.
    config = HeartbeatSweepJob.good_job_concurrency_config

    assert_equal 1, config[:total_limit]
    assert_nil config[:enqueue_limit]
  end
end

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
  PRODUCTION_ENV_FILE = Rails.root.join("config/environments/production.rb")

  # The production cron table is a literal hash in the environment file, which no
  # test environment loads. Reading the class names out of it directly is what
  # keeps this test honest about the schedule that actually ships.
  def self.cron_job_class_names
    names = PRODUCTION_ENV_FILE.read.scan(/^\s*class:\s*"(\w+)"/).flatten.uniq
    raise "no cron entries found in #{PRODUCTION_ENV_FILE}" if names.empty?

    names
  end

  # A sweep that takes arguments re-enqueues itself with them to chain retries,
  # and a class-wide key would block that chain behind the cron copy. So the
  # guarantee is scoped to the argument-less ones.
  def self.argument_less?(klass)
    klass.instance_method(:perform).parameters.empty?
  end

  test "every recurring job named in the production cron table resolves" do
    unresolvable = self.class.cron_job_class_names.reject { |name| name.safe_constantize }

    assert_empty unresolvable,
                 "config/environments/production.rb schedules job classes that do not exist: " \
                 "#{unresolvable.join(', ')}"
  end

  test "every argument-less recurring sweep on the default queue is a singleton" do
    unguarded = self.class.cron_job_class_names.filter_map do |name|
      klass = name.safe_constantize
      next unless klass
      next unless klass.new.queue_name == "default"
      next unless self.class.argument_less?(klass)
      next if klass.good_job_concurrency_config[:total_limit] == 1

      name
    end

    assert_empty unguarded, <<~MESSAGE
      These recurring sweeps run on the shared `default` queue, take no arguments, and are
      not singletons, so cron will stack copies of them whenever the queue is congested:

        #{unguarded.join("\n  ")}

      Add `include SingletonSweep` to each. If a sweep genuinely needs to overlap with
      itself, give it arguments that distinguish the runs — do not silence this test.
    MESSAGE
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

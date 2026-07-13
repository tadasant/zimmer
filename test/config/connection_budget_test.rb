# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# An ActiveRecord pool is a promise the database has to be able to keep, and the pool is
# lazy -- so an app that promises more connections than its cluster has slots looks
# perfectly healthy until real traffic calls the promise in, at which point Postgres
# answers FATAL "remaining connection slots are reserved for roles with the SUPERUSER
# attribute" and Rails turns that into a 500.
#
# Nothing in a Rails boot checks that promise against the server. These assertions are
# that check: they pin the derivation, and they pin it to the number Terraform enforces
# against the cluster's plan, so the two halves of the budget cannot drift apart.
class ConnectionBudgetTest < ActiveSupport::TestCase
  MAIN_TF = Rails.root.join("infra/terraform/main.tf")
  DATABASE_YML = Rails.root.join("config/database.yml")

  # ConnectionBudget reads the process's shape from ENV and $PROGRAM_NAME, because that
  # is all database.yml can know about itself. To assert the shape of a process this one
  # is not, borrow it and give it back.
  def as_process(rails_env:, program_name: $PROGRAM_NAME, **env)
    previous_env = ENV.to_h.slice("RAILS_ENV", *env.keys)
    previous_program_name = $PROGRAM_NAME
    ENV["RAILS_ENV"] = rails_env
    env.each { |key, value| ENV[key] = value&.to_s }
    $PROGRAM_NAME = program_name
    yield
  ensure
    env.each_key { |key| ENV.delete(key) }
    previous_env.each { |key, value| ENV[key] = value }
    $PROGRAM_NAME = previous_program_name
  end

  def as_web(rails_env: "production", **env, &block)
    as_process(rails_env: rails_env, program_name: "/rails/bin/rails", **env, &block)
  end

  def as_worker(rails_env: "production", **env, &block)
    as_process(rails_env: rails_env, program_name: "/usr/local/bundle/ruby/3.4.0/bin/good_job", **env, &block)
  end

  # --- The invariant that the pools exist to satisfy ---------------------------

  test "the worker's primary pool covers every GoodJob thread that can hold a connection" do
    as_worker do
      # An executing GoodJob job holds its connection for the whole job -- the advisory
      # lock it takes is session-scoped, so GoodJob leases the connection stickily. With
      # agent jobs that run for hours, a pool short of the scheduler count is not a queue,
      # it is a stall. GoodJob's own SharedExecutor threads query too.
      threads = ConnectionBudget.good_job_scheduler_threads + ConnectionBudget::GOOD_JOB_UTILITY_THREADS
      assert_operator ConnectionBudget.primary_pool, :>=, threads
    end
  end

  test "the web pool covers Puma's request threads and NOT the worker's job threads" do
    as_web("RAILS_MAX_THREADS" => 3) do
      assert_operator ConnectionBudget.primary_pool, :>=, 3
      # The whole defect: handing the web process a pool sized for GoodJob's schedulers.
      assert_operator ConnectionBudget.primary_pool, :<, ConnectionBudget.good_job_scheduler_threads
    end
  end

  test "development runs GoodJob in-process, so its pool covers Puma AND the schedulers" do
    as_web(rails_env: "development") do
      assert_equal :async, ConnectionBudget.execution_mode
      assert_operator ConnectionBudget.primary_pool, :>=,
                      ConnectionBudget.good_job_scheduler_threads + Integer(ENV.fetch("RAILS_MAX_THREADS", 3))
    end
  end

  test "the cable pool is sized for in-flight broadcasts, not for job threads" do
    # solid_cable takes no advisory lock, so a cable connection is leased per INSERT and
    # returned -- a broadcast from an hours-long agent job holds one for the write only.
    as_worker do
      assert_operator ConnectionBudget.cable_pool, :<, ConnectionBudget.primary_pool
    end
  end

  # --- Threads and the pool that serves them move together ---------------------

  test "raising a queue's thread count raises the worker's pool with it" do
    baseline = as_worker { ConnectionBudget.primary_pool }
    raised = as_worker("GOOD_JOB_AGENTS_THREADS" => 20) { ConnectionBudget.primary_pool }

    assert_equal baseline + 4, raised
  end

  test "the queue string GoodJob is configured with is the one the budget counted" do
    as_worker("GOOD_JOB_AGENTS_THREADS" => 20) do
      assert_includes ConnectionBudget.good_job_queues, "agents:20"
      assert_equal 20 + 3 + 2 + 4, ConnectionBudget.good_job_scheduler_threads
    end
  end

  test "max_threads cannot authorize more threads than the queues declare" do
    as_worker do
      assert_equal ConnectionBudget.good_job_scheduler_threads, ConnectionBudget.good_job_max_threads
    end
  end

  # --- The server-side budget --------------------------------------------------

  test "the budget counts both roles, the notifier's connection, and a Kamal cutover" do
    expected = (ConnectionBudget.web_connections + ConnectionBudget.worker_connections) *
               ConnectionBudget::DEPLOY_CUTOVER_MULTIPLIER + ConnectionBudget::OPERATOR_RESERVE

    assert_equal expected, ConnectionBudget.required_backends
    # Kamal health-gates its cutover by running the old and new containers together, so
    # every connection exists twice for that window. Budgeting for steady state alone is
    # what makes a deploy the most dangerous moment in the system.
    assert_operator ConnectionBudget::DEPLOY_CUTOVER_MULTIPLIER, :>=, 2
    # GoodJob's Notifier checks a LISTEN connection out and then REMOVES it from the pool,
    # so it is a real backend that no pool size accounts for.
    assert_operator ConnectionBudget.worker_connections, :>,
                    ConnectionBudget.primary_pool + ConnectionBudget.cable_pool
  end

  test "the budget is a property of the deployment, not of the process reading it" do
    # Terraform enforces one number. If it moved with RAILS_ENV, it would enforce the
    # wrong one.
    budgets = %w[development test staging production].map do |env|
      as_web(rails_env: env) { ConnectionBudget.required_backends }
    end

    assert_equal 1, budgets.uniq.size, "required_backends differs by environment: #{budgets.inspect}"
  end

  # --- The two halves cannot drift apart ---------------------------------------

  test "Terraform enforces exactly the budget this app derives" do
    default = MAIN_TF.read[/variable "app_required_backends".*?default\s*=\s*(\d+)/m, 1]

    assert default, "infra/terraform/main.tf no longer declares an app_required_backends default"
    assert_equal ConnectionBudget.required_backends, Integer(default),
                 "infra/terraform/main.tf's app_required_backends default (#{default}) no longer matches " \
                 "ConnectionBudget.required_backends (#{ConnectionBudget.required_backends}). Terraform is " \
                 "the only thing that checks the app's connection promise against the cluster's plan; if the " \
                 "two disagree it is guarding the wrong number."
  end

  test "database.yml derives every pool rather than hard-coding one" do
    production = as_web { render_database_yml.fetch("production") }
    worker_primary = as_worker { render_database_yml.dig("production", "primary", "pool") }

    # Four pools, four different right answers. A flat number is correct for at most one.
    assert_operator worker_primary, :>, production.dig("primary", "pool")
    assert_operator production.dig("primary", "pool"), :>, production.dig("cable", "pool")
  end

  private

  def render_database_yml
    YAML.safe_load(ERB.new(DATABASE_YML.read).result, aliases: true)
  end
end

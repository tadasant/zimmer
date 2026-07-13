# frozen_string_literal: true

namespace :db do
  desc "Report Zimmer's Postgres connection budget and check the server can serve it"
  task connection_budget: :environment do
    server = ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT
        current_setting('max_connections')::int AS max_connections,
        current_setting('superuser_reserved_connections')::int AS superuser_reserved,
        (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend') AS live_backends
    SQL

    usable = server["max_connections"] - server["superuser_reserved"]
    required = ConnectionBudget.required_backends

    puts "Zimmer connection budget (#{Rails.env})"
    puts "-" * 60
    # Every number below comes from ConnectionBudget, including the env parsing. This task
    # gets run during an incident; a task that raises on a stray empty env var is worse
    # than no task at all.
    puts format("  web process          %3d  (primary %d, cable %d)",
                ConnectionBudget.web_connections, ConnectionBudget.deployed_web_primary_pool,
                ConnectionBudget.cable_pool)
    puts format("  worker process       %3d  (primary %d = goodjob %d + utility %d + overhead %d, cable %d, notifier %d)",
                ConnectionBudget.worker_connections, ConnectionBudget.deployed_worker_primary_pool,
                ConnectionBudget.good_job_scheduler_threads,
                ConnectionBudget::GOOD_JOB_UTILITY_THREADS, ConnectionBudget::PROCESS_OVERHEAD,
                ConnectionBudget.cable_pool, ConnectionBudget::GOOD_JOB_NOTIFIER_CONNECTIONS)
    puts format("  committed (steady)   %3d", ConnectionBudget.committed_connections)
    puts format("  x%d for Kamal cutover %3d", ConnectionBudget::DEPLOY_CUTOVER_MULTIPLIER,
                ConnectionBudget.committed_connections * ConnectionBudget::DEPLOY_CUTOVER_MULTIPLIER)
    puts format("  + operator reserve   %3d", ConnectionBudget::OPERATOR_RESERVE)
    puts format("  REQUIRED BACKENDS    %3d", required)
    puts
    puts format("  server max_connections        %3d", server["max_connections"])
    puts format("  - superuser_reserved          %3d", server["superuser_reserved"])
    puts format("  USABLE BACKENDS              %3d", usable)
    puts format("  live client backends now     %3d", server["live_backends"])
    puts "-" * 60

    if usable >= required
      puts "OK: server can serve the budget (#{usable - required} spare)."
    else
      warn "OVERCOMMITTED: the app commits to #{required} backends; the server serves #{usable}."
      warn "Resize the database, or lower GOOD_JOB_AGENTS_THREADS (see config/connection_budget.rb)."
      abort
    end
  end
end

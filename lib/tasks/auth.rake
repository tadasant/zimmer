# frozen_string_literal: true

namespace :auth do
  desc "Warm every runtime's DB-current login identity to disk (run on worker boot before good_job)"
  task warm_boot: :environment do
    results = AuthWarmupService.new.warm_all

    results.each do |result|
      status =
        if result.ok?
          "ok (#{result.account.email})"
        elsif result.no_account?
          "skipped (no account available)"
        else
          "error (#{result.error})"
        end
      puts "[auth:warm_boot] #{result.runtime}: #{status}"
    end

    # Intentionally never aborts: warm-up is best-effort. The lazy per-session
    # path is the backstop, so a warm-up failure must not stop the worker from
    # starting GoodJob (the boot cmd chains this task with `&& good_job start`).
  end
end

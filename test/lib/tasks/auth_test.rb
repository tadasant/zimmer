# frozen_string_literal: true

require "test_helper"
require "rake"
require "mocha/minitest"

# Tests the auth:warm_boot rake task — the worker-boot entrypoint that warms
# every runtime's login identity to disk before good_job starts. The warm-up
# logic lives in (and is covered by) AuthWarmupServiceTest; here we assert the
# task wires the service in and prints a per-runtime status line.
class AuthTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  teardown do
    Rake::Task.clear
  end

  def run_task
    capture_io do
      Rake::Task["auth:warm_boot"].reenable
      Rake::Task["auth:warm_boot"].invoke
    end.first
  end

  test "invokes AuthWarmupService#warm_all and reports each runtime's status" do
    results = [
      AuthWarmupService::Result.new(runtime: "claude_code", account: claude_accounts(:primary), error: nil),
      AuthWarmupService::Result.new(runtime: "codex", account: nil, error: :no_account)
    ]
    AuthWarmupService.any_instance.expects(:warm_all).returns(results)

    output = run_task

    assert_match(/\[auth:warm_boot\] claude_code: ok \(#{Regexp.escape(claude_accounts(:primary).email)}\)/, output)
    assert_match(/\[auth:warm_boot\] codex: skipped \(no account available\)/, output)
  end

  test "reports an error status without raising when a runtime warm-up failed" do
    boom = RuntimeError.new("token endpoint unreachable")
    results = [
      AuthWarmupService::Result.new(runtime: "claude_code", account: nil, error: boom)
    ]
    AuthWarmupService.any_instance.expects(:warm_all).returns(results)

    output = run_task

    assert_match(/\[auth:warm_boot\] claude_code: error \(token endpoint unreachable\)/, output)
  end
end

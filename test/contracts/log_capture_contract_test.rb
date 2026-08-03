# frozen_string_literal: true

require "test_helper"

# Contract test: no test that can issue an HTTP request may assign Rails.logger.
#
# Rails::Application#env_config memoizes "action_dispatch.logger" => Rails.logger the
# first time anything asks for it, and Rails::Engine#build_request merges that hash
# over every request env. An assignment that is live when a worker takes that memo
# points ActionDispatch::DebugExceptions at a throwaway logger for the rest of the
# process — so later examples watch requests complete and see no ERROR record at all,
# depending on nothing but --seed ordering. That is issue #337.
#
# test_helper.rb takes the memo before parallelize() forks, which closes the hole. This
# test keeps the idiom from coming back, because the second half of the damage survives
# that fix: an assignment still hides from the assigning test every record written
# through a reference Rails hands out elsewhere — DebugExceptions above all, which is
# usually the exact record a logging test exists to assert on.
#
# Capture with LogCaptureHelpers#capture_log_entries instead. Unit tests outside these
# directories never build a request env, so the idiom is inert there and not scanned.
class LogCaptureContractTest < ActiveSupport::TestCase
  REQUEST_ISSUING_TEST_DIRS = %w[
    test/integration
    test/controllers
    test/system
    test/e2e
  ].freeze

  ASSIGNMENT = /^\s*Rails\.logger\s*=[^=]/

  test "no request-issuing test assigns Rails.logger" do
    offenders = REQUEST_ISSUING_TEST_DIRS.flat_map do |dir|
      Dir[Rails.root.join(dir, "**", "*.rb")].filter_map do |path|
        lines = File.readlines(path).each_with_index.select { |line, _index| line.match?(ASSIGNMENT) }
        next if lines.empty?

        relative = Pathname.new(path).relative_path_from(Rails.root)
        lines.map { |_line, index| "#{relative}:#{index + 1}" }
      end
    end.flatten

    assert_empty offenders, <<~MESSAGE
      These tests assign Rails.logger and can issue HTTP requests:

        #{offenders.join("\n  ")}

      Capture with capture_log_entries (test/support/log_capture_helpers.rb), which
      attaches a sink instead. Assigning Rails.logger cannot be seen by
      ActionDispatch::DebugExceptions, so any ERROR-record assertion built on it is
      blind. See issue #337.
    MESSAGE
  end
end

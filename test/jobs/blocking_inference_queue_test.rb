# frozen_string_literal: true

require "test_helper"

# Blocking inference is backpressured by a scheduler lane, not a perform-limit
# rejection. Every excess job therefore exists once and waits for one of the two
# workers instead of repeatedly rescheduling itself with ConcurrencyExceeded.
class BlockingInferenceQueueTest < ActiveSupport::TestCase
  test "every always-blocking inference job uses the inference lane" do
    assert_equal "inference", SessionTitleJob.new(1).queue_name
    assert_equal "inference", SessionStatusSummaryJob.new(1).queue_name
    assert_equal "inference", SessionStatusSummaryJob.new(1, headless: true).queue_name
  end

  test "push notifications use inference only for the shape that calls it" do
    assert_equal "inference", SendPushNotificationJob.new(1, :needs_input).queue_name

    %i[session_complete session_failed custom_message elicitation_pending].each do |type|
      assert_equal "default", SendPushNotificationJob.new(1, type).queue_name,
        "#{type} has a deterministic body and must not wait for inference"
    end
  end

  test "the inference scheduler is separate from default and connection-budgeted" do
    queues = ConnectionBudget.good_job_queue_threads

    assert_operator queues.fetch(:inference), :>=, 1
    assert_operator queues.fetch(:default), :>=, 1
    assert_includes ConnectionBudget.good_job_queues, "inference:#{queues.fetch(:inference)}"
  end

  test "blocking jobs no longer install GoodJob concurrency rejection handlers" do
    error = "GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError"

    [ SessionTitleJob, SessionStatusSummaryJob, SendPushNotificationJob ].each do |job_class|
      handlers = job_class.rescue_handlers.map(&:first)
      assert_equal 1, handlers.count(error),
        "#{job_class} should carry only GoodJob's inherited handler; a job-specific handler recreates the retry storm"
    end
  end

  test "every direct HeadlessInferenceService caller has a queue policy" do
    callers = Dir[Rails.root.join("app/jobs/*.rb")].filter_map do |path|
      next unless File.read(path).include?("HeadlessInferenceService")

      File.basename(path, ".rb").camelize.safe_constantize
    end.compact

    assert_equal [ SendPushNotificationJob, SessionTitleJob ].sort_by(&:name), callers.sort_by(&:name)
    assert_equal "inference", SessionTitleJob.new(1).queue_name
    assert_equal "inference", SendPushNotificationJob.new(1, :needs_input).queue_name
  end
end

require "test_helper"

module Supervisor
  class LogsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @log = logs(:info_log)
    end

    test "should get index" do
      get supervisor_logs_url
      assert_response :success
      assert_select "h1", "Logs"
    end

    test "should show log" do
      get supervisor_log_url(@log)
      assert_response :success
    end

    test "should get new" do
      get new_supervisor_log_url
      assert_response :success
    end

    test "should get edit" do
      get edit_supervisor_log_url(@log)
      assert_response :success
    end

    test "should update log" do
      patch supervisor_log_url(@log), params: {
        log: {
          content: "Updated content",
          level: @log.level
        }
      }
      assert_redirected_to supervisor_log_url(@log)
    end

    test "should destroy log" do
      assert_difference("Log.count", -1) do
        delete supervisor_log_url(@log)
      end
      assert_redirected_to supervisor_logs_url
    end
  end
end

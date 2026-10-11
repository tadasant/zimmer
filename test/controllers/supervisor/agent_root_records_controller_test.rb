require "test_helper"

module Supervisor
  class AgentRootRecordsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @record = AgentRootRecord.create!(namespace: "zimmer", collection: "notes", key: "pr-1",
                                        data: { "title" => "remember-this" }, data_bytes: 25)
      @counter = AgentRootRecordCounter.create!(namespace: "zimmer", collection: "notes", records_count: 1, data_bytes: 25)
    end

    test "lists and shows records" do
      get supervisor_agent_root_records_url
      assert_response :success
      assert_match "pr-1", response.body

      get supervisor_agent_root_record_url(@record)
      assert_response :success
      assert_match "remember-this", response.body
    end

    test "lists and shows counters" do
      get supervisor_agent_root_record_counters_url
      assert_response :success
      assert_match "notes", response.body

      get supervisor_agent_root_record_counter_url(@counter)
      assert_response :success
    end

    # Every write goes through RootData::Store, which holds the caps and the
    # counters; the panels offer no form and no Delete.
    test "both panels are read-only" do
      %w[supervisor/agent_root_records supervisor/agent_root_record_counters].each do |controller|
        actions = Rails.application.routes.routes
          .select { |route| route.defaults[:controller] == controller }
          .map { |route| route.defaults[:action] }
        assert_equal %w[index show], actions.sort, controller
      end
      assert_empty AgentRootRecordDashboard::FORM_ATTRIBUTES
      assert_empty AgentRootRecordCounterDashboard::FORM_ATTRIBUTES
    end
  end
end

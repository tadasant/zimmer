# frozen_string_literal: true

require "test_helper"

module Supervisor
  class XOauthPendingFlowsControllerTest < ActionDispatch::IntegrationTest
    include SupervisorAuthTestHelper
    include SupervisorAuthTestHelper::AutoBasicAuth

    setup do
      @flow = XOauthPendingFlow.start!(account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN")
    end

    test "lists and shows a consent in progress without its verifier" do
      get supervisor_x_oauth_pending_flows_path
      assert_response :success
      assert_match "tadasayy", response.body

      get supervisor_x_oauth_pending_flow_path(@flow)
      assert_response :success
      assert_match @flow.state, response.body
      assert_no_match @flow.code_verifier, response.body
    end

    test "destroying a flow cancels it" do
      delete supervisor_x_oauth_pending_flow_path(@flow)

      assert_not XOauthPendingFlow.exists?(@flow.id)
    end

    test "flows cannot be hand-written" do
      actions = Rails.application.routes.routes
        .select { |route| route.defaults[:controller] == "supervisor/x_oauth_pending_flows" }
        .map { |route| route.defaults[:action] }

      assert_equal %w[destroy index show], actions.sort
      assert_empty XOauthPendingFlowDashboard::FORM_ATTRIBUTES
    end
  end
end

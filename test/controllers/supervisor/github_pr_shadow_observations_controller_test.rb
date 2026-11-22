require "test_helper"

module Supervisor
  class GithubPrShadowObservationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @row = GithubPrShadowObservation.record!(
        session_id: sessions(:running).id, pr_url: "https://github.com/tadasant/zimmer/pull/7",
        kind: "comments", mode: "webhook_shadow", signaled_at: 1.minute.ago
      )
    end

    test "index and show render the observation" do
      get supervisor_github_pr_shadow_observations_url
      assert_response :success
      assert_match "https://github.com/tadasant/zimmer/pull/7", response.body

      get supervisor_github_pr_shadow_observation_url(@row)
      assert_response :success
      assert_match "webhook_shadow", response.body
    end

    test "the panel is read-only" do
      actions = Rails.application.routes.routes
        .select { |route| route.defaults[:controller] == "supervisor/github_pr_shadow_observations" }
        .map { |route| route.defaults[:action] }

      assert_equal %w[index show], actions.sort
    end
  end
end

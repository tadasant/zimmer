require "test_helper"

class ApplicationControllerTest < ActionDispatch::IntegrationTest
  test "no authentication required" do
    get root_url
    assert_response :success
  end

  test "handles 404 errors gracefully" do
    get "/sessions/nonexistent-id-12345"
    assert_response :not_found
  end
end

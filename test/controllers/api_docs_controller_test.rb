# frozen_string_literal: true

require "test_helper"

class ApiDocsControllerTest < ActionDispatch::IntegrationTest
  test "should get show" do
    get api_docs_url
    assert_response :success
  end

  test "should render page with correct title" do
    get api_docs_url
    assert_select "h1", "API Documentation"
  end

  test "should have back link to sessions index" do
    get api_docs_url
    assert_select "a[href=?]", root_path
  end

  test "should have sessions section" do
    get api_docs_url
    assert_select "h2", "Sessions"
  end

  test "should have logs section" do
    get api_docs_url
    assert_select "h2", "Logs"
  end

  test "should have subagent transcripts section" do
    get api_docs_url
    assert_select "h2", "Subagent Transcripts"
  end

  test "should have configuration section" do
    get api_docs_url
    assert_select "h2", "Configuration"
  end

  test "should have SDK examples section" do
    get api_docs_url
    assert_select "h2", "SDK Examples"
  end

  test "should have overview section with authentication info" do
    get api_docs_url
    assert_select "h2", "Overview"
    assert_select "code", /X-API-Key/
  end

  test "should route GET /api_docs to api_docs#show" do
    assert_routing(
      { method: :get, path: "/api_docs" },
      { controller: "api_docs", action: "show" }
    )
  end
end

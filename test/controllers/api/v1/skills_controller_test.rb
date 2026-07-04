# frozen_string_literal: true

require "test_helper"

class Api::V1::SkillsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_skills_path
    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "Unauthorized", json["error"]
  end

  test "should return 401 with invalid API key" do
    get api_v1_skills_path, headers: { "X-API-Key" => "invalid_key" }
    assert_response :unauthorized
  end

  test "should accept valid API key" do
    get api_v1_skills_path, headers: @headers
    assert_response :success
  end

  # Response format tests
  test "should return JSON with correct content type" do
    get api_v1_skills_path, headers: @headers
    assert_response :success
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "should return skills array" do
    get api_v1_skills_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("skills")
    assert json["skills"].is_a?(Array)
  end

  test "should return skill objects with expected fields" do
    get api_v1_skills_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)

    assert json["skills"].any?, "Expected at least one skill in config"

    json["skills"].each do |skill|
      assert skill.key?("id"), "Skill should have id field"
      assert skill.key?("name"), "Skill should have name field"
      assert skill.key?("title"), "Skill should have title field"
      assert skill.key?("description"), "Skill should have description field"
      assert skill.key?("category"), "Skill should have category field"

      # Should NOT have sensitive/large fields
      assert_not skill.key?("files"), "Skill should NOT expose files field"
      assert_not skill.key?("content"), "Skill should NOT expose content field"
    end
  end

  test "should return skills from SkillsConfig" do
    get api_v1_skills_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    skill_names = json["skills"].map { |s| s["name"] }

    # Verify it matches the SkillsConfig catalog
    config_names = SkillsConfig.names
    assert_equal config_names.sort, skill_names.sort
  end
end

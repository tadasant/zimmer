require "test_helper"

class GoalsConfigTest < ActiveSupport::TestCase
  # Test loading goals
  test "should load all goals from config" do
    goals = GoalsConfig.all
    assert goals.is_a?(Array)
    assert goals.all? { |g| g.is_a?(GoalsConfig::Goal) }
  end

  test "should have expected goals from config" do
    goal_ids = GoalsConfig.ids

    # These are the goals defined in config/goals.json
    assert_includes goal_ids, "codebase-question"
    assert_includes goal_ids, "open-reviewed-green-pr"
    assert_includes goal_ids, "open-reviewed-green-pr-with-version-bump"
    assert_includes goal_ids, "e2e-verified-green-pr"
    assert_equal 4, goal_ids.size
  end

  # Test finding goals
  test "should find goal by id" do
    goal = GoalsConfig.find("open-reviewed-green-pr")
    assert_not_nil goal
    assert_equal "open-reviewed-green-pr", goal.id
  end

  test "should return nil for non-existent goal" do
    goal = GoalsConfig.find("nonexistent")
    assert_nil goal
  end

  test "should raise error with find! for non-existent goal" do
    assert_raises(GoalsConfig::GoalNotFoundError) do
      GoalsConfig.find!("nonexistent")
    end
  end

  test "should include goal id in error message" do
    error = assert_raises(GoalsConfig::GoalNotFoundError) do
      GoalsConfig.find!("missing_goal")
    end
    assert_includes error.message, "missing_goal"
  end

  # Test goal existence
  test "should return true for existing goal" do
    assert GoalsConfig.exists?("open-reviewed-green-pr")
  end

  test "should return false for non-existent goal" do
    assert_not GoalsConfig.exists?("nonexistent")
  end

  # Test goal ids
  test "should return array of goal ids" do
    ids = GoalsConfig.ids
    assert ids.is_a?(Array)
    assert ids.all? { |id| id.is_a?(String) }
  end

  # Test reload functionality
  test "should reload configuration" do
    initial_goals = GoalsConfig.all
    reloaded_goals = GoalsConfig.reload!
    assert_equal initial_goals.map(&:id), reloaded_goals.map(&:id)
  end

  # Test Goal object
  test "goal should have id attribute" do
    goal = GoalsConfig.find("open-reviewed-green-pr")
    assert_equal "open-reviewed-green-pr", goal.id
  end

  test "goal should have name attribute" do
    goal = GoalsConfig.find("open-reviewed-green-pr")
    assert_equal "Open Reviewed Green PR", goal.name
  end

  test "goal should have description attribute" do
    goal = GoalsConfig.find("open-reviewed-green-pr")
    assert_not_nil goal.description
    assert goal.description.is_a?(String)
  end

  # Test to_h method
  test "goal should convert to hash" do
    goal = GoalsConfig.find("open-reviewed-green-pr")
    hash = goal.to_h

    assert hash.is_a?(Hash)
    assert_equal "open-reviewed-green-pr", hash[:id]
    assert_equal "Open Reviewed Green PR", hash[:name]
    assert hash.key?(:description)
  end

  # Test to_json method
  test "goal should convert to json" do
    goal = GoalsConfig.find("open-reviewed-green-pr")
    json = goal.to_json

    assert json.is_a?(String)
    parsed = JSON.parse(json)
    assert_equal "open-reviewed-green-pr", parsed["id"]
  end

  # Test description quality - no stub descriptions that just echo the name
  test "every goal should have an actionable description distinct from its name" do
    GoalsConfig.all.each do |goal|
      assert goal.description.present?,
        "Goal '#{goal.id}' has a blank description"
      assert goal.description != goal.name,
        "Goal '#{goal.id}' has a stub description that just echoes its name '#{goal.name}'"
      assert goal.description.length > goal.name.length + 20,
        "Goal '#{goal.id}' description is too short to be actionable (#{goal.description.length} chars)"
    end
  end

  # Test raw config access
  test "should access raw config" do
    config = GoalsConfig.config
    assert config.is_a?(Hash)
    assert config.key?("goals")
  end

  # Test error handling
  test "should have ConfigurationError exception class" do
    assert_kind_of Class, GoalsConfig::ConfigurationError
    assert GoalsConfig::ConfigurationError < StandardError
  end

  test "should have GoalNotFoundError exception class" do
    assert_kind_of Class, GoalsConfig::GoalNotFoundError
    assert GoalsConfig::GoalNotFoundError < StandardError
  end
end

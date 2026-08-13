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

  # The goal text is what actually steers a session's lifecycle -- it is far more
  # proximate than the general principle in OrchestratorSystemPromptBuilder, so a
  # goal that says "do not archive yourself" wins over a prompt that says the
  # opposite. These pin the resolution: PR goals end in self-archival, and
  # codebase-question is the single goal allowed to say otherwise.
  PR_GOAL_IDS = %w[
    open-reviewed-green-pr
    open-reviewed-green-pr-with-version-bump
    e2e-verified-green-pr
  ].freeze

  test "PR goals instruct the session to archive itself" do
    PR_GOAL_IDS.each do |id|
      description = GoalsConfig.find(id).description

      assert_includes description, "archive yourself",
        "Goal '#{id}' must tell the session to self-archive once the PR is green, reviewed and labeled"
      assert_includes description, "Do NOT park this session as a stand-in todo item for an unreviewed PR",
        "Goal '#{id}' must reject the stale 'an open PR is the user's todo list' rationale"
    end
  end

  test "no goal reinstates the todo-list parking rationale" do
    GoalsConfig.all.each do |goal|
      refute_match(/todo-list/i, goal.description,
        "Goal '#{goal.id}' revives the 'open PRs are a visible todo-list' rationale")
      refute_includes goal.description, "STOP and wait in needs_input state",
        "Goal '#{goal.id}' parks unconditionally instead of archiving on completion"
    end
  end

  test "codebase-question is the only goal that tells a session not to archive" do
    keeping_the_session_open = GoalsConfig.all.select do |goal|
      goal.description.include?("do NOT archive yourself") ||
        goal.description.include?("Do NOT archive yourself")
    end

    assert_equal [ "codebase-question" ], keeping_the_session_open.map(&:id),
      "Only a human-asked question is a sanctioned reason to stay in needs_input by default"
  end

  test "codebase-question tells a router-spawned session to report back and archive" do
    description = GoalsConfig.find("codebase-question").description

    assert_includes description, "If a human invoked this session directly"
    assert_includes description, "report your answer back to that parent and archive yourself",
      "A research session spawned by a parent has no human waiting on it, so it must not park"
  end
end

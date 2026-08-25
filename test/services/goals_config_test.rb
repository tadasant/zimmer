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
  # goal that contradicts the prompt wins. These pin the resolution: a PR session
  # holds the work while its PR's disposition is unsettled, and the merge message --
  # not a human -- is what tells it to archive.
  PR_GOAL_IDS = %w[
    open-reviewed-green-pr
    open-reviewed-green-pr-with-version-bump
    e2e-verified-green-pr
  ].freeze

  test "PR goals hold the session until the PR merges, then archive on the merge message" do
    PR_GOAL_IDS.each do |id|
      description = GoalsConfig.find(id).description

      assert_includes description, "do NOT archive yourself yet, and do NOT merge the PR",
        "Goal '#{id}' must hold the session while the PR's merge disposition is unsettled"
      assert_includes description, "Zimmer never recorded a PR URL for this session",
        "Goal '#{id}' must give the session an exit when no merge message can ever reach it"
      assert_includes description, "THAT MESSAGE IS YOUR SIGNAL TO ARCHIVE",
        "Goal '#{id}' must name the merge notification as the archive trigger"
      assert_includes description, "archive yourself immediately rather than waiting to be told twice",
        "Goal '#{id}' must not leave the session waiting for a human after its PR merged"
      assert_includes description, "a merge gate holds the PR for human review",
        "Goal '#{id}' must say that a held PR is the sanctioned reason to stay put"
    end
  end

  # The `open-pr` skill's terminal step sleeps the session on an unrated PR instead of
  # parking it in the action queue -- a PR waiting to be rated is a machine wait, a PR
  # the gate held is a human handoff. Both texts are injected into the same prompt, so
  # a goal that flatly ordered "stop in needs_input" would read as a contradiction and
  # the session would park anyway. These pin the deferral and its fallback.
  test "PR goals defer the resting decision to the open-pr skill's terminal steps" do
    PR_GOAL_IDS.each do |id|
      description = GoalsConfig.find(id).description

      refute_includes description, "stop in needs_input",
        "Goal '#{id}' orders an unconditional park, contradicting the open-pr skill's self-wake"
      assert_includes description, "follow the `open-pr` skill's terminal steps",
        "Goal '#{id}' must send the session to the skill for how to come to rest"
      assert_includes description, "bounded self-wake",
        "Goal '#{id}' must name the self-wake so a session without the skill loaded still knows the shape"
      assert_includes description, "If the `open-pr` skill is not available to you",
        "Goal '#{id}' must leave a runtime or repo without the skill an instruction of its own"
    end
  end

  # The stop is conditional, and the condition has to be the merge message rather than
  # a person's attention. A goal making a human the only thing able to release a session
  # is what leaves sessions in needs_input for weeks after their PR has landed.
  test "no goal makes archiving conditional on the user's say-so" do
    GoalsConfig.all.each do |goal|
      refute_match(/todo-list/i, goal.description,
        "Goal '#{goal.id}' revives the 'open PRs are a visible todo-list' rationale")
      refute_includes goal.description, "Only the user (or an explicit follow-up message) should trigger archiving",
        "Goal '#{goal.id}' makes a human the only archive trigger, which strands the session after its PR merges"
      refute_includes goal.description, "STOP and wait in needs_input state",
        "Goal '#{goal.id}' parks unconditionally, with no stated condition for archiving"
    end
  end

  test "codebase-question is the only goal that parks without naming an exit" do
    parking_for_a_human = GoalsConfig.all.reject do |goal|
      goal.description.include?("THAT MESSAGE IS YOUR SIGNAL TO ARCHIVE")
    end.select do |goal|
      goal.description.match?(/do NOT archive yourself/i)
    end

    assert_equal [ "codebase-question" ], parking_for_a_human.map(&:id),
      "Only a human-asked question parks with no machine signal to release it"
  end

  test "codebase-question tells a router-spawned session to report back and archive" do
    description = GoalsConfig.find("codebase-question").description

    assert_includes description, "If a human invoked this session directly"
    assert_includes description, "report your answer back to that parent and archive yourself",
      "A research session spawned by a parent has no human waiting on it, so it must not park"
  end
end

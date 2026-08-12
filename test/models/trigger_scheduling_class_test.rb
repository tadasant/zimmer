# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

# The spot/priority selector on a Trigger, and what it stamps on the sessions the
# trigger spawns.
class TriggerSchedulingClassTest < ActiveSupport::TestCase
  setup do
    @slack = triggers(:enabled_slack_trigger)
    @schedule = triggers(:enabled_schedule_trigger)
    ServersConfig.stubs(:exists?).returns(true)
    SkillsConfig.stubs(:exists?).returns(true)
    HooksConfig.stubs(:exists?).returns(true)
    PluginsConfig.stubs(:exists?).returns(true)
    AgentRootsConfig.stubs(:exists?).returns(true)
  end

  def stub_agent_root_for(trigger)
    root = OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:find!).with(trigger.agent_root_name).returns(root)
    AgentSessionJob.stubs(:enqueue_new_session)
    root
  end

  # --- the selector -----------------------------------------------------------

  test "a trigger stores no class by default" do
    assert_nil @slack.scheduling_class
  end

  test "the default class follows the condition type" do
    assert_equal SessionGenesis::PRIORITY, @slack.default_scheduling_class,
      "a human is waiting on the other end of a Slack trigger"
    assert_equal SessionGenesis::SPOT, @schedule.default_scheduling_class,
      "recurring automation runs again, so a deferred run costs little"
  end

  test "effective_scheduling_class prefers the stored choice" do
    assert_equal SessionGenesis::PRIORITY, @slack.effective_scheduling_class

    @slack.update!(scheduling_class: SessionGenesis::SPOT)
    assert_equal SessionGenesis::SPOT, @slack.effective_scheduling_class
  end

  test "a blank selection is stored as NULL rather than an empty class" do
    @slack.update!(scheduling_class: "")
    assert_nil @slack.reload.scheduling_class
  end

  test "an unknown class is rejected" do
    @slack.scheduling_class = "whenever"
    refute @slack.valid?
    assert @slack.errors[:scheduling_class].any?
  end

  # --- what it stamps ---------------------------------------------------------

  test "a trigger with no selector stamps nothing, so the session derives" do
    stub_agent_root_for(@slack)

    session = @slack.create_session!(prompt: "Test")

    assert_nil session.scheduling_class,
      "leaving the column NULL is what keeps a later change to the shipped default reaching it"
    assert_equal SessionGenesis::SLACK, session.genesis
    assert session.priority?
  end

  test "a trigger with a selector stamps it on the session" do
    @slack.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@slack)

    session = @slack.create_session!(prompt: "Test")

    assert_equal SessionGenesis::SPOT, session.scheduling_class
    assert session.spot?
    assert_equal SessionGenesis::SLACK, session.genesis,
      "the class moved; where the work came from did not"
  end

  test "one trigger's selector does not move another trigger of the same genesis" do
    # This is the whole point of moving the selector off the genesis kind: the old
    # per-kind lever would have demoted every Slack trigger at once.
    noisy = @slack
    noisy.update!(scheduling_class: SessionGenesis::SPOT)
    other = triggers(:bot_mention_slack_trigger)

    assert_equal SessionGenesis::SPOT, noisy.effective_scheduling_class
    assert_equal SessionGenesis::PRIORITY, other.effective_scheduling_class
  end

  test "the Invoke button's genesis override wins over the trigger's selector" do
    # A human pressed Invoke and is waiting. That is a different origin from the
    # one the selector describes, so the session takes web_ui's class instead.
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)

    session = @schedule.create_session!(prompt: "Test", genesis: SessionGenesis::WEB_UI)

    assert_equal SessionGenesis::WEB_UI, session.genesis
    assert_nil session.scheduling_class
    assert session.priority?
  end

  test "changing the selector does not move sessions the trigger already spawned" do
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)
    already_spawned = @schedule.create_session!(prompt: "Test")
    assert already_spawned.spot?

    @schedule.update!(scheduling_class: SessionGenesis::PRIORITY)

    assert_equal SessionGenesis::SPOT, already_spawned.reload.scheduling_class,
      "the selector is read once, when the trigger fires — the documented contract"
    assert already_spawned.spot?
  end
end

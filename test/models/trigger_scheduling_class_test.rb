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

  # --- the predefined rank ----------------------------------------------------

  test "a trigger predefines no rank by default" do
    assert_nil @slack.precedence
  end

  test "a blank rank is stored as NULL rather than zero" do
    @slack.update!(precedence: "")

    assert_nil @slack.reload.precedence, "an empty form field predefines nothing"
  end

  test "a trigger with no rank leaves the session on the default" do
    stub_agent_root_for(@slack)

    assert_equal SessionPrecedence::DEFAULT, @slack.create_session!(prompt: "Test").precedence
  end

  test "a trigger with a rank stamps it on the sessions it spawns" do
    @slack.update!(scheduling_class: SessionGenesis::SPOT, precedence: 8_000)
    stub_agent_root_for(@slack)

    assert_equal 8_000, @slack.create_session!(prompt: "Test").precedence
  end

  # The class is withheld from an Invoke because a human pressing the button is a
  # different ORIGIN. The rank is not: it describes how this work ranks against
  # everything else queued, which is as true of a hand-fired run.
  test "the rank still applies when a human invokes the trigger" do
    @slack.update!(precedence: 321)
    stub_agent_root_for(@slack)

    session = @slack.create_session!(prompt: "Test", genesis: SessionGenesis::WEB_UI)

    assert_equal 321, session.precedence
    assert_nil session.scheduling_class, "the class is still the Invoke's, not the trigger's"
  end

  test "a rank beyond the accepted range is rejected" do
    @slack.precedence = SessionPrecedence::MAX + 1

    assert_not @slack.valid?
    assert_includes @slack.errors.full_messages.join, "Precedence"
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

  test "a burst-notice session carries the trigger's class" do
    @schedule.update!(scheduling_class: SessionGenesis::PRIORITY, max_sessions_per_minute: 1)
    stub_agent_root_for(@schedule)

    @schedule.create_session!(prompt: "First")
    notice = @schedule.create_session!(prompt: "Second — tips the cap")

    assert notice.metadata["burst_notice"], "the second fire should have produced the burst notice"
    assert_equal SessionGenesis::PRIORITY, notice.scheduling_class
  end

  # --- what a change to the selector reaches (#480) ---------------------------

  test "changing the selector moves the trigger's already-spawned waiting sessions" do
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)
    already_spawned = @schedule.create_session!(prompt: "Test")
    assert already_spawned.waiting?
    assert already_spawned.spot?

    @schedule.update!(scheduling_class: SessionGenesis::PRIORITY)

    assert_equal SessionGenesis::PRIORITY, already_spawned.reload.scheduling_class,
      "an operator flipping a trigger to priority during a backlog means the backlog"
    assert already_spawned.priority?
    assert_equal 1, @schedule.reclassified_session_count
    assert_equal "1 already-spawned waiting session moved to priority.", @schedule.reclassification_summary
  end

  test "a demotion moves them the other way too" do
    @schedule.update!(scheduling_class: SessionGenesis::PRIORITY)
    stub_agent_root_for(@schedule)
    already_spawned = @schedule.create_session!(prompt: "Test")
    assert already_spawned.priority?

    @schedule.update!(scheduling_class: SessionGenesis::SPOT)

    assert already_spawned.reload.spot?
    assert_equal 1, @schedule.reclassified_session_count
  end

  test "clearing the selector returns already-spawned waiting sessions to deriving" do
    @slack.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@slack)
    already_spawned = @slack.create_session!(prompt: "Test")
    assert_equal SessionGenesis::SPOT, already_spawned.scheduling_class

    @slack.update!(scheduling_class: "")

    assert_nil already_spawned.reload.scheduling_class,
      "the stamp follows the trigger's, including back to 'derive it'"
    assert already_spawned.priority?, "a slack session derives priority"
    assert_equal 1, @slack.reclassified_session_count
  end

  test "the reclassification is scoped to THIS trigger, not the genesis it shares" do
    # The blast radius of the one-click workaround is the whole point of #480:
    # `promote_genesis` sweeps every session of a kind, and five of the eight
    # kinds restate a condition type. A sibling trigger's work is not this
    # operator's to promote.
    other = Trigger.create!(
      name: "Another scheduled trigger",
      agent_root_name: @schedule.agent_root_name,
      prompt_template: "Test",
      status: "enabled",
      scheduling_class: SessionGenesis::SPOT,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "interval" => 2, "unit" => "hours" } }
      ]
    )
    stub_agent_root_for(other)
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)

    sibling = other.create_session!(prompt: "Sibling work")
    mine = @schedule.create_session!(prompt: "My work")
    assert_equal sibling.genesis, mine.genesis, "both derive the same genesis — that is the trap"

    @schedule.update!(scheduling_class: SessionGenesis::PRIORITY)

    assert mine.reload.priority?
    assert_equal SessionGenesis::SPOT, sibling.reload.scheduling_class,
      "a sibling trigger's session is not this operator's to promote"
    assert_equal 1, @schedule.reclassified_session_count
  end

  test "a session that has already started keeps the class it ran with" do
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)
    started = @schedule.create_session!(prompt: "Test")
    started.update_column(:status, "running")

    @schedule.update!(scheduling_class: SessionGenesis::PRIORITY)

    assert_equal SessionGenesis::SPOT, started.reload.scheduling_class,
      "it is past the gate this setting governs"
    assert_equal 0, @schedule.reclassified_session_count
    assert_equal "No already-spawned waiting sessions needed moving.", @schedule.reclassification_summary
  end

  test "a hand-fired Invoke session is not reclassified" do
    # The selector is withheld from an Invoke on purpose — a human pressed the
    # button and the session takes web_ui's class. A later change to the selector
    # must not reach it either, even though it carries this trigger's id.
    stub_agent_root_for(@schedule)
    invoked = @schedule.create_session!(prompt: "Test", genesis: SessionGenesis::WEB_UI)
    assert_nil invoked.scheduling_class
    assert invoked.priority?

    @schedule.update!(scheduling_class: SessionGenesis::SPOT)

    assert_nil invoked.reload.scheduling_class, "the selector never applied to it"
    assert invoked.priority?
    assert_equal 0, @schedule.reclassified_session_count
  end

  test "a session that is not waiting is left alone whatever its status" do
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)
    parked = @schedule.create_session!(prompt: "Test")
    parked.update_column(:status, "needs_input")

    @schedule.update!(scheduling_class: SessionGenesis::PRIORITY)

    assert_equal SessionGenesis::SPOT, parked.reload.scheduling_class
    assert_equal 0, @schedule.reclassified_session_count
  end

  test "a whole backlog moves in one change, not just the first session" do
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)
    backlog = 3.times.map { |i| @schedule.create_session!(prompt: "Held work #{i}") }

    @schedule.update!(scheduling_class: SessionGenesis::PRIORITY)

    backlog.each { |session| assert session.reload.priority?, "session #{session.id} should have moved" }
    assert_equal 3, @schedule.reclassified_session_count
    assert_equal "3 already-spawned waiting sessions moved to priority.", @schedule.reclassification_summary
  end

  test "a session an operator already moved by hand stays where they put it" do
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)
    moved_by_hand = @schedule.create_session!(prompt: "Test")
    moved_by_hand.update!(scheduling_class: SessionGenesis::PRIORITY)

    @schedule.update!(scheduling_class: "")

    assert_equal SessionGenesis::PRIORITY, moved_by_hand.reload.scheduling_class,
      "a per-session choice outranks a trigger-wide one"
    assert_equal 0, @schedule.reclassified_session_count
  end

  test "a reclassified session records why its class changed" do
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)
    session = @schedule.create_session!(prompt: "Test")

    @schedule.update!(scheduling_class: SessionGenesis::PRIORITY)

    log = session.logs.reload.find { |l| l.content.include?("Scheduling class set to priority") }
    assert log, "the session should say why its class moved"
    assert_includes log.content, @schedule.name
  end

  test "a save that leaves the class alone reports nothing" do
    @schedule.update!(scheduling_class: SessionGenesis::SPOT)
    stub_agent_root_for(@schedule)
    session = @schedule.create_session!(prompt: "Test")

    @schedule.update!(name: "Renamed")

    assert_nil @schedule.reclassified_session_count
    assert_nil @schedule.reclassification_summary
    assert_equal SessionGenesis::SPOT, session.reload.scheduling_class
  end

  test "a rewrite that resolves to the same class is not counted as a move" do
    # The schedule trigger's condition type already derives spot, so naming it
    # explicitly moves nothing. Saying "1 session reclassified" would overstate
    # what the click did.
    stub_agent_root_for(@schedule)
    session = @schedule.create_session!(prompt: "Test")
    assert_nil session.scheduling_class
    assert session.spot?

    @schedule.update!(scheduling_class: SessionGenesis::SPOT)

    assert_equal SessionGenesis::SPOT, session.reload.scheduling_class, "the stamp still follows the trigger's"
    assert session.spot?
    assert_equal 0, @schedule.reclassified_session_count
    assert session.logs.reload.any? { |l| l.content.include?("which it already resolved to") },
      "a write with no record of it is what makes a class look self-inflicted"
  end
end

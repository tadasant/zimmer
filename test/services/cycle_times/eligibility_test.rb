# frozen_string_literal: true

require "test_helper"

class CycleTimes::EligibilityTest < ActiveSupport::TestCase
  include CycleTimeFixtures

  T0 = Time.utc(2026, 11, 10, 8)
  AGENT = "session #SELF via the self-session MCP server"

  setup do
    @user = User.first || User.create!(key: "tester", display_name: "Tester", email: nil)
  end

  def root_and_child(root_actor: AGENT, child_actor: AGENT, child_extra: [])
    root = build_cycle_time_session(created_at: T0, title: "Root",
                                    script: simple_turn(T0 + 5) + [ [ :archive, T0 + 600, root_actor ] ])
    child = build_cycle_time_session(created_at: T0 + 30, title: "Child", parent: root,
                                     script: simple_turn(T0 + 40) + child_extra + [ [ :archive, T0 + 500, child_actor ] ])
    [ root, child ]
  end

  def evaluate(root)
    hierarchy = CycleTimes::Hierarchy.new(root)
    logs = Log.where(session_id: hierarchy.ids).order(:created_at).group_by(&:session_id)
    changes = logs.transform_values { |rows| CycleTimes::StateLog.parse(rows) }
    CycleTimes::Eligibility.new(hierarchy, changes_by_session: changes,
                                human_messages: HumanMessage.where(session_id: hierarchy.ids).to_a).call
  end

  def human_message(session, at)
    HumanMessage.create!(session: session, author: @user.key, channel: "web_ui", content: "hi", occurred_at: at)
  end

  test "agent archives and only an initiating human prompt qualify, initiated by a human" do
    root, = root_and_child
    human_message(root, T0 + 1)

    result = evaluate(root)

    assert result.eligible, result.detail
    assert_equal "human", result.initiator
  end

  test "a trigger-created root with no human message qualifies as trigger-initiated" do
    trigger = Trigger.create!(name: "Nightly sweep", agent_root_name: "general-agent", prompt_template: "go") rescue nil
    root, = root_and_child
    root.update_columns(metadata: { "trigger_id" => trigger&.id || 123 })

    result = evaluate(root)

    assert result.eligible
    assert_equal "trigger", result.initiator
  end

  test "a human follow-up anywhere in the hierarchy disqualifies it" do
    root, child = root_and_child
    human_message(root, T0 + 1)
    human_message(child, T0 + 200)

    result = evaluate(root)

    refute result.eligible
    assert_equal "human_follow_up", result.reason
  end

  test "a human message on the root after the first turn's grace is a follow-up" do
    root, = root_and_child
    human_message(root, T0 + 5 + CycleTimes::Eligibility::INITIATION_GRACE + 1)

    assert_equal "human_follow_up", evaluate(root).reason
  end

  test "a human-archived leaf disqualifies the hierarchy" do
    root, = root_and_child(child_actor: "a user in the web UI")

    assert_equal "human_archive", evaluate(root).reason
  end

  test "a sweep archive and an unrecorded archive disqualify it" do
    root, = root_and_child(child_actor: "Zimmer's stale-session sweep (untouched for 7 days)")
    assert_equal "system_archive", evaluate(root).reason

    other, = root_and_child(root_actor: "an unrecorded caller")
    assert_equal "unrecorded_archive", evaluate(other).reason
  end

  test "a session restored from the trash disqualifies it" do
    root, = root_and_child(child_extra: [ [ :state, T0 + 300, "Session restored from trash to waiting" ] ])

    assert_equal "reopened", evaluate(root).reason
  end

  test "an uncle's follow-up is agent input and does not join or disqualify the hierarchy" do
    root, child = root_and_child
    uncle = build_cycle_time_session(created_at: T0 - 100, title: "Uncle", script: [ [ :archive, T0 + 700, AGENT ] ])
    SessionUncleLink.create!(session: child, uncle_session: uncle, source: "follow_up")

    result = evaluate(root)

    assert result.eligible
    assert_equal [ root.id, child.id ].sort, CycleTimes::Hierarchy.new(root).ids.sort
  end

  test "the root walk finds the top of the spawn chain" do
    root, child = root_and_child
    grandchild = build_cycle_time_session(created_at: T0 + 60, title: "Grandchild", parent: child,
                                          script: [ [ :archive, T0 + 400, AGENT ] ])

    assert_equal root.id, CycleTimes::Hierarchy.root_for(grandchild).id
    assert_equal 2, CycleTimes::Hierarchy.new(root).depths[grandchild.id]
  end

  test "an archive by a session outside the hierarchy disqualifies it; one by its own router does not" do
    root, child = root_and_child(child_actor: "session #ROOT via the MCP API")
    # The fixture only knows its own id, so point the child's archive at its router after the fact.
    Log.where(session_id: child.id).where("content LIKE ?", "%ROOT%")
       .update_all([ "content = REPLACE(content, '#ROOT', ?)", "##{root.id}" ])
    assert evaluate(root).eligible

    other, = root_and_child(root_actor: "session #8657 via the MCP API")
    result = evaluate(other)
    refute result.eligible
    assert_equal "outside_archive", result.reason
    assert_match "#8657", result.detail
  end

  test "a missed wake longer than the limit disqualifies; a shorter one does not" do
    missed = ->(seconds) { CycleTimes::LaneBuilder::MissedWake.new(T0, T0 + seconds) }

    assert_nil CycleTimes::Eligibility.missed_wake({ 1 => [ missed.call(20.minutes) ], 2 => [] })

    reason, detail = CycleTimes::Eligibility.missed_wake({ 1 => [], 7 => [ missed.call(75.days) ] })
    assert_equal "missed_wake", reason
    assert_match "session #7", detail
  end
end

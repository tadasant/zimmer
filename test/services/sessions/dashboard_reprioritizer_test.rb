# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Reprioritize button's session: ONE durable session reused across presses,
# through the same trigger machinery a wake-up or a recurring Slack trigger uses.
class Sessions::DashboardReprioritizerTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Trigger.where(name: Sessions::DashboardReprioritizer::TRIGGER_NAME).destroy_all
  end

  test "the trigger is seeded on first use and found thereafter" do
    first = Sessions::DashboardReprioritizer.trigger!
    second = Sessions::DashboardReprioritizer.trigger!

    assert_equal first.id, second.id
    assert_equal 1, Trigger.where(name: Sessions::DashboardReprioritizer::TRIGGER_NAME).count
  end

  # Every automatic firing path filters on `status: "enabled"`, and this trigger
  # must only ever fire from the button.
  test "the seeded trigger is disabled so nothing fires it on a schedule" do
    trigger = Sessions::DashboardReprioritizer.trigger!

    assert_equal "disabled", trigger.status
    assert_not trigger.enabled?
  end

  # A trigger whose every condition is a ONE-TIME schedule is a
  # `one_time_reuse_trigger?`, which changes what happens when the target session
  # is gone (it skips instead of spawning a fresh one) and makes the row a
  # candidate for CleanupStaleTriggersJob's one-shot sweeps. Neither is wanted.
  test "the seeded trigger is not a one-time reuse trigger" do
    trigger = Sessions::DashboardReprioritizer.trigger!

    assert_not trigger.one_time_reuse_trigger?
    assert_not trigger.dead_one_time_wake?
    assert_nil trigger.trigger_conditions.first.scheduled_at,
      "a one-time schedule here would make the row collectable by the stale-trigger sweep"
  end

  test "the trigger is configured to reuse its session across presses" do
    trigger = Sessions::DashboardReprioritizer.trigger!

    assert trigger.reuse_session, "a session per press is the thing this exists to avoid"
    assert trigger.enqueue_messages, "a press landing mid-turn has to survive to the next turn boundary"
    assert trigger.resuscitate_archived, "the reprioritizer archives itself when it is done"
    assert_equal Sessions::DashboardReprioritizer::AGENT_ROOT, trigger.agent_root_name
  end

  test "the agent root the trigger names is one the catalog carries" do
    assert_includes AgentRootsConfig.all.map(&:name), Sessions::DashboardReprioritizer::AGENT_ROOT
  end

  test "the prompt tells the session to use the two User view tools and not to scrape" do
    prompt = Sessions::DashboardReprioritizer::PROMPT_TEMPLATE

    assert_includes prompt, "get_user_view"
    assert_includes prompt, "reorder_user_view"
    assert_match(/do not scrape|Do NOT scrape/i, prompt)
    assert_match(/archive yourself/i, prompt)
  end

  test "a press fires the trigger and returns the session that took the job" do
    result = Sessions::DashboardReprioritizer.call

    assert result.session?
    assert_equal :fired, result.outcome
    assert_match(/#{result.session.id}/, result.message)
  end

  # The whole point: the second press is a follow-up into the conversation the
  # first one started, not a second session.
  test "a second press reuses the first press's session" do
    first = Sessions::DashboardReprioritizer.call
    first.session.update!(status: :needs_input)
    first.session.stubs(:deliver_follow_up!)

    second = Sessions::DashboardReprioritizer.call

    assert_equal first.session.id, second.session.id
    assert_equal 1, Session.where(id: [ first.session.id, second.session.id ]).count
  end
end

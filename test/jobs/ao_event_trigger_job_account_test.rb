# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The account half of the ao_event vocabulary.
#
# Every existing ao_event is a session transition, and the firing job used to be
# written entirely in those terms: it loaded a Session, filtered on
# `is_autonomous`, compared against `watched_session_id`, and checked whether the
# transitioning session was one the trigger had spawned. `account_needs_reauth`
# has none of those, and what these cover is that the seam holds in both
# directions — an account event carries an account through, and neither kind of
# event fires the other kind's conditions.
class AoEventTriggerJobAccountTest < ActiveJob::TestCase
  EVENT = "account_needs_reauth"

  setup do
    # Deliberately NOT stubbing AgentRootsConfig: `general-agent` and
    # `slack-workspace` are real catalog entries, and half the point of these
    # tests is that the seeded trigger names ones that resolve. Only the spawn
    # itself is stubbed out.
    AgentSessionJob.stubs(:enqueue_new_session)

    # Isolate: every other enabled ao_event trigger (including the seeded one and
    # the session-event fixtures) is stood down so a count assertion measures this
    # test's trigger alone. update_columns, because standing a fixture down is not
    # an edit worth revalidating it for.
    Trigger.where(status: "enabled").find_each do |t|
      t.update_columns(status: "disabled") if t.trigger_conditions.ao_event.exists?
    end

    @trigger = Trigger.create!(
      name: "Reauth notifier",
      agent_root_name: "general-agent",
      prompt_template: "{{event}} — go tell someone.",
      mcp_servers: [ "slack-workspace" ],
      status: "enabled",
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => EVENT } }
      ]
    )
    @condition = @trigger.trigger_conditions.first

    @account = claude_accounts(:primary)
    @account.update_columns(status: ClaudeAccount.statuses[:needs_reauth])
  end

  test "an account event spawns a session and spends the condition" do
    assert_difference("Session.count", 1) do
      AoEventTriggerJob.perform_now(EVENT, @account.id)
    end

    assert_not_nil @condition.reload.last_triggered_at
  end

  # The point of the whole redesign: the notification is composed by an agent that
  # holds the Slack MCP server, not by Zimmer.
  test "the spawned session gets the general-agent root and the slack MCP server" do
    AoEventTriggerJob.perform_now(EVENT, @account.id)
    spawned = Session.order(:id).last

    assert_equal "general-agent", spawned.agent_root_key
    assert_includes spawned.mcp_servers, "slack-workspace"
    assert_equal @trigger.id.to_s, spawned.metadata["trigger_id"].to_s
  end

  test "the prompt names the account and its runtime" do
    AoEventTriggerJob.perform_now(EVENT, @account.id)
    spawned = Session.order(:id).last

    assert_includes spawned.prompt, @account.email
    assert_includes spawned.prompt, "Claude"
    assert_includes spawned.prompt, "needs re-authentication"
  end

  test "a codex account says Codex rather than Claude" do
    codex = ClaudeAccount.create!(email: "codex-event@example.com", runtime: "codex")
    codex.update_columns(status: ClaudeAccount.statuses[:needs_reauth])

    AoEventTriggerJob.perform_now(EVENT, codex.id)

    assert_includes Session.order(:id).last.prompt, "Codex account codex-event@example.com"
  end

  # The account can be re-authenticated, or resurrected by a filesystem sync,
  # between the transition and this job running. Spawning a session to report a
  # problem that no longer exists is worse than saying nothing.
  test "an account that recovered before the job ran does not fire" do
    @account.update_columns(status: ClaudeAccount.statuses[:active])

    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now(EVENT, @account.id)
    end

    assert_nil @condition.reload.last_triggered_at
  end

  # The claim was taken at emit time for a notification that is now not happening.
  # Holding it would silence the next — real — condemnation for the rest of the
  # window.
  test "a stale account gets its throttle slot back" do
    @account.update_columns(
      status: ClaudeAccount.statuses[:active],
      reauth_alerted_at: Time.current
    )

    AoEventTriggerJob.perform_now(EVENT, @account.id)

    assert_nil @account.reload.reauth_alerted_at
  end

  # The flood the throttle exists to stop is unaffected by that release: in the
  # flood the account is still needs_reauth when the job runs, so it is not stale
  # and the slot stays spent.
  test "a still-dead account keeps its throttle slot spent" do
    stamped = 1.minute.ago.change(usec: 0)
    @account.update_columns(reauth_alerted_at: stamped)

    AoEventTriggerJob.perform_now(EVENT, @account.id)

    assert_equal stamped, @account.reload.reauth_alerted_at
  end

  test "a deleted account does not fire and does not raise" do
    id = @account.id
    @account.destroy!

    assert_no_difference("Session.count") do
      assert_nothing_raised { AoEventTriggerJob.perform_now(EVENT, id) }
    end
  end

  # is_autonomous is a property of sessions. An account has none, and the
  # broadcast filter that reads it must not be applied to one — nor may the
  # account id be mistaken for a session id.
  test "a session transition does not fire an account condition" do
    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now("session_needs_input", session.id)
    end
  end

  test "an account event does not fire a session condition" do
    @condition.update!(configuration: { "event_name" => "session_needs_input" })

    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now(EVENT, @account.id)
    end
  end

  test "a disabled trigger does not fire" do
    @trigger.update!(status: "disabled")

    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now(EVENT, @account.id)
    end
  end

  # An account condition is broadcast and recurring, so a fire that raises must
  # leave it enabled — parking it would silently stop every future alert, which is
  # the failure this whole change exists to end.
  test "a fire that raises alerts and leaves the trigger enabled" do
    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("spawn exploded"))
    AlertService.expects(:raise_alert).with do |title, opts|
      title == "State-change wake failed to fire" && opts[:details].include?(@account.email)
    end.returns(true)

    assert_nothing_raised { AoEventTriggerJob.perform_now(EVENT, @account.id) }

    assert_equal "enabled", @trigger.reload.status
  end

  # The circularity: reporting a dead account needs a live one to spawn the
  # session with. When the pool is empty enough that the spawn fails, the failure
  # is not silent — it reaches #eng-alerts, which needs no account at all.
  test "an unspawnable session still reaches a human through the alert channel" do
    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("no usable account in the pool"))
    alerted = false
    AlertService.stubs(:raise_alert).with { |_t, _o| alerted = true }.returns(true)

    AoEventTriggerJob.perform_now(EVENT, @account.id)

    assert alerted, "a spawn failure must still surface somewhere a human looks"
  end
end

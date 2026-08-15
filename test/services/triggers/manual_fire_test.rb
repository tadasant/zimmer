# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class Triggers::ManualFireTest < ActiveSupport::TestCase
  setup do
    @trigger = triggers(:enabled_slack_trigger)
    stub_session_creation
  end

  def stub_session_creation
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)
  end

  test "fires the trigger's own path: the session is linked to it and the fire counter moves" do
    before = @trigger.sessions_created_count

    result = nil
    assert_difference("Session.count", 1) do
      result = Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::API)
    end

    assert_equal :fired, result.outcome
    assert result.fired?
    assert result.session?
    assert_equal @trigger.id.to_s, result.session.metadata["trigger_id"].to_s
    assert_equal before + 1, @trigger.reload.sessions_created_count
    assert_not_nil @trigger.last_triggered_at
  end

  test "interpolates only the variables the template can name" do
    result = Triggers::ManualFire.call(
      trigger: @trigger,
      genesis: SessionGenesis::API,
      variables: { "link" => "https://example.com/msg/1", "channel" => "eng-alerts", "nonsense" => "dropped" }
    )

    assert_includes result.session.prompt, "https://example.com/msg/1"
    assert_includes result.session.prompt, "#eng-alerts"
    assert_not_includes result.session.prompt, "dropped"
  end

  test "an omitted variable interpolates as an empty string rather than raising" do
    result = Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::API)

    assert_equal :fired, result.outcome
    assert_not_includes result.session.prompt, "{{link}}"
  end

  test "the caller's genesis is what the session carries" do
    api = Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::API)
    assert_equal SessionGenesis::API, api.session.genesis

    web = Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::WEB_UI)
    assert_equal SessionGenesis::WEB_UI, web.session.genesis
  end

  test "over the burst cap the outcome is a burst notice, then suppression" do
    @trigger.update!(max_sessions_per_minute: 1)

    assert_equal :fired, Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::API).outcome

    notice = Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::API)
    assert_equal :burst_notice, notice.outcome
    assert notice.session?
    assert notice.session.metadata["burst_notice"]
    assert_match(/burst-notice session it spawned instead/, notice.message)

    suppressed = nil
    assert_no_difference("Session.count") do
      suppressed = Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::API)
    end
    assert_equal :burst_suppressed, suppressed.outcome
    assert_not suppressed.session?
    assert_match(/is in a burst/, suppressed.message)
  end

  test "a one-time reuse trigger whose target session is gone reports not_reusable" do
    @trigger.update!(reuse_session: true, last_session_id: 999_999_999)
    @trigger.stubs(:one_time_reuse_trigger?).returns(true)

    result = nil
    assert_no_difference("Session.count") do
      result = Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::API)
    end

    assert_equal :not_reusable, result.outcome
    assert_not result.session?
    assert_match(/no longer reusable/, result.message)
  end

  # The one outcome that comes back carrying a session it did NOT fire:
  # Trigger#create_session! hands the stale target straight back.
  test "a one-time reuse trigger whose target session is unusable reports not_reusable, with the target" do
    target = sessions(:failed)
    @trigger.update!(reuse_session: true, last_session_id: target.id, resuscitate_archived: false)
    @trigger.stubs(:one_time_reuse_trigger?).returns(true)
    fired_at_before = @trigger.last_triggered_at

    result = nil
    assert_no_difference("Session.count") do
      result = Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::API)
    end

    assert_equal :not_reusable, result.outcome, "a session came back, but nothing fired"
    assert_equal target.id, result.session.id
    assert_match(/no longer reusable/, result.message)
    assert_nil fired_at_before, "fixture sanity: the trigger has not fired yet"
    assert_nil @trigger.reload.last_triggered_at, "a declined reuse must not record a fire"
  end
end

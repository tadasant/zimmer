# frozen_string_literal: true

require "test_helper"

# MCP parity for the spot/priority surface: everything the /settings card shows
# and does must be reachable over MCP.
class Mcp::Tools::SpotPolicyTest < ActiveSupport::TestCase
  setup do
    @context = Mcp::Context.new(base_url: "http://test.host")
    AppSetting.editable.update!(spot_gating_enabled: false, genesis_class_overrides: {})
  end

  def get_policy
    Mcp::Tools::GetSpotPolicy.new(context: @context).call({})
  end

  def action(args)
    Mcp::Tools::ActionSpotPolicy.new(context: @context).call(args.stringify_keys)
  end

  # --- registry ---------------------------------------------------------------

  test "both tools are registered in the health group" do
    names = Mcp::Registry.tools_for(%w[health]).map(&:tool_name)
    assert_includes names, "get_spot_policy"
    assert_includes names, "action_spot_policy"
  end

  test "the write tool is absent from the readonly health group" do
    names = Mcp::Registry.tools_for(%w[health_readonly]).map(&:tool_name)
    assert_includes names, "get_spot_policy"
    refute_includes names, "action_spot_policy"
  end

  # --- read -------------------------------------------------------------------

  test "get_spot_policy reports the setting, the decision and every genesis" do
    output = get_policy

    assert_match(/Gating enabled:\*\* no/, output)
    assert_match(/5-hour window target:\*\* 80%/, output)
    assert_match(/Current decision/, output)
    SessionGenesis::KEYS.each { |key| assert_match(/`#{key}`/, output) }
  end

  # The page and the tool render the same decision, which is the property that
  # keeps the card's badge and the tool's answer from disagreeing.
  test "get_spot_policy reports the live decision and both windows" do
    # The gate averages every account with a reading. Leave only this one with
    # anything to say.
    ClaudeAccountQuotaSnapshot.delete_all
    account = ClaudeAccount.create!(email: "mcp-window@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    ClaudeAccountQuotaSnapshot.create!(claude_account: account, utilization_5h: 0.42, utilization_7d: 0.10,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, active_session_count: 1,
      trigger: "usage_sample")
    AppSetting.editable.update!(spot_gating_enabled: true,
                                spot_gate_five_hour_threshold_pct: 80, spot_gate_weekly_threshold_pct: 80)

    output = get_policy
    decision = SpotGateService.evaluate

    assert_match(/Windows averaged across:\*\* 1 of \d+ accounts in the pool/, output)
    assert_match(/needs_reauth included/, output)
    refute_match(/mcp-window@example\.com/, output,
                 "the decision is the pool's, so no single account is named as the one that decides")
    assert_match(/Utilization now:\*\* 42\.0%/, output)
    assert_match(/At the target:\*\* no/, output)
    assert_equal decision.allowed?, output.include?("**Spot sessions:** running"),
      "the tool must report the same decision the page renders"
  end

  test "get_spot_policy says when a window has reached its target" do
    ClaudeAccountQuotaSnapshot.delete_all
    account = ClaudeAccount.create!(email: "mcp-at-limit@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    ClaudeAccountQuotaSnapshot.create!(claude_account: account, utilization_5h: 0.85, utilization_7d: 0.10,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, active_session_count: 1,
      trigger: "usage_sample")
    AppSetting.editable.update!(spot_gating_enabled: true,
                                spot_gate_five_hour_threshold_pct: 80, spot_gate_weekly_threshold_pct: 80)

    output = get_policy
    assert_match(/Spot sessions:\*\* HELD/, output)
    assert_match(/Reason:\*\* `at_utilization_limit`/, output)
    assert_match(/At the target:\*\* yes — spot work is paused until it falls/, output)
  end

  # Parity with /quotas: an agent asking why it is held has to see the same
  # aggregate the page shows, including the accounts a human cannot serve from.
  test "get_spot_policy averages every account, needs_reauth included" do
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.for_runtime("claude_code").destroy_all
    serving = ClaudeAccount.create!(email: "mcp-serving@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    reauth = ClaudeAccount.create!(email: "mcp-reauth@example.com", runtime: "claude_code",
                                   oauth_config: { "x" => 1 }, status: :needs_reauth)
    ClaudeAccountQuotaSnapshot.create!(claude_account: serving, utilization_5h: 0.95, utilization_7d: 0.10,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, active_session_count: 1, trigger: "usage_sample")
    ClaudeAccountQuotaSnapshot.create!(claude_account: reauth, utilization_5h: 0.05, utilization_7d: 0.10,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, active_session_count: 1, trigger: "usage_sample")
    AppSetting.editable.update!(spot_gating_enabled: true,
                                spot_gate_five_hour_threshold_pct: 80, spot_gate_weekly_threshold_pct: 80)

    output = get_policy

    assert_match(/Windows averaged across:\*\* all 2 accounts in the pool/, output)
    assert_match(/Utilization now:\*\* 50\.0%/, output,
                 "the serving account alone reads 95% — the pool average is what the tool reports")
  end

  test "get_spot_policy reflects a demotion" do
    action(action: "demote_genesis", genesis: SessionGenesis::WEB_UI)
    output = get_policy

    assert_match(/`web_ui` \| Zimmer web app \| \*\*spot\*\* \(changed from priority\)/, output)
  end

  test "get_spot_policy says where each kind's class is set" do
    output = get_policy

    assert_match(/`web_ui`.*`action_spot_policy`/, output)
    assert_match(/`slack`.*the trigger/, output)
  end

  test "get_spot_policy lists the triggers that carry a class of their own" do
    assert_match(/None — every trigger derives its class/, get_policy)

    trigger = triggers(:enabled_schedule_trigger)
    trigger.update!(scheduling_class: SessionGenesis::PRIORITY)

    output = get_policy
    assert_match(/Triggers with their own class/, output)
    assert_match(/#{Regexp.escape(trigger.name)}/, output)
    assert_match(/\*\*priority\*\*/, output)
  end

  # --- write ------------------------------------------------------------------

  test "set_gating turns the gate on and sets both thresholds" do
    action(action: "set_gating", enabled: true, five_hour_threshold_pct: 70, weekly_threshold_pct: 60)

    setting = AppSetting.current
    assert setting.spot_gating_enabled
    assert_equal 70, setting.spot_gate_five_hour_threshold_pct
    assert_equal 60, setting.spot_gate_weekly_threshold_pct
  end

  test "set_gating leaves omitted fields alone" do
    action(action: "set_gating", enabled: true, five_hour_threshold_pct: 55)
    action(action: "set_gating", weekly_threshold_pct: 45)

    setting = AppSetting.current
    assert setting.spot_gating_enabled, "an omitted enabled flag must not turn the gate off"
    assert_equal 55, setting.spot_gate_five_hour_threshold_pct
    assert_equal 45, setting.spot_gate_weekly_threshold_pct
  end

  # Parity: the cap is on the /quotas form, so an agent has to be able to set it
  # and read it back without a human at the page.
  test "set_gating sets the max concurrent sessions cap, and get reports it" do
    action(action: "set_gating", enabled: true, max_concurrent_sessions: 4)

    assert_equal 4, AppSetting.current.spot_max_concurrent_sessions
    assert_match(/Max sessions at once:\*\* 4/, get_policy)
  end

  test "an out-of-range cap comes back as a message rather than an internal error" do
    AppSetting.editable.update!(spot_max_concurrent_sessions: 10)

    error = assert_raises(Mcp::ToolError) { action(action: "set_gating", max_concurrent_sessions: 0) }
    assert_match(/Invalid spot policy/, error.message)
    assert_equal 10, AppSetting.current.spot_max_concurrent_sessions
  end

  test "set_gating with nothing to change is an error rather than a silent no-op" do
    assert_raises(Mcp::ToolError) { action(action: "set_gating") }
  end

  test "promote_genesis reclassifies existing sessions" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::API)
    assert session.spot?

    output = action(action: "promote_genesis", genesis: SessionGenesis::API)

    assert_match(/is now \*\*priority\*\*/, output)
    assert session.reload.priority?, "the promotion must apply to sessions that already exist"
  end

  test "a trigger-backed genesis is refused, and says where to set it instead" do
    error = assert_raises(Mcp::ToolError) do
      action(action: "demote_genesis", genesis: SessionGenesis::SLACK)
    end

    assert_match(/takes its class from the trigger/, error.message)
    assert_match(/action_trigger/, error.message)
    assert_equal({}, AppSetting.current.genesis_class_overrides)
  end

  test "every trigger-backed kind is refused" do
    SessionGenesis::TRIGGER_BACKED_KEYS.each do |key|
      assert_raises(Mcp::ToolError, "#{key} should not be settable here") do
        action(action: "promote_genesis", genesis: key)
      end
    end
  end

  test "demote_genesis moves a kind to spot" do
    action(action: "demote_genesis", genesis: SessionGenesis::WEB_UI)
    assert_equal SessionGenesis::SPOT, SessionGenesis.effective_class(SessionGenesis::WEB_UI)
  end

  test "reset_genesis_classes drops every override" do
    action(action: "promote_genesis", genesis: SessionGenesis::API)
    action(action: "demote_genesis", genesis: SessionGenesis::WEB_UI)
    action(action: "reset_genesis_classes")

    assert_equal({}, AppSetting.current.genesis_class_overrides)
    assert_equal SessionGenesis::SPOT, SessionGenesis.effective_class(SessionGenesis::API)
    assert_equal SessionGenesis::PRIORITY, SessionGenesis.effective_class(SessionGenesis::WEB_UI)
  end

  test "the tool only advertises the settable kinds" do
    enum = Mcp::Tools::ActionSpotPolicy.input_schema.to_h.dig(:properties, :genesis, :enum)
    assert_equal SessionGenesis::SETTABLE_KEYS, enum
  end

  test "an unknown action is rejected" do
    assert_raises(Mcp::ToolError) { action(action: "delete_everything") }
  end

  test "an unknown genesis is rejected" do
    assert_raises(Mcp::ToolError) { action(action: "promote_genesis", genesis: "carrier_pigeon") }
  end

  test "an out-of-range threshold comes back as a readable tool error" do
    error = assert_raises(Mcp::ToolError) do
      action(action: "set_gating", five_hour_threshold_pct: 150)
    end
    assert_match(/Invalid spot policy/, error.message)
  end
end

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
    assert_match(/5-hour window limit:\*\* 80%/, output)
    assert_match(/Current decision/, output)
    SessionGenesis::KEYS.each { |key| assert_match(/`#{key}`/, output) }
  end

  test "get_spot_policy reflects a promotion" do
    action(action: "promote_genesis", genesis: SessionGenesis::GITHUB_ISSUE)
    output = get_policy

    assert_match(/`github_issue` \| GitHub issue trigger \| \*\*priority\*\* \(changed from spot\)/, output)
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

  test "set_gating with nothing to change is an error rather than a silent no-op" do
    assert_raises(Mcp::ToolError) { action(action: "set_gating") }
  end

  test "promote_genesis reclassifies existing sessions" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::GITHUB_ISSUE)
    assert session.spot?

    output = action(action: "promote_genesis", genesis: SessionGenesis::GITHUB_ISSUE)

    assert_match(/is now \*\*priority\*\*/, output)
    assert session.reload.priority?, "the promotion must apply to sessions that already exist"
  end

  test "demote_genesis moves a kind to spot" do
    action(action: "demote_genesis", genesis: SessionGenesis::WEB_UI)
    assert_equal SessionGenesis::SPOT, SessionGenesis.effective_class(SessionGenesis::WEB_UI)
  end

  test "reset_genesis_classes drops every override" do
    action(action: "promote_genesis", genesis: SessionGenesis::GITHUB_ISSUE)
    action(action: "demote_genesis", genesis: SessionGenesis::WEB_UI)
    action(action: "reset_genesis_classes")

    assert_equal({}, AppSetting.current.genesis_class_overrides)
    assert_equal SessionGenesis::SPOT, SessionGenesis.effective_class(SessionGenesis::GITHUB_ISSUE)
    assert_equal SessionGenesis::PRIORITY, SessionGenesis.effective_class(SessionGenesis::WEB_UI)
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
    assert_match(/Invalid thresholds/, error.message)
  end
end

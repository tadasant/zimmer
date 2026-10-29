# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::GetTestflightCrashesTest < ActiveSupport::TestCase
  setup do
    @context = Mcp::Context.new(base_url: "http://test.host")
    SecretProviders.stubs(:chain).returns(SecretProviders::Chain.new([ SecretProviders::Env.new({}) ]))
  end

  def call(args = {})
    Mcp::Tools::GetTestflightCrashes.new(context: @context).call(args.stringify_keys)
  end

  test "is a read in the health group, so health_readonly carries it" do
    assert_includes Mcp::Registry.tools_for(%w[health]).map(&:tool_name), "get_testflight_crashes"
    assert_includes Mcp::Registry.tools_for(%w[health_readonly]).map(&:tool_name), "get_testflight_crashes"
  end

  test "an empty list says whether the poller is configured" do
    output = call

    assert_match(/No submissions stored/, output)
    assert_match(/not configured.*TESTFLIGHT_ASC_ISSUER_ID/, output)
  end

  test "lists crashes newest first with their headline, and screenshots only when asked" do
    TestflightFeedback.create!(asc_id: "old", kind: "crash", submitted_at: 2.days.ago, crash_log: AppStoreConnectFixtures::CRASH_LOG)
    TestflightFeedback.create!(asc_id: "new", kind: "crash", submitted_at: 1.hour.ago, build_number: "212", comment: "CarPlay\nconnect")
    TestflightFeedback.create!(asc_id: "shot", kind: "screenshot", submitted_at: 1.minute.ago)

    output = call

    assert_operator output.index("**new**"), :<, output.index("**old**")
    assert_match(/\*\*new\*\* crash .* build 212 .* log pending · “CarPlay connect”/, output)
    assert_match(/\*\*old\*\* crash .*Exception Type:  EXC_CRASH \(SIGABRT\)/, output)
    refute_match(/shot/, output)
    assert_match(/\*\*shot\*\*/, call(kind: "all"))
  end

  test "reports the poller configured when all three values resolve" do
    SecretProviders.stubs(:chain).returns(SecretProviders::Chain.new([ SecretProviders::Env.new(
      "TESTFLIGHT_ASC_ISSUER_ID" => "i", "TESTFLIGHT_ASC_KEY_ID" => "k", "TESTFLIGHT_ASC_KEY_P8" => "p"
    ) ]))

    assert_match(/Poller: configured; newest row stored never/, call)
  end

  test "get returns the whole crash log and the attributes" do
    TestflightFeedback.create!(asc_id: "c1", kind: "crash", comment: "it died", tester_email: "t@example.com",
      crash_log: AppStoreConnectFixtures::CRASH_LOG, raw_attributes: { "batteryPercentage" => 81, "comment" => "it died" })

    output = call(id: "c1")

    assert_includes output, AppStoreConnectFixtures::CRASH_LOG
    assert_match(/"batteryPercentage": 81/, output)
    assert_match(/### Comment\n\nit died/, output)
    refute_match(/Truncated/, output)
  end

  test "a long crash log pages, and says which call returns the rest" do
    log = "A" * 1_500 + "B" * 1_500
    TestflightFeedback.create!(asc_id: "c1", kind: "crash", crash_log: log)

    first = call(id: "c1", max_chars: 1_500)
    assert_includes first, "A" * 1_500
    refute_includes first, "BBB"
    assert_match(/offset: 1500/, first)

    rest = call(id: "c1", offset: 1_500, max_chars: 1_500)
    assert_includes rest, "B" * 1_500
    refute_match(/Truncated/, rest)
  end

  test "an unknown id is a tool error" do
    assert_raises(Mcp::ToolError) { call(id: "nope") }
  end
end

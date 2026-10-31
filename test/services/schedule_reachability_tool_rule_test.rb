# frozen_string_literal: true

require "test_helper"

class ScheduleReachabilityToolRuleTest < ActiveSupport::TestCase
  def rule(config = {})
    ScheduleReachabilityToolRule.from_configuration(config)
  end

  # -- defaults (a condition saved before the rule existed) --

  test "with no keys, strad's placeholder is excluded and any other tool passes" do
    assert_equal %w[troubleshoot_host], rule.exclude
    assert rule.default?

    assert_nil rule.failure(%w[imessage-tadas-mbp__send_message])
    assert_match(/\Aexclude rule failed: lists imessage-tadas-mbp__troubleshoot_host\z/, rule.failure(%w[imessage-tadas-mbp__troubleshoot_host]))
  end

  test "an empty list never passes" do
    assert_equal "it lists no tools", rule.failure([])
    assert_equal "it lists no tools", rule("reachable_tools_exclude" => []).failure([])
  end

  # -- exclude --

  test "an explicit empty exclusion lets the placeholder count as reachable" do
    assert_nil rule("reachable_tools_exclude" => []).failure(%w[anki__troubleshoot_host])
  end

  test "an excluded tool fails the server even beside real tools" do
    failure = rule("reachable_tools_exclude" => %w[troubleshoot_host maintenance_*]).failure(%w[s__send_message s__maintenance_mode])
    assert_equal "exclude rule failed: lists s__maintenance_mode", failure
  end

  # -- include --

  test "include any: one listed include is enough" do
    r = rule("reachable_tools_include" => %w[send_message read_*])

    assert_nil r.failure(%w[s__read_messages])
    assert_equal "include rule failed: lists none of send_message, read_*", r.failure(%w[s__list_chats])
  end

  test "include all: every include must be listed, and the failure names the missing ones" do
    r = rule("reachable_tools_include" => %w[send_message read_messages], "reachable_tools_include_mode" => "all")

    assert_nil r.failure(%w[s__send_message s__read_messages s__other])
    assert_match(/\Ainclude rule failed: lists none matching read_messages/, r.failure(%w[s__send_message]))
  end

  test "the exclusion is checked before the include" do
    r = rule("reachable_tools_include" => %w[send_message])

    assert_match(/\Aexclude rule failed/, r.failure(%w[s__troubleshoot_host]))
  end

  # -- matching --

  test "an entry matches the full name or the bare one after the first __" do
    r = rule("reachable_tools_include" => %w[imessage-tadas-mbp__send_message], "reachable_tools_exclude" => [])

    assert_nil r.failure(%w[imessage-tadas-mbp__send_message])
    assert_match(/include rule failed/, r.failure(%w[imessage-other__send_message]))
    assert_nil rule("reachable_tools_include" => %w[send_message]).failure(%w[send_message]), "an un-namespaced tool matches by its own name"
  end

  # -- validation --

  test "errors name a bad mode, a bad entry and an overlap" do
    errors = rule("reachable_tools_include_mode" => "most", "reachable_tools_include" => [ "bad name!", "x" ],
                  "reachable_tools_exclude" => %w[x]).errors

    assert(errors.any? { |e| e.include?("reachable_tools_include_mode must be one of any, all") })
    assert(errors.any? { |e| e.include?("bad name!") })
    assert(errors.any? { |e| e.include?("x is both included and excluded") })
    assert_empty rule("reachable_tools_include" => "send_message, read_*").errors
  end

  test "the form's comma-separated text parses into a list" do
    assert_equal %w[send_message read_*], rule("reachable_tools_include" => "send_message, read_*\nsend_message").include
  end
end

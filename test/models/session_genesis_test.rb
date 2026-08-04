# frozen_string_literal: true

require "test_helper"

class SessionGenesisTest < ActiveSupport::TestCase
  # --- taxonomy ---------------------------------------------------------------

  test "every genesis kind has a valid class" do
    SessionGenesis::KINDS.each do |kind|
      assert_includes SessionGenesis::CLASSES, kind.default_class, "#{kind.key} has an invalid default class"
      assert kind.label.present?, "#{kind.key} has no label"
      assert kind.description.present?, "#{kind.key} has no description"
    end
  end

  test "keys are unique" do
    assert_equal SessionGenesis::KEYS.uniq, SessionGenesis::KEYS
  end

  # The classification Tadas named explicitly. If a later change flips one of
  # these, it should have to delete a test that says so out loud.
  test "web app entry and Slack triggers default to priority" do
    assert_equal SessionGenesis::PRIORITY, SessionGenesis.default_class(SessionGenesis::WEB_UI)
    assert_equal SessionGenesis::PRIORITY, SessionGenesis.default_class(SessionGenesis::SLACK)
  end

  test "the gate feeds default to spot" do
    assert_equal SessionGenesis::SPOT, SessionGenesis.default_class(SessionGenesis::GITHUB_ISSUE)
    assert_equal SessionGenesis::SPOT, SessionGenesis.default_class(SessionGenesis::GITHUB_LABEL)
  end

  test "unknown fails safe to priority" do
    assert_equal SessionGenesis::PRIORITY, SessionGenesis.default_class(SessionGenesis::UNKNOWN)
    assert_equal SessionGenesis::PRIORITY, SessionGenesis.default_class("something-nobody-defined")
  end

  # --- trigger condition parity ----------------------------------------------

  test "every trigger condition type maps to a genesis" do
    TriggerCondition::CONDITION_TYPES.each do |type|
      assert SessionGenesis::CONDITION_TYPE_KINDS.key?(type),
        "TriggerCondition type #{type} has no genesis mapping"
      assert_includes SessionGenesis::CONDITION_TYPE_PRECEDENCE, type,
        "TriggerCondition type #{type} is missing from the precedence order"
    end
  end

  test "from_condition_types picks the human-facing kind when a trigger mixes types" do
    assert_equal SessionGenesis::SLACK, SessionGenesis.from_condition_types(%w[schedule slack])
    assert_equal SessionGenesis::GITHUB_LABEL, SessionGenesis.from_condition_types(%w[schedule github_label])
    assert_equal SessionGenesis::SCHEDULE, SessionGenesis.from_condition_types(%w[schedule])
  end

  test "from_condition_types falls back to unknown for an empty list" do
    assert_equal SessionGenesis::UNKNOWN, SessionGenesis.from_condition_types([])
  end

  # --- override resolution ----------------------------------------------------

  test "effective_classes returns defaults with no overrides" do
    classes = SessionGenesis.effective_classes({})
    assert_equal SessionGenesis::SPOT, classes[SessionGenesis::GITHUB_ISSUE]
    assert_equal SessionGenesis::PRIORITY, classes[SessionGenesis::WEB_UI]
  end

  test "an override moves a kind" do
    classes = SessionGenesis.effective_classes({ SessionGenesis::GITHUB_ISSUE => SessionGenesis::PRIORITY })
    assert_equal SessionGenesis::PRIORITY, classes[SessionGenesis::GITHUB_ISSUE]
    # Untouched kinds keep their defaults.
    assert_equal SessionGenesis::SPOT, classes[SessionGenesis::SCHEDULE]
  end

  test "a garbage override value is ignored rather than trusted" do
    classes = SessionGenesis.effective_classes({ SessionGenesis::WEB_UI => "urgent" })
    assert_equal SessionGenesis::PRIORITY, classes[SessionGenesis::WEB_UI]
  end

  test "keys_classified splits the taxonomy" do
    spot = SessionGenesis.keys_classified(SessionGenesis::SPOT, {})
    priority = SessionGenesis.keys_classified(SessionGenesis::PRIORITY, {})

    assert_includes spot, SessionGenesis::GITHUB_ISSUE
    assert_includes priority, SessionGenesis::WEB_UI
    assert_equal SessionGenesis::KEYS.sort, (spot + priority).sort
  end

  test "overridden? reports divergence from the shipped default" do
    refute SessionGenesis.overridden?(SessionGenesis::GITHUB_ISSUE, {})
    assert SessionGenesis.overridden?(SessionGenesis::GITHUB_ISSUE,
      { SessionGenesis::GITHUB_ISSUE => SessionGenesis::PRIORITY })
  end
end

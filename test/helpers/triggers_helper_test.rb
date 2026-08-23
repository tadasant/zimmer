# frozen_string_literal: true

require "test_helper"

class TriggersHelperTest < ActionView::TestCase
  include TriggersHelper

  test "every condition type maps to an icon key" do
    TriggerCondition::CONDITION_TYPES.each do |condition_type|
      assert_equal 1, trigger_condition_icon_keys([ condition_type ]).size,
        "#{condition_type} should map to exactly one icon"
      assert_not_equal [ :fallback ], trigger_condition_icon_keys([ condition_type ]),
        "#{condition_type} should have an icon of its own, not the fallback"
    end
  end

  test "a system_event condition gets its own icon key" do
    assert_equal [ :system_event ], trigger_condition_icon_keys([ "system_event" ])
  end

  test "the two GitHub condition types share one icon" do
    assert_equal [ :github ], trigger_condition_icon_keys([ "github_label", "github_issue" ])
  end

  test "icons come back in a stable order regardless of condition order" do
    assert_equal [ :slack, :schedule ], trigger_condition_icon_keys([ "schedule", "slack" ])
  end

  test "a condition type with no icon of its own falls back rather than rendering nothing" do
    assert_equal [ :fallback ], trigger_condition_icon_keys([ "some_future_condition_type" ])
  end

  test "a trigger with no conditions falls back" do
    assert_equal [ :fallback ], trigger_condition_icon_keys([])
  end

  test "the fallback does not crowd out the icons that did match" do
    assert_equal [ :slack ], trigger_condition_icon_keys([ "slack", "some_future_condition_type" ])
  end

  test "every icon key renders a glyph, and an unknown key renders the fallback glyph" do
    (TriggersHelper::CONDITION_TYPE_ICON_KEYS.values.uniq + [ :fallback, :not_an_icon ]).each do |key|
      render partial: "triggers/condition_icon", locals: { key: key }
      assert_select "svg path", minimum: 1, message: "#{key} should render a glyph"
    end
  end
end

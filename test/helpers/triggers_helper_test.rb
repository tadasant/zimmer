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

  # Each key is asserted against its own render rather than against `rendered`,
  # which accumulates every render in the test and would let an empty glyph hide
  # behind the markup of an earlier iteration.
  test "every icon key renders a glyph, and an unknown key renders the fallback glyph" do
    (TriggersHelper::CONDITION_TYPE_ICON_KEYS.values.uniq + [ :fallback, :not_an_icon ]).each do |key|
      html = render(partial: "triggers/condition_icon", locals: { key: key })
      fragment = Rails::Dom::Testing.html_document_fragment.parse(html)

      assert_select fragment, "svg[role=img][aria-label] path", { minimum: 1 }, "#{key} should render a labelled glyph"
    end
  end

  # The detail page's badge is the same drift hazard as the row's icon: a type
  # added to CONDITION_TYPES without an entry here used to print its raw enum
  # value in a gray pill.
  test "every condition type maps to a badge label and colours of its own" do
    TriggerCondition::CONDITION_TYPES.each do |condition_type|
      badge = trigger_condition_badge(condition_type)

      assert TriggersHelper::CONDITION_TYPE_BADGES.key?(condition_type),
        "#{condition_type} should have a badge of its own, not the titleized fallback"
      assert_not_equal condition_type, badge[:label],
        "#{condition_type} should be badged with words, not with its raw enum value"
      assert badge[:css].present?, "#{condition_type} should have badge colours"
    end
  end

  test "the two GitHub condition types share one badge" do
    assert_equal trigger_condition_badge("github_label"), trigger_condition_badge("github_issue")
  end

  test "a condition type with no badge of its own is titleized rather than shown raw" do
    badge = trigger_condition_badge("some_future_condition_type")

    assert_equal "Some Future Condition Type", badge[:label]
    assert_equal TriggersHelper::FALLBACK_CONDITION_BADGE_CSS, badge[:css]
  end

  test "the detail line drops the prefix the badge already carries" do
    condition = TriggerCondition.new(
      condition_type: "system_event",
      configuration: { "event_name" => "quota_available" }
    )

    assert_equal "System Event: Quota available again", condition.description
    assert_equal "Quota available again", trigger_condition_detail(condition)
  end

  test "the detail line is left whole when it does not repeat the badge" do
    condition = TriggerCondition.new(
      condition_type: "schedule",
      configuration: { "unit" => "hours", "interval" => 2, "timezone" => "UTC" }
    )

    assert_equal condition.description, trigger_condition_detail(condition)
  end

  test "an unknown key renders the same glyph as the fallback key" do
    fallback = render(partial: "triggers/condition_icon", locals: { key: :fallback })
    unknown = render(partial: "triggers/condition_icon", locals: { key: :not_an_icon })

    assert_equal fallback, unknown
  end
end

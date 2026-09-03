# frozen_string_literal: true

module TriggersHelper
  VARIABLE_PLACEHOLDERS = {
    "link" => "e.g. https://example.com/message/123",
    "text" => "e.g. The message content…",
    "author" => "e.g. Jane Doe",
    "channel" => "e.g. #general",
    "event" => "e.g. Session #5 needs input",
    "repo" => "e.g. tadasant/zimmer",
    "number" => "e.g. 177",
    "title" => "e.g. Fix the flaky poller test",
    "labels" => "e.g. ready to merge"
  }.freeze

  def variable_placeholder(variable_name)
    VARIABLE_PLACEHOLDERS[variable_name] || ""
  end

  # Options for a trigger's scheduling-class selector. The blank option names the
  # class the trigger would derive, so "Default" is never a value the operator has
  # to go and look up — except on a brand-new trigger, whose conditions do not
  # exist yet and whose derived class therefore cannot be known.
  def trigger_scheduling_class_options(trigger)
    default = trigger.persisted? ? "Default (#{trigger.default_scheduling_class})" : "Default for this trigger's conditions"

    [
      [ default, "" ],
      [ "Priority — starts whenever it is ready", SessionGenesis::PRIORITY ],
      [ "Spot — waits for quota room or a free slot", SessionGenesis::SPOT ]
    ]
  end

  # A short spot/priority badge, used wherever a trigger is listed.
  def scheduling_class_badge_css(klass)
    if klass == SessionGenesis::PRIORITY
      "bg-indigo-100 text-indigo-800"
    else
      "bg-gray-100 text-gray-700"
    end
  end

  # Condition type → icon key, in the order the icons are stacked in a trigger
  # row. Every type in TriggerCondition::CONDITION_TYPES belongs here; a type
  # absent from this map falls through to :fallback rather than rendering an
  # empty icon slot.
  CONDITION_TYPE_ICON_KEYS = {
    "slack" => :slack,
    "schedule" => :schedule,
    "ao_event" => :ao_event,
    "github_label" => :github,
    "github_issue" => :github,
    "system_event" => :system_event
  }.freeze

  def trigger_condition_icon_keys(condition_types)
    types = Array(condition_types)
    keys = CONDITION_TYPE_ICON_KEYS.select { |type, _| types.include?(type) }.values.uniq

    keys.presence || [ :fallback ]
  end

  # Condition type → the badge a condition wears on the trigger detail page:
  # the words in the pill, and the pill's colors. The colors echo the hue of the
  # icon the same type gets in a trigger row, so the two pages read as one thing.
  #
  # Every type in TriggerCondition::CONDITION_TYPES belongs here. A type absent
  # from this map is titleized rather than shown as its raw enum value, so a
  # newly added type reads as words even before it is given a badge of its own.
  CONDITION_TYPE_BADGES = {
    "slack" => { label: "Slack", css: "bg-purple-100 text-purple-800" },
    "schedule" => { label: "Schedule", css: "bg-blue-100 text-blue-800" },
    "ao_event" => { label: "Zimmer Event", css: "bg-orange-100 text-orange-800" },
    "github_label" => { label: "GitHub", css: "bg-gray-800 text-white" },
    "github_issue" => { label: "GitHub", css: "bg-gray-800 text-white" },
    "system_event" => { label: "System Event", css: "bg-emerald-100 text-emerald-800" }
  }.freeze

  FALLBACK_CONDITION_BADGE_CSS = "bg-gray-100 text-gray-800"

  def trigger_condition_badge(condition_type)
    type = condition_type.to_s

    CONDITION_TYPE_BADGES[type] || { label: type.titleize, css: FALLBACK_CONDITION_BADGE_CSS }
  end

  # What the badge leaves for the line beside it. TriggerCondition#description
  # opens with the same words the badge carries ("Slack: …", "System Event: …"),
  # so the prefix is dropped rather than printed twice. A description that does
  # not carry the prefix is left whole.
  def trigger_condition_detail(condition)
    label = trigger_condition_badge(condition.condition_type)[:label]

    condition.description.to_s.delete_prefix("#{label}: ")
  end
end

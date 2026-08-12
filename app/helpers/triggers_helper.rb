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
      [ "Spot — waits for quota headroom", SessionGenesis::SPOT ]
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
end

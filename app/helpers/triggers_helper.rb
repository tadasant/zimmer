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
end

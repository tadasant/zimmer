# frozen_string_literal: true

module LiveConversationsHelper
  # Matched against already-escaped text, so it stops at an escaped quote or
  # angle bracket as well as at whitespace.
  URL_PATTERN = %r{https?://(?:(?!&quot;|&#39;|&lt;|&gt;)[^\s<>"')\]])+}

  # Escaped text with its URLs as links — what the model says often names the
  # session it just started.
  def live_linkify(text)
    escaped = ERB::Util.html_escape(text.to_s).to_str
    escaped.gsub(URL_PATTERN) do |url|
      %(<a href="#{url}" class="underline break-all" target="_blank" rel="noopener noreferrer">#{url}</a>)
    end.html_safe # rubocop:disable Rails/OutputSafety -- input escaped above; only matched URLs are wrapped
  end

  # "zimmer → quick_router" for a gateway call, the function name otherwise.
  def live_tool_label(turn)
    if turn.tool_name == LiveConversations::ToolBridge::ZIMMER_TOOL && turn.tool_arguments.is_a?(Hash) && turn.tool_arguments["tool"].present?
      "zimmer → #{turn.tool_arguments['tool']}"
    else
      turn.tool_name
    end
  end

  # A successful `update_live_settings` that changed something.
  def live_settings_change?(turn)
    turn.tool? && turn.tool_name == LiveConversations::ToolBridge::UPDATE_SETTINGS && !turn.tool_error &&
      turn.tool_output.to_s.start_with?("Changed:")
  end
end

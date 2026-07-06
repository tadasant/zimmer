module SessionsHelper
  # Resolve a goal value to its display name using predefined goals.
  # Returns the matching goal name, "Custom" if set but unrecognized, or nil if blank.
  def goal_display_name(goal, goals_for_select)
    return nil if goal.blank?

    matching = (goals_for_select || []).find { |g| g[:description] == goal || g[:id] == goal }
    matching ? matching[:name] : "Custom"
  end

  # Returns the CSS class for PR icon color based on status
  def pr_icon_color_class(status)
    case status
    when "merged" then "text-purple-600"
    when "open" then "text-green-600"
    when "closed" then "text-red-600"
    else "text-gray-400"
    end
  end

  # Returns the CSS class for CI status indicator color
  # CI statuses: pass (green), fail (red), pending (yellow), cancel (gray), skipping (gray)
  def ci_status_color_class(ci_status)
    case ci_status
    when "pass" then "text-green-500"
    when "fail" then "text-red-500"
    when "pending" then "text-yellow-500"
    when "cancel", "skipping" then "text-gray-400"
    else "text-gray-300"
    end
  end

  # Returns the background CSS class for CI status indicator
  def ci_status_bg_class(ci_status)
    case ci_status
    when "pass" then "bg-green-500"
    when "fail" then "bg-red-500"
    when "pending" then "bg-yellow-500"
    when "cancel", "skipping" then "bg-gray-400"
    else "bg-gray-300"
    end
  end

  # Extract PR number from a GitHub PR URL for display
  def extract_pr_number(url)
    match = url.to_s.match(%r{/pull/(\d+)})
    match ? "##{match[1]}" : "PR"
  end

  # Returns the CSS classes for session status badges
  # Running badges start green and update dynamically via JS based on elapsed time
  # Other statuses have fixed colors that don't clash with running's green/yellow/red
  def status_badge_classes(agent_session)
    case agent_session.status
    when "running"
      # Default to green, JS will update based on elapsed time
      "bg-green-100 text-green-800"
    when "waiting"
      # Purple for waiting (was yellow, changed to avoid clash with running's yellow)
      "bg-purple-100 text-purple-800"
    when "needs_input"
      # Blue for needs input
      "bg-blue-100 text-blue-800"
    when "failed"
      # Orange for failed (distinct from running's red which indicates long duration)
      "bg-orange-100 text-orange-800"
    else
      # Gray for archived and any other status
      "bg-gray-100 text-gray-800"
    end
  end

  # ---------------------------------------------------------------------------
  # OpenTranscripts display helpers
  # ---------------------------------------------------------------------------
  # These render a single OpenTranscripts event (see OpenTranscript) for the
  # unified timeline_items/_item partial. They key on the event :type rather
  # than decoding per-runtime content blocks, so both runtimes render through
  # one path.

  # Human-readable label for an event's header.
  def ot_event_label(item)
    case item[:type]
    when OpenTranscript::Types::USER_MESSAGE then "User"
    when OpenTranscript::Types::ASSISTANT_MESSAGE then "Assistant"
    when OpenTranscript::Types::THINKING then "Thinking"
    when OpenTranscript::Types::TOOL_CALL then "Tool: #{item[:tool_name].presence || 'unknown'}"
    when OpenTranscript::Types::TOOL_RESULT then item[:is_error] ? "Tool Result (Error)" : "Tool Result"
    when OpenTranscript::Types::SUBAGENT_SPAWN then "Subagent"
    when OpenTranscript::Types::COMPACTION then "Compaction"
    when OpenTranscript::Types::ERROR then "Error"
    when OpenTranscript::Types::SYSTEM_EVENT
      item[:subtype] == "queue-operation" ? "Queue Event" : (item[:subtype].presence || "system").to_s.titleize
    else "Event"
    end
  end

  # Which icon glyph to draw (see timeline_items/_item.html.erb).
  def ot_icon_kind(item)
    case item[:type]
    when OpenTranscript::Types::USER_MESSAGE then :user
    when OpenTranscript::Types::ASSISTANT_MESSAGE then :assistant
    when OpenTranscript::Types::THINKING then :thinking
    when OpenTranscript::Types::TOOL_CALL, OpenTranscript::Types::TOOL_RESULT, OpenTranscript::Types::SUBAGENT_SPAWN then :tool
    when OpenTranscript::Types::ERROR then :error
    else :system
    end
  end

  def ot_badge_class(item)
    case ot_icon_kind(item)
    when :user then "bg-indigo-100"
    when :assistant then "bg-green-100"
    when :thinking then "bg-yellow-100"
    when :tool then "bg-purple-100"
    when :error then "bg-red-100"
    else "bg-cyan-100"
    end
  end

  def ot_icon_color(item)
    case ot_icon_kind(item)
    when :user then "text-indigo-600"
    when :assistant then "text-green-600"
    when :thinking then "text-yellow-600"
    when :tool then "text-purple-600"
    when :error then "text-red-600"
    else "text-cyan-600"
    end
  end

  # Whether this event row should get the subtle gray tool background.
  def ot_tool_row?(item)
    %w[Thinking ToolCall ToolResult SubagentSpawn].include?(item[:type])
  end

  # Count of image ContentParts in a message event (for the image badge).
  def ot_image_count(item)
    parts = item[:content]
    return 0 unless parts.is_a?(Array)

    parts.count { |p| p.is_a?(Hash) && p["type"] == "image" }
  end

  # The markdown body rendered for an event via shared/enhanced_markdown.
  def ot_content_markdown(item)
    case item[:type]
    when OpenTranscript::Types::USER_MESSAGE, OpenTranscript::Types::ASSISTANT_MESSAGE
      ot_parts_to_markdown(item[:content])
    when OpenTranscript::Types::TOOL_RESULT
      ot_parts_to_markdown(item[:output])
    when OpenTranscript::Types::THINKING
      item[:text].to_s
    when OpenTranscript::Types::TOOL_CALL
      ot_tool_call_markdown(item)
    when OpenTranscript::Types::SUBAGENT_SPAWN
      ot_subagent_spawn_markdown(item)
    when OpenTranscript::Types::COMPACTION
      ot_compaction_markdown(item)
    when OpenTranscript::Types::ERROR
      item[:message].to_s
    when OpenTranscript::Types::SYSTEM_EVENT
      ot_system_event_markdown(item)
    else
      ""
    end
  end

  private

  # Join a ContentPart[] into a markdown string. Text parts pass through; image
  # parts render a visual placeholder (image data is not inlined).
  def ot_parts_to_markdown(parts)
    return "" unless parts.is_a?(Array)

    parts.filter_map do |part|
      next unless part.is_a?(Hash)

      case part["type"]
      when "text"
        part["text"]
      when "image"
        type_label = part["mime_type"].to_s.split("/").last.presence&.upcase || "IMAGE"
        "[Image attached: #{type_label}]"
      end
    end.join("\n\n")
  end

  def ot_tool_call_markdown(item)
    parts = [ "Using tool: #{item[:tool_name].presence || 'Unknown Tool'}" ]
    arguments = item[:arguments]

    if arguments.is_a?(Hash) && arguments.any?
      parts << "Parameters:"
      arguments.each do |key, value|
        parts << "  #{key}: #{format_parameter_value(value)}"
      end
    end

    parts.join("\n")
  end

  def ot_subagent_spawn_markdown(item)
    parts = []
    parts << "**Subagent:** #{item[:subagent_type]}" if item[:subagent_type].present?
    parts << item[:description] if item[:description].present?
    parts << "" if parts.any? && item[:prompt].present?
    parts << item[:prompt] if item[:prompt].present?
    parts.join("\n")
  end

  def ot_compaction_markdown(item)
    header = "**Context compaction**"
    header += " (#{item[:trigger]})" if item[:trigger].present?

    parts = [ header ]
    if item[:tokens_before].present? || item[:tokens_after].present?
      parts << "Tokens: #{item[:tokens_before] || '?'} → #{item[:tokens_after] || '?'}"
    end
    parts << item[:summary] if item[:summary].present?
    parts.join("\n")
  end

  def ot_system_event_markdown(item)
    payload = item[:payload]
    return "" unless payload.is_a?(Hash)

    parts = []
    parts << "**Operation:** #{payload['operation'].to_s.titleize}" if payload["operation"].present?
    if payload["content"].is_a?(String) && payload["content"].present?
      parts << payload["content"]
    elsif parts.empty?
      parts << format_hash_preview(payload.except("type"))
    end
    parts.join("\n")
  end

  def format_hash_preview(hash, max_depth: 1)
    return "{}" if hash.empty?
    return "{...}" if max_depth <= 0

    preview_items = hash.first(3).map do |key, value|
      value_preview = case value
      when String
        value.length > 50 ? "\"#{value[0...50]}...\"" : "\"#{value}\""
      when Array
        "[#{value.length} items]"
      when Hash
        format_hash_preview(value, max_depth: max_depth - 1)
      else
        value.to_s
      end
      "#{key}: #{value_preview}"
    end

    suffix = hash.size > 3 ? ", ..." : ""
    "{#{preview_items.join(', ')}#{suffix}}"
  end

  def format_parameter_value(value)
    case value
    when String
      # Truncate long strings
      value.length > 200 ? "#{value[0...200]}..." : value
    when Array
      # Show array info
      "[Array with #{value.length} items]"
    when Hash
      # Show hash info
      "{#{value.keys.join(', ')}}"
    else
      value.to_s
    end
  end
end

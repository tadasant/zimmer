# frozen_string_literal: true

# --- Codex rollout transcript shape ------------------------------------------
class TranscriptHooks::CodexToolCallParser < TranscriptHooks::ToolCallParser
  def shell_calls
    @shell_calls ||= response_items.filter_map do |payload|
      command = shell_command(payload)
      next if command.blank?
      next unless payload["call_id"]

      { id: payload["call_id"], command: command }
    end
  end

  # Every `function_call` payload, shell and non-shell alike. Codex routes an MCP
  # tool through the same payload type as its built-in `shell`, naming it
  # `mcp__<server>__<tool>` (codex-rs `MCP_TOOL_NAME_DELIMITER`) and JSON-encoding
  # its arguments — which is what CodexMcpStatusDetector reads a server's
  # connection out of.
  #
  # `local_shell_call` is not included: it is Codex's own shell payload, it
  # carries an argv rather than named arguments, and it is never an MCP tool.
  def structured_tool_calls
    @structured_tool_calls ||= response_items.filter_map do |payload|
      next unless payload["type"] == "function_call"
      next unless payload["call_id"].is_a?(String) && payload["name"].is_a?(String)

      { id: payload["call_id"], name: payload["name"], input: parse_arguments(payload["arguments"]) }
    end
  end

  def tool_results
    @tool_results ||= begin
      codes = exit_codes_by_call_id

      response_items.filter_map do |payload|
        next unless %w[function_call_output custom_tool_call_output].include?(payload["type"])

        text = output_text(payload["output"])
        next if text.blank?

        exit_code = codes[payload["call_id"]]
        { id: payload["call_id"], text: text, is_error: exit_code.present? && exit_code != 0 }
      end
    end
  end

  # Codex writes the agent's prose twice: as a response_item `message` payload
  # (role "assistant") and as a UI-side `agent_message` event. Both are read so a
  # rollout that carries only one of them is not silently blind.
  def assistant_texts
    @assistant_texts ||= parsed_transcript.filter_map do |line|
      payload = line["payload"]
      next unless payload.is_a?(Hash)

      text =
        if line["type"] == "response_item" && payload["type"] == "message" && payload["role"] == "assistant"
          output_text(payload["content"])
        elsif line["type"] == "event_msg" && payload["type"] == "agent_message"
          payload["message"]
        end

      text if text.is_a?(String) && text.present?
    end
  end

  private

  # Every response_item payload hash in the rollout.
  def response_items
    @response_items ||= parsed_transcript.filter_map do |line|
      next unless line["type"] == "response_item"

      payload = line["payload"]
      payload if payload.is_a?(Hash)
    end
  end

  # Map call_id -> exit_code from `exec_command_end` event_msg lines. These
  # UI-side lines are the only place Codex records a shell's exit status.
  def exit_codes_by_call_id
    parsed_transcript.each_with_object({}) do |line, map|
      next unless line["type"] == "event_msg"

      payload = line["payload"]
      next unless payload.is_a?(Hash) && payload["type"] == "exec_command_end"
      next if payload["call_id"].nil?

      map[payload["call_id"]] = payload["exit_code"]
    end
  end

  # The shell command string for a tool-call payload, or nil when the payload is
  # not a shell invocation. The argv array is joined so patterns can match across
  # tokens.
  def shell_command(payload)
    case payload["type"]
    when "function_call"
      return nil unless payload["name"] == "shell"

      command_to_string(parse_arguments(payload["arguments"])["command"])
    when "local_shell_call"
      action = payload["action"]
      return nil unless action.is_a?(Hash)

      command_to_string(action["command"])
    end
  end

  def command_to_string(command)
    case command
    when String then command
    when Array then command.join(" ")
    end
  end

  # The Codex `function_call` arguments field is a JSON-encoded String.
  def parse_arguments(arguments)
    return {} if arguments.blank?
    return arguments if arguments.is_a?(Hash)

    parsed = JSON.parse(arguments)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # A tool output is either a bare String or an array of content items.
  def output_text(output)
    case output
    when String
      output
    when Array
      output.filter_map { |item| item["text"] if item.is_a?(Hash) }.join("\n")
    else
      ""
    end
  end
end

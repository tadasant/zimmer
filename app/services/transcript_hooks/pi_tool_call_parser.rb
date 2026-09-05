# frozen_string_literal: true

# ToolCallParser for the Pi coding agent's session JSONL.
#
# Pi's shape shares nothing with Claude's or Codex's, so without this class the
# dispatch in TranscriptHooks::ToolCallParser.for would fall through to the
# Claude parser and every hook would silently find nothing on a Pi session — no
# error, no log, just a hook that never fires.
#
# Pi entries are `{"type":"message", "message": <AgentMessage>}`, and the three
# things a hook wants live in three different message roles:
#
#   - a model tool call:  role "assistant", a `toolCall` content block carrying
#     `{id, name, arguments}`
#   - its result:         role "toolResult", carrying `{toolCallId, toolName,
#     content, isError}`
#   - assistant prose:    role "assistant", `text` content blocks
#
# Two Pi-specific details are worth stating, because they are where a naive port
# of the Codex parser would go wrong:
#
#   - **Arguments are a real Hash, not a JSON string.** Codex serializes
#     `function_call.arguments` as a string that must be parsed; Pi stores the
#     object. The shell command is `arguments["command"]`.
#   - **`isError` is recorded on the result itself.** Codex has to correlate a
#     separate `exec_command_end` event by call_id to learn the exit code; Pi
#     states it inline, so there is no second pass and no correlation map.
#
# A user-run `!` command is a `bashExecution` message rather than a tool call.
# It is included in #shell_calls because a hook watching for a command the
# session ran should see it however it was issued, and its synthetic id is
# namespaced so it cannot collide with a model-issued `toolCallId`.
class TranscriptHooks::PiToolCallParser < TranscriptHooks::ToolCallParser
  # Tools whose arguments carry a shell command. Pi's built-in shell tool is
  # `bash`; `powershell` is its Windows counterpart and is matched too so a hook
  # is not silently blind on a Windows host.
  SHELL_TOOL_NAMES = %w[bash powershell].freeze

  # Prefix for the synthetic id given to a user-run `!` command, which has no
  # toolCallId of its own.
  BASH_EXECUTION_ID_PREFIX = "pi-bash-execution"

  def shell_calls
    @shell_calls ||= begin
      calls = []

      each_message do |message, index|
        case message["role"]
        when "assistant"
          tool_call_blocks(message).each do |block|
            next unless SHELL_TOOL_NAMES.include?(block["name"])

            command = block.dig("arguments", "command")
            next if command.blank?
            next if block["id"].blank?

            calls << { id: block["id"], command: command }
          end
        when "bashExecution"
          command = message["command"]
          next if command.blank?

          calls << { id: "#{BASH_EXECUTION_ID_PREFIX}-#{index}", command: command }
        end
      end

      calls
    end
  end

  # Every `toolCall` block, shell and non-shell alike, with its arguments as the
  # Hash Pi already stores.
  #
  # Pi's MCP tools do NOT appear here under their own names: the `pi-mcp-adapter`
  # extension exposes one `mcp` proxy tool that every server is called through
  # (see PiRuntimePromptContribution), so an MCP call is a `toolCall` named `mcp`
  # whose arguments nest the real tool and its arguments. Unwrapping that would
  # mean guessing at a shape nothing here has verified, so it is left alone: a
  # hook keying on `mcp__<server>__<tool>` finds nothing on a Pi session rather
  # than finding something wrong.
  def structured_tool_calls
    @structured_tool_calls ||= begin
      calls = []

      each_message do |message, _index|
        next unless message["role"] == "assistant"

        tool_call_blocks(message).each do |block|
          next unless block["id"].is_a?(String) && block["name"].is_a?(String)

          arguments = block["arguments"]
          calls << { id: block["id"], name: block["name"], input: arguments.is_a?(Hash) ? arguments : {} }
        end
      end

      calls
    end
  end

  def tool_results
    @tool_results ||= begin
      results = []

      each_message do |message, index|
        case message["role"]
        when "toolResult"
          text = content_text(message["content"])
          next if text.blank?
          next if message["toolCallId"].blank?

          results << { id: message["toolCallId"], text: text, is_error: !!message["isError"] }
        when "bashExecution"
          text = message["output"]
          next if text.blank?

          exit_code = message["exitCode"]
          results << {
            id: "#{BASH_EXECUTION_ID_PREFIX}-#{index}",
            text: text,
            is_error: exit_code.present? && exit_code != 0
          }
        end
      end

      results
    end
  end

  def assistant_texts
    @assistant_texts ||= begin
      texts = []

      each_message do |message, _index|
        next unless message["role"] == "assistant"

        text = content_text(message["content"])
        texts << text if text.present?
      end

      texts
    end
  end

  private

  # Yield each `message` entry's AgentMessage along with its index in the
  # transcript. The index is what gives a `bashExecution` its stable synthetic
  # id, and it is taken over the WHOLE transcript (not over messages alone) so a
  # call and its result agree on it.
  def each_message
    parsed_transcript.each_with_index do |line, index|
      next unless line.is_a?(Hash)
      next unless line["type"] == "message"

      message = line["message"]
      next unless message.is_a?(Hash)

      yield message, index
    end
  end

  def tool_call_blocks(message)
    content = message["content"]
    return [] unless content.is_a?(Array)

    content.select { |block| block.is_a?(Hash) && block["type"] == "toolCall" }
  end

  # Pi content is a bare String or an array of typed blocks; only `text` blocks
  # carry prose.
  def content_text(content)
    case content
    when String
      content
    when Array
      content.filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "text" }.join("\n").presence
    end
  end
end

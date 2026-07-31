# frozen_string_literal: true

# Runtime-aware reader for the tool calls and tool results in a parsed transcript.
#
# Claude Code and OpenAI Codex write very different transcript shapes, and any
# hook that needs to correlate "what command ran" with "what that command printed"
# has to know both. GithubPrUrlHook grew that knowledge first; this class is the
# extraction its own comment called for, so GithubCommentAuthorshipHook could ask
# the same questions without a second copy of the shape handling.
#
# Two questions are answered:
#   - #tool_call_ids_matching(pattern) — the ids of shell invocations whose command
#     matches a pattern (Claude tool_use ids / Codex call_ids).
#   - #tool_results — every tool result as { id:, text:, is_error: }.
#
# Shape notes:
#   - Claude Code: tool_use/tool_result blocks; a shell command lives in a Bash
#     tool_use's `input.command`; a result's failure is its own `is_error` flag.
#   - Codex: response_item function_call/local_shell_call (shell argv) and
#     function_call_output (result text); a shell's exit code lives on a separate
#     `exec_command_end` event_msg line, correlated by call_id. The OpenTranscripts
#     normalizer intentionally drops those UI-side event_msg lines, so exit codes
#     are read straight from the rollout rather than from normalized events.
class TranscriptHooks::ToolCallParser
  # @param session [Session] the session whose runtime selects the shape
  # @param parsed_transcript [Array<Hash>] JSONL transcript lines, already parsed
  # @return [TranscriptHooks::ToolCallParser] the parser for the session's runtime
  def self.for(session:, parsed_transcript:)
    klass = session.agent_runtime == "codex" ? TranscriptHooks::CodexToolCallParser : TranscriptHooks::ClaudeToolCallParser
    klass.new(parsed_transcript)
  end

  attr_reader :parsed_transcript

  def initialize(parsed_transcript)
    @parsed_transcript = parsed_transcript
  end

  # Ids of shell invocations whose command matches `pattern`.
  # @param pattern [Regexp]
  # @return [Array<String>]
  def tool_call_ids_matching(pattern)
    shell_calls.filter_map do |call|
      call[:id] if call[:command].present? && call[:command].match?(pattern)
    end
  end

  # Every tool result in the transcript.
  # @return [Array<Hash>] each { id: String, text: String, is_error: Boolean }
  def tool_results
    raise NotImplementedError
  end

  # Every shell invocation in the transcript.
  # @return [Array<Hash>] each { id: String, command: String }
  def shell_calls
    raise NotImplementedError
  end
end

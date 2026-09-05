# frozen_string_literal: true

require "test_helper"

# Without a Pi-shaped parser, TranscriptHooks::ToolCallParser.for would hand a Pi
# session the Claude parser, which matches none of Pi's shapes — so every
# transcript hook would become a silent no-op with no error and no log.
class PiToolCallParserTest < ActiveSupport::TestCase
  setup do
    @transcript = PiTranscriptSource.new.parse_events(file_fixture("pi_session.jsonl").read)
    @session = Session.new(agent_runtime: "pi")
  end

  test "the dispatcher picks the Pi parser for a Pi session" do
    parser = TranscriptHooks::ToolCallParser.for(session: @session, parsed_transcript: @transcript)

    assert_instance_of TranscriptHooks::PiToolCallParser, parser
  end

  test "the dispatcher still picks Claude and Codex for their own runtimes" do
    assert_instance_of TranscriptHooks::ClaudeToolCallParser,
      TranscriptHooks::ToolCallParser.for(session: Session.new(agent_runtime: "claude_code"), parsed_transcript: [])
    assert_instance_of TranscriptHooks::CodexToolCallParser,
      TranscriptHooks::ToolCallParser.for(session: Session.new(agent_runtime: "codex"), parsed_transcript: [])
    # A blank runtime is Claude Code, matching RuntimeRegistry::DEFAULT_RUNTIME.
    assert_instance_of TranscriptHooks::ClaudeToolCallParser,
      TranscriptHooks::ToolCallParser.for(session: Session.new(agent_runtime: nil), parsed_transcript: [])
  end

  # Against the transcript captured from the real Pi binary.
  test "extracts the model's shell call from a real Pi transcript" do
    calls = parser.shell_calls

    assert_equal 1, calls.length
    assert_equal "call_sim_1", calls.first[:id]
    assert_equal "echo ZIMMER-PI-TOOL-OK", calls.first[:command]
  end

  test "extracts the tool result, with isError read inline" do
    results = parser.tool_results

    assert_equal 1, results.length
    assert_equal "call_sim_1", results.first[:id]
    assert_equal "ZIMMER-PI-TOOL-OK\n", results.first[:text]
    assert_not results.first[:is_error]
  end

  test "extracts assistant prose" do
    assert_equal [ "Ran the command. ZIMMER-PI-DONE" ], parser.assistant_texts
  end

  test "tool_call_ids_matching finds a command by pattern" do
    assert_equal [ "call_sim_1" ], parser.tool_call_ids_matching(/ZIMMER-PI-TOOL-OK/)
    assert_equal [], parser.tool_call_ids_matching(/nothing-like-this/)
  end

  # Pi stores tool arguments as a real Hash. Codex serializes them as a JSON
  # string; porting that assumption here would find nothing.
  test "arguments are read as a Hash, not parsed from a string" do
    calls = build_parser([ assistant_tool_call("git status") ]).shell_calls

    assert_equal "git status", calls.first[:command]
  end

  test "a non-shell tool call is not reported as a shell call" do
    entry = assistant_tool_call("ignored")
    entry["message"]["content"][0]["name"] = "read"

    assert_equal [], build_parser([ entry ]).shell_calls
  end

  # A user-run `!` command is a bashExecution, not a tool call, but a hook
  # watching for a command the session ran should still see it.
  test "a user-run bash execution is reported as a shell call and a result" do
    entry = {
      "type" => "message", "id" => "aa11", "message" => {
        "role" => "bashExecution", "command" => "ls -la", "output" => "total 0", "exitCode" => 0
      }
    }
    p = build_parser([ entry ])

    assert_equal [ "ls -la" ], p.shell_calls.map { |c| c[:command] }
    assert_equal [ "total 0" ], p.tool_results.map { |r| r[:text] }
    # The synthetic id ties the call to its result and cannot collide with a
    # model-issued toolCallId.
    assert_equal p.shell_calls.first[:id], p.tool_results.first[:id]
    assert p.shell_calls.first[:id].start_with?(TranscriptHooks::PiToolCallParser::BASH_EXECUTION_ID_PREFIX)
    assert_not p.tool_results.first[:is_error]
  end

  test "a failed bash execution is marked as an error" do
    entry = {
      "type" => "message", "id" => "bb22", "message" => {
        "role" => "bashExecution", "command" => "false", "output" => "boom", "exitCode" => 1
      }
    }

    assert build_parser([ entry ]).tool_results.first[:is_error]
  end

  test "an errored tool result carries isError through" do
    entry = {
      "type" => "message", "id" => "cc33", "message" => {
        "role" => "toolResult", "toolCallId" => "call_x", "toolName" => "bash",
        "content" => [ { "type" => "text", "text" => "permission denied" } ], "isError" => true
      }
    }

    assert build_parser([ entry ]).tool_results.first[:is_error]
  end

  test "tolerates a transcript with nothing in it" do
    p = build_parser([])

    assert_equal [], p.shell_calls
    assert_equal [], p.tool_results
    assert_equal [], p.assistant_texts
    assert_equal [], p.structured_tool_calls
  end

  # #structured_tool_calls is how a hook sees a tool call that is not a shell
  # command — GithubPrUrlHook reads an MCP `create_pull_request` through it.
  test "structured_tool_calls reports every tool call with its arguments as a Hash" do
    entry = assistant_tool_call("git status")

    assert_equal [ { id: "call_1", name: "bash", input: { "command" => "git status" } } ],
      build_parser([ entry ]).structured_tool_calls
  end

  test "structured_tool_calls reports a non-shell tool call that shell_calls skips" do
    entry = assistant_tool_call("ignored")
    entry["message"]["content"][0]["name"] = "read"
    entry["message"]["content"][0]["arguments"] = { "path" => "README.md" }
    p = build_parser([ entry ])

    assert_equal [], p.shell_calls
    assert_equal [ { id: "call_1", name: "read", input: { "path" => "README.md" } } ], p.structured_tool_calls
  end

  # Pi's MCP tools are called through the `pi-mcp-adapter` extension's single
  # `mcp` proxy tool rather than under their own names, so a Pi transcript
  # carries no `mcp__<server>__<tool>` for a hook to key on. It is reported as
  # what it is — a call to `mcp` — rather than unwrapped into a shape nothing
  # here has verified.
  test "structured_tool_calls reports an MCP proxy call as the proxy tool, not the tool inside it" do
    entry = {
      "type" => "message", "id" => "ee55", "message" => {
        "role" => "assistant",
        "content" => [ {
          "type" => "toolCall", "id" => "call_mcp", "name" => "mcp",
          "arguments" => { "tool" => "create_pull_request", "args" => { "owner" => "owner", "repo" => "repo" } }
        } ]
      }
    }

    assert_equal [ "mcp" ], build_parser([ entry ]).structured_tool_calls.map { |call| call[:name] }
  end

  private

  def parser
    @parser ||= TranscriptHooks::PiToolCallParser.new(@transcript)
  end

  def build_parser(entries)
    TranscriptHooks::PiToolCallParser.new(entries)
  end

  def assistant_tool_call(command)
    {
      "type" => "message", "id" => "dd44", "message" => {
        "role" => "assistant",
        "content" => [ {
          "type" => "toolCall", "id" => "call_1", "name" => "bash",
          "arguments" => { "command" => command }
        } ]
      }
    }
  end
end

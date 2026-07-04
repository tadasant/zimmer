require "test_helper"

class TranscriptHooks::GithubPrUrlHookTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @session.update!(custom_metadata: {}, git_root: "https://github.com/owner/repo.git")
  end

  test "extracts PR URL from tool result content when repo matches" do
    # Tool result format as seen from gh pr create output
    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/123" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "extracts PR URL from tool result with surrounding text" do
    # gh pr create output sometimes has the URL with surrounding info
    @session.update!(git_root: "https://github.com/anthropics/claude.git")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"Creating pull request...\\nhttps://github.com/anthropics/claude/pull/456\\nDone!","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/anthropics/claude/pull/456" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "ignores PR URLs in assistant text content (not tool results)" do
    # This simulates an assistant referencing another PR - should NOT be extracted
    transcript = <<~JSONL
      {"type":"user","message":{"content":"Create a PR please"}}
      {"type":"assistant","message":{"content":"I've looked at https://github.com/owner/repo/pull/999 for reference. Now creating your PR..."}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "appends new URL when PR URLs already exist" do
    @session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/1" ] })

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/999","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/1", "https://github.com/owner/repo/pull/999" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "does not duplicate existing PR URL" do
    @session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/123" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "does not update if no PR URL found in tool results" do
    transcript = <<~JSONL
      {"type":"user","message":{"content":"Hello"}}
      {"type":"assistant","message":{"content":"Hi there!"}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"File created successfully","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "handles various PR URL formats in tool results" do
    test_cases = [
      { git_root: "https://github.com/owner/repo.git", pr_url: "https://github.com/owner/repo/pull/1" },
      { git_root: "https://github.com/my-org/my-repo.git", pr_url: "https://github.com/my-org/my-repo/pull/12345" },
      { git_root: "https://github.com/user123/project_name.git", pr_url: "https://github.com/user123/project_name/pull/999" }
    ]

    test_cases.each do |tc|
      @session.update!(custom_metadata: {}, git_root: tc[:git_root])

      transcript = %({"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"#{tc[:pr_url]}","is_error":false}]}})

      hook = TranscriptHooks::GithubPrUrlHook.new(
        session: @session,
        transcript_content: transcript,
        new_messages: []
      )

      hook.call

      @session.reload
      assert_equal [ tc[:pr_url] ], @session.custom_metadata["github_pull_request_urls"], "Failed for URL: #{tc[:pr_url]}"
    end
  end

  test "extracts all matching PR URLs when multiple tool results exist" do
    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"https://github.com/owner/repo/pull/1","is_error":false}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_2","type":"tool_result","content":"https://github.com/owner/repo/pull/2","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/1", "https://github.com/owner/repo/pull/2" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "handles empty transcript" do
    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: "",
      new_messages: []
    )

    # Should not raise an error
    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "ignores non-GitHub PR URLs in tool results" do
    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://gitlab.com/owner/repo/merge_requests/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "extracts PR URL even from tool result errors" do
    # Tool result that failed - still should extract if URL is present
    # (e.g., PR was created but something else failed)
    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":true}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    # Should still extract even from error results - the PR URL is still valid
    assert_equal [ "https://github.com/owner/repo/pull/123" ], @session.custom_metadata["github_pull_request_urls"]
  end

  # === New tests for repository matching ===

  test "ignores PR URLs from different repositories" do
    # Session is working on owner/repo but transcript contains PR from different/repo
    @session.update!(git_root: "https://github.com/tadasant/zimmer-catalog.git")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"Found reference: https://github.com/heartcombo/devise/pull/5728","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "extracts only matching PR URL when multiple PRs from different repos exist" do
    @session.update!(git_root: "https://github.com/owner/repo.git")

    # Multiple PR URLs - only the one matching the session's repo should be extracted
    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"Reference: https://github.com/other/project/pull/100\\nCreated: https://github.com/owner/repo/pull/42\\nAlso see: https://github.com/another/library/pull/999","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/42" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "returns nil when git_root is not a GitHub URL" do
    @session.update!(git_root: "/path/to/local/repo")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "returns nil when git_root is a GitLab URL" do
    @session.update!(git_root: "https://gitlab.com/owner/repo.git")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "handles SSH git URL format" do
    @session.update!(git_root: "git@github.com:anthropics/claude-code.git")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/anthropics/claude-code/pull/789","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/anthropics/claude-code/pull/789" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "handles SSH git URL format without .git extension" do
    @session.update!(git_root: "git@github.com:owner/repo")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/123" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "handles HTTPS URL without .git extension" do
    @session.update!(git_root: "https://github.com/owner/repo")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/123" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "matching is case-insensitive" do
    @session.update!(git_root: "https://github.com/Owner/Repo.git")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/123" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "returns nil when git_root is blank" do
    @session.update_column(:git_root, "")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  # === Tests for tracking timestamp ===

  test "stores tracking timestamp when PR URL is first added" do
    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    freeze_time do
      hook = TranscriptHooks::GithubPrUrlHook.new(
        session: @session,
        transcript_content: transcript,
        new_messages: []
      )

      hook.call

      @session.reload
      timestamps = @session.custom_metadata["github_pr_tracking_started_at"]
      assert_not_nil timestamps
      assert_equal Time.current.iso8601, timestamps["https://github.com/owner/repo/pull/123"]
    end
  end

  test "does not overwrite existing tracking timestamp for same PR URL" do
    original_time = "2025-01-01T12:00:00Z"
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pr_tracking_started_at" => { "https://github.com/owner/repo/pull/123" => original_time }
    })

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/123","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    timestamps = @session.custom_metadata["github_pr_tracking_started_at"]
    # Should preserve the original timestamp
    assert_equal original_time, timestamps["https://github.com/owner/repo/pull/123"]
  end

  # === Cross-repo PRs created via `gh pr create` ===

  test "extracts cross-repo PR URL when opened via gh pr create" do
    # Session works on owner/repo, agent opens a PR on a totally different repo via `gh pr create`
    @session.update!(git_root: "https://github.com/tadasant/zimmer-catalog.git")

    transcript = <<~JSONL
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_create_1","name":"Bash","input":{"command":"cd ~/work/fork && gh pr create --draft --repo modelcontextprotocol/modelcontextprotocol --base main --head fork:branch --title \\"Test\\" --body \\"...\\""}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_create_1","type":"tool_result","content":"https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2652\\nShell cwd was reset","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2652" ],
      @session.custom_metadata["github_pull_request_urls"]
  end

  test "extracts both same-repo and cross-repo PR URLs when both present" do
    @session.update!(git_root: "https://github.com/owner/repo.git")

    transcript = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_view_1","type":"tool_result","content":"Existing PR: https://github.com/owner/repo/pull/1","is_error":false}]}}
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_create_1","name":"Bash","input":{"command":"gh pr create --repo other/proj --base main --head fork:b --title T --body B"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_create_1","type":"tool_result","content":"https://github.com/other/proj/pull/99","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/1", "https://github.com/other/proj/pull/99" ],
      @session.custom_metadata["github_pull_request_urls"]
  end

  test "still ignores cross-repo PR URLs that did NOT come from gh pr create" do
    # `gh pr view` of an unrelated PR — should NOT be tracked
    @session.update!(git_root: "https://github.com/owner/repo.git")

    transcript = <<~JSONL
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_view_1","name":"Bash","input":{"command":"gh pr view 5728 --repo heartcombo/devise"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_view_1","type":"tool_result","content":"https://github.com/heartcombo/devise/pull/5728\\ntitle: ...","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "extracts cross-repo gh pr create PR even when git_root is non-GitHub" do
    # Session on a GitLab repo — same-repo path is unavailable, but `gh pr create`
    # should still get its PR tracked.
    @session.update!(git_root: "https://gitlab.com/group/proj.git")

    transcript = <<~JSONL
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_create_1","name":"Bash","input":{"command":"gh pr create --repo other/proj --base main --head fork:b --title T --body B"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_create_1","type":"tool_result","content":"https://github.com/other/proj/pull/42","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/other/proj/pull/42" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "ignores cross-repo PR URL when gh pr create tool_result is an error" do
    # `gh pr create` can fail (auth, branch already has a PR, etc.) and the
    # error output may still contain a PR URL. We must not attribute that
    # PR to this session.
    @session.update!(git_root: "https://github.com/tadasant/zimmer-catalog.git")

    transcript = <<~JSONL
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_create_fail","name":"Bash","input":{"command":"gh pr create --repo other/proj --base main --head fork:b --title T --body B"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_create_fail","type":"tool_result","content":"a pull request for branch \\"fork:b\\" into branch \\"main\\" already exists:\\nhttps://github.com/other/proj/pull/55","is_error":true}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "stores tracking timestamp for cross-repo PR opened via gh pr create" do
    @session.update!(git_root: "https://github.com/tadasant/zimmer-catalog.git")

    transcript = <<~JSONL
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_create_1","name":"Bash","input":{"command":"gh pr create --repo other/proj"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_create_1","type":"tool_result","content":"https://github.com/other/proj/pull/7","is_error":false}]}}
    JSONL

    freeze_time do
      hook = TranscriptHooks::GithubPrUrlHook.new(
        session: @session,
        transcript_content: transcript,
        new_messages: []
      )

      hook.call

      @session.reload
      timestamps = @session.custom_metadata["github_pr_tracking_started_at"]
      assert_not_nil timestamps
      assert_equal Time.current.iso8601, timestamps["https://github.com/other/proj/pull/7"]
    end
  end

  test "stores separate timestamps for each PR URL" do
    # First PR
    transcript1 = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/owner/repo/pull/1","is_error":false}]}}
    JSONL

    first_time = Time.utc(2025, 1, 15, 10, 0, 0)
    travel_to(first_time) do
      hook = TranscriptHooks::GithubPrUrlHook.new(
        session: @session,
        transcript_content: transcript1,
        new_messages: []
      )
      hook.call
    end

    # Second PR (added later)
    transcript2 = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_456","type":"tool_result","content":"https://github.com/owner/repo/pull/2","is_error":false}]}}
    JSONL

    second_time = Time.utc(2025, 1, 15, 11, 0, 0)
    travel_to(second_time) do
      @session.reload
      hook = TranscriptHooks::GithubPrUrlHook.new(
        session: @session,
        transcript_content: transcript2,
        new_messages: []
      )
      hook.call
    end

    @session.reload
    timestamps = @session.custom_metadata["github_pr_tracking_started_at"]

    assert_equal first_time.iso8601, timestamps["https://github.com/owner/repo/pull/1"]
    assert_equal second_time.iso8601, timestamps["https://github.com/owner/repo/pull/2"]
  end

  # === Codex runtime transcript shape ===
  #
  # Codex rollouts use a different schema than Claude: each line is
  # {timestamp, type, payload}. A shell call is a response_item with
  # payload.type "function_call" (name "shell", JSON-encoded arguments holding a
  # command argv) or "local_shell_call" (argv under action.command). The shell's
  # exit code lives on a separate event_msg line (exec_command_end), correlated
  # by call_id, and the command output is a response_item function_call_output
  # whose `output` is plain text. These helpers build those lines so the fixtures
  # mirror a real Codex rollout (the shape session 7273 produced when it opened
  # PR #4050 without being associated).

  TS = "2026-06-04T00:00:00.000Z"

  def codex_shell_call(call_id:, command:, name: "shell")
    {
      timestamp: TS,
      type: "response_item",
      payload: {
        type: "function_call",
        name: name,
        arguments: { command: command }.to_json,
        call_id: call_id
      }
    }.to_json
  end

  def codex_local_shell_call(call_id:, command:)
    {
      timestamp: TS,
      type: "response_item",
      payload: {
        type: "local_shell_call",
        call_id: call_id,
        action: { type: "exec", command: command }
      }
    }.to_json
  end

  def codex_exec_end(call_id:, exit_code:)
    {
      timestamp: TS,
      type: "event_msg",
      payload: {
        type: "exec_command_end",
        call_id: call_id,
        exit_code: exit_code,
        stdout: "",
        stderr: "",
        aggregated_output: "",
        duration: 1.0
      }
    }.to_json
  end

  def codex_output(call_id:, output:)
    {
      timestamp: TS,
      type: "response_item",
      payload: {
        type: "function_call_output",
        call_id: call_id,
        output: output
      }
    }.to_json
  end

  test "codex: extracts same-repo PR URL from gh pr create output" do
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/owner/repo.git")

    transcript = [
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --base main --head branch --title T --body B" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/4050\n")
    ].join("\n")

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/4050" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "codex: extracts cross-repo PR URL opened via gh pr create" do
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/tadasant/zimmer-catalog.git")

    transcript = [
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "cd ~/fork && gh pr create --repo other/proj --base main --head fork:b --title T --body B" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/other/proj/pull/99\nShell cwd was reset")
    ].join("\n")

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/other/proj/pull/99" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "codex: extracts PR URL from local_shell_call argv variant" do
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/owner/repo.git")

    transcript = [
      codex_local_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/7")
    ].join("\n")

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/7" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "codex: ignores cross-repo PR URL from gh pr view (not gh pr create)" do
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/owner/repo.git")

    transcript = [
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr view 5728 --repo heartcombo/devise" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/heartcombo/devise/pull/5728\ntitle: ...")
    ].join("\n")

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "codex: ignores cross-repo PR URL when gh pr create exits non-zero" do
    # A failed `gh pr create` (e.g. branch already has a PR) can still emit a PR
    # URL in its output. The exit code lives on the exec_command_end line; a
    # non-zero code must keep the URL from being attributed to this session.
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/tadasant/zimmer-catalog.git")

    transcript = [
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --repo other/proj --base main --head fork:b --title T --body B" ]),
      codex_exec_end(call_id: "call_1", exit_code: 1),
      codex_output(call_id: "call_1", output: "a pull request for branch \"fork:b\" into branch \"main\" already exists:\nhttps://github.com/other/proj/pull/55")
    ].join("\n")

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "codex: stores tracking timestamp for PR opened via gh pr create" do
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/owner/repo.git")

    transcript = [
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/4050")
    ].join("\n")

    freeze_time do
      hook = TranscriptHooks::GithubPrUrlHook.new(
        session: @session,
        transcript_content: transcript,
        new_messages: []
      )

      hook.call

      @session.reload
      timestamps = @session.custom_metadata["github_pr_tracking_started_at"]
      assert_not_nil timestamps
      assert_equal Time.current.iso8601, timestamps["https://github.com/owner/repo/pull/4050"]
    end
  end

  test "codex: associates cross-repo gh pr create PR when no exec_command_end line exists" do
    # The shell's exit code lives on a separate exec_command_end event_msg line.
    # If that UI-side line is absent (dropped/not emitted), a successful
    # gh pr create must still be associated — a missing exit code is treated as
    # success, never as an error. This guards the feature's central assumption.
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/tadasant/zimmer-catalog.git")

    transcript = [
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --repo other/proj --fill" ]),
      codex_output(call_id: "call_1", output: "https://github.com/other/proj/pull/321")
    ].join("\n")

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/other/proj/pull/321" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "codex: ignores gh pr create text inside a non-shell function_call" do
    # Only function_call payloads named "shell" are shell invocations. A
    # different tool (e.g. apply_patch) whose arguments happen to contain the
    # literal "gh pr create" must not be treated as a PR-creating command.
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/owner/repo.git")

    non_shell = {
      timestamp: TS,
      type: "response_item",
      payload: {
        type: "function_call",
        name: "apply_patch",
        arguments: { input: "patch that mentions gh pr create in a comment" }.to_json,
        call_id: "call_1"
      }
    }.to_json

    transcript = [
      non_shell,
      codex_output(call_id: "call_1", output: "patched; see https://github.com/other/proj/pull/77")
    ].join("\n")

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    # other/proj is cross-repo and the call was not a `gh pr create` shell, so
    # the URL must not be associated.
    assert_nil @session.custom_metadata["github_pull_request_urls"]
  end

  test "codex: extracts PR URL from custom_tool_call_output with array-shaped output" do
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/owner/repo.git")

    custom_output = {
      timestamp: TS,
      type: "response_item",
      payload: {
        type: "custom_tool_call_output",
        call_id: "call_1",
        output: [ { type: "text", text: "https://github.com/owner/repo/pull/88" } ]
      }
    }.to_json

    transcript = [
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      custom_output
    ].join("\n")

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/88" ], @session.custom_metadata["github_pull_request_urls"]
  end

  test "codex: same-repo PR URL is tracked even when gh pr create exits non-zero" do
    # git_root is a strong signal: a same-repo PR is attributed regardless of the
    # exit code (mirrors the Claude same-repo behavior).
    @session.update!(agent_runtime: "codex", git_root: "https://github.com/owner/repo.git")

    transcript = [
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 1),
      codex_output(call_id: "call_1", output: "a pull request for branch already exists:\nhttps://github.com/owner/repo/pull/123")
    ].join("\n")

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/123" ], @session.custom_metadata["github_pull_request_urls"]
  end
end

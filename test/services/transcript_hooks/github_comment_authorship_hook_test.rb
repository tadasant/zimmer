require "test_helper"

class TranscriptHooks::GithubCommentAuthorshipHookTest < ActiveSupport::TestCase
  # The production shape: `gh pr comment` prints the comment permalink and nothing
  # else. This is the exact comment from the reported loop.
  POSTED_URL = "https://github.com/tadasant/tadasant-internal/pull/281#issuecomment-5145406778".freeze

  setup do
    @session = sessions(:running)
    @session.update!(agent_runtime: "claude_code")
  end

  def run_hook(transcript)
    TranscriptHooks::GithubCommentAuthorshipHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: []
    ).call
  end

  def claude_transcript(command:, output:, is_error: false)
    <<~JSONL
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":#{command.to_json}}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":#{output.to_json},"is_error":#{is_error}}]}}
    JSONL
  end

  test "records the comment id printed by gh pr comment" do
    run_hook(claude_transcript(command: "gh pr comment 281 --repo tadasant/tadasant-internal --body 'done'", output: POSTED_URL))

    record = AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
    assert_not_nil record, "the comment the session just posted must be recorded"
    assert_equal @session.id, record.session_id
    assert_equal POSTED_URL, record.comment_url
    assert_equal "https://github.com/tadasant/tadasant-internal/pull/281", record.pr_url
  end

  test "records an inline review reply posted through gh api" do
    output = { "id" => 999, "html_url" => "https://github.com/owner/repo/pull/7#discussion_r999" }.to_json
    command = "gh api repos/owner/repo/pulls/7/comments -f body='[CC Says] ok' -f in_reply_to=5"

    run_hook(claude_transcript(command: command, output: output))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "review", comment_id: 999)
  end

  test "records a comment posted through gh pr review" do
    output = "https://github.com/owner/repo/pull/7#issuecomment-4242"

    run_hook(claude_transcript(command: "gh pr review 7 --comment --body 'looks good'", output: output))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 4242)
  end

  test "does NOT record a comment the agent merely read" do
    # Verifying a comment's provenance — which is what the session in the reported
    # loop did — returns that comment's own html_url. Treating that as a post would
    # suppress a human comment nobody posted from Zimmer.
    output = { "id" => 5145406778, "html_url" => POSTED_URL, "user" => { "login" => "tadasant" } }.to_json
    command = "gh api repos/tadasant/tadasant-internal/issues/comments/5145406778"

    run_hook(claude_transcript(command: command, output: output))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "does NOT record when the posting command failed" do
    run_hook(claude_transcript(
      command: "gh pr comment 281 --repo tadasant/tadasant-internal --body 'done'",
      output: "could not create comment: HTTP 403\n#{POSTED_URL}",
      is_error: true
    ))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "does NOT record a lookalike host" do
    run_hook(claude_transcript(
      command: "gh pr comment 1 --body hi",
      output: "https://github.com.evil.example/owner/repo/pull/1#issuecomment-777"
    ))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 777)
  end

  test "is idempotent across repeated polls of the same transcript" do
    transcript = claude_transcript(command: "gh pr comment 281 --body done", output: POSTED_URL)

    run_hook(transcript)
    assert_no_difference "AgentPostedGithubComment.count" do
      run_hook(transcript)
      run_hook(transcript)
    end
  end

  test "records every comment across several posting calls" do
    transcript = <<~JSONL
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"gh pr comment 1 --body a"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"https://github.com/owner/repo/pull/1#issuecomment-111","is_error":false}]}}
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"gh pr comment 1 --body b"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_2","type":"tool_result","content":"https://github.com/owner/repo/pull/1#issuecomment-222","is_error":false}]}}
    JSONL

    run_hook(transcript)

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 111)
    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 222)
  end

  test "does nothing when no comment was posted" do
    assert_no_difference "AgentPostedGithubComment.count" do
      run_hook(claude_transcript(command: "git status", output: "nothing to commit"))
    end
  end

  test "handles a Codex rollout" do
    @session.update!(agent_runtime: "codex")

    transcript = <<~JSONL
      {"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"call_1","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"gh pr comment 281 --body done\\"]}"}}
      {"type":"event_msg","payload":{"type":"exec_command_end","call_id":"call_1","exit_code":0}}
      {"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"#{POSTED_URL}"}}
    JSONL

    run_hook(transcript)

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "does NOT record a failed Codex shell call" do
    @session.update!(agent_runtime: "codex")

    transcript = <<~JSONL
      {"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"call_1","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"gh pr comment 281 --body done\\"]}"}}
      {"type":"event_msg","payload":{"type":"exec_command_end","call_id":"call_1","exit_code":1}}
      {"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"failed: #{POSTED_URL}"}}
    JSONL

    run_hook(transcript)

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end
end

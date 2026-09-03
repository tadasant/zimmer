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
  # --- False positives that would silence a human ----------------------------
  #
  # Over-recording is the dangerous direction: a wrongly recorded id suppresses that
  # comment for every session, permanently, with only a log line to show for it.

  test "does NOT record a comments READ that shares a command line with an unrelated -f flag" do
    # `rm -f`, `git push -f`, `grep -f` are everywhere in agent one-liners. Matching the
    # write flag across the whole line would turn this read of a whole thread into a
    # "post" and record every comment in it — including the human's.
    output = [
      { "id" => 5145406778, "html_url" => POSTED_URL, "user" => { "login" => "tadasant" } },
      { "id" => 999, "html_url" => "https://github.com/tadasant/tadasant-internal/pull/281#issuecomment-999" }
    ].to_json
    command = "gh api repos/tadasant/tadasant-internal/issues/281/comments --paginate && rm -f /tmp/old.json"

    run_hook(claude_transcript(command: command, output: output))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 999)
  end

  test "does NOT record a comments read piped into grep -f" do
    output = { "id" => 5145406778, "html_url" => POSTED_URL }.to_json

    run_hook(claude_transcript(
      command: "gh api repos/o/r/pulls/7/comments --jq . | grep -f /tmp/patterns",
      output: output
    ))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "does NOT record a comment quoted in the body of the comment it posts" do
    # GithubCommentPromptBuilder hands the agent the human's permalink under
    # "Comment URL" and tells it to reply with `gh api ... -f body=...`. The API
    # echoes the created comment INCLUDING its body, so a reply that quotes the
    # human's link must not register that link as agent-posted.
    output = {
      "id" => 4242,
      "html_url" => "https://github.com/tadasant/tadasant-internal/pull/281#discussion_r4242",
      "body" => "[CC Says] Replying to #{POSTED_URL} — fixed in abc123."
    }.to_json
    command = "gh api repos/tadasant/tadasant-internal/pulls/281/comments -f body='[CC Says] ...' -f in_reply_to=5"

    run_hook(claude_transcript(command: command, output: output))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "review", comment_id: 4242),
      "the comment it actually created is still recorded"
    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778),
      "the comment merely quoted in the body must not be suppressed"
  end

  test "does NOT record a non-comments gh api write that mentions comments" do
    run_hook(claude_transcript(
      command: "gh api graphql -f query=@q.graphql   # fetch comments urls",
      output: POSTED_URL
    ))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "records a gh api post written with --method=POST" do
    output = { "id" => 7777, "html_url" => "https://github.com/o/r/pull/7#issuecomment-7777" }.to_json

    run_hook(claude_transcript(
      command: "gh api --method=POST repos/o/r/issues/7/comments -f body=hi",
      output: output
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 7777)
  end

  test "records a post whose gh api call is one segment of a compound command" do
    output = { "id" => 8888, "html_url" => "https://github.com/o/r/pull/7#issuecomment-8888" }.to_json

    run_hook(claude_transcript(
      command: "cd /app && gh api repos/o/r/issues/7/comments -f body='done'",
      output: output
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 8888)
  end

  test "records a gh api post behind the bash -lc wrapper a Codex argv joins into" do
    # Codex records a shell call as an argv array the parser joins back into one
    # string, so `gh api` is never at the front of the command it ran.
    output = { "id" => 9999, "html_url" => "https://github.com/o/r/pull/7#issuecomment-9999" }.to_json

    run_hook(claude_transcript(
      command: "bash -lc gh api repos/o/r/issues/7/comments -f body=hi",
      output: output
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 9999)
  end

  test "records a gh api post inside a quoted shell wrapper" do
    # The same wrapper with its script quoted. What a shell is handed is more
    # commands, so the `cd` in front of the post does not hide it.
    output = { "id" => 9998, "html_url" => "https://github.com/o/r/pull/7#issuecomment-9998" }.to_json

    run_hook(claude_transcript(
      command: %q(bash -lc "cd /repo && gh api repos/o/r/issues/7/comments -f body=hi"),
      output: output
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 9998)
  end

  test "does NOT record a comments READ inside a quoted shell wrapper that also runs rm -f" do
    # The unrelated-`-f` case, wrapped. Reading the wrapped script as one command
    # lets `rm -f` supply the write flag and records the whole thread — the human's
    # comment included, permanently and fleet-wide.
    output = [
      { "id" => 5145406778, "html_url" => POSTED_URL, "user" => { "login" => "tadasant" } }
    ].to_json

    run_hook(claude_transcript(
      command: %q(bash -lc "gh api repos/tadasant/tadasant-internal/issues/281/comments --paginate && rm -f /tmp/x"),
      output: output
    ))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "records a gh api post whose output the command captures" do
    output = { "id" => 10101, "html_url" => "https://github.com/o/r/pull/7#issuecomment-10101" }.to_json

    run_hook(claude_transcript(
      command: "out=$(gh api repos/o/r/issues/7/comments -f body=hi)",
      output: output
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 10101)
  end

  test "reads a tool result whose content is an array of text blocks" do
    transcript = <<~JSONL
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"gh pr comment 281 --body done"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":[{"type":"text","text":"#{POSTED_URL}"}],"is_error":false}]}}
    JSONL

    run_hook(transcript)

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end
end

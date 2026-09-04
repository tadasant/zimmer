require "test_helper"

class TranscriptHooks::GithubCommentAuthorshipHookTest < ActiveSupport::TestCase
  # The production shape: `gh pr comment` prints the comment permalink and nothing
  # else. This is the exact comment from the reported loop.
  POSTED_URL = "https://github.com/tadasant/tadasant-internal/pull/281#issuecomment-5145406778".freeze

  # A thread with one comment from each side, for the calls that post and read in the
  # same breath (#901).
  AGENT_COMMENT_URL = "https://github.com/tadasant/tadasant-internal/pull/281#issuecomment-100".freeze
  HUMAN_COMMENT_URL = "https://github.com/tadasant/tadasant-internal/pull/281#issuecomment-50".freeze

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

  # --- Quoted mentions: the literal handed to another command as data ---------
  #
  # #870. A read-only command that merely names a posting command is not one, and
  # reading it as one records every permalink in its output — over this repo's own
  # source and docs, which quote both the literals and example permalinks.

  test "does NOT record a permalink grepped out of the repo for the gh pr comment literal" do
    # Session 11898's shape (#772) pointed at this hook: a grep for the literal over
    # a file whose comments carry an example permalink.
    output = <<~OUT
      app/services/transcript_hooks/github_comment_authorship_hook.rb:44:  #   gh pr comment / gh issue comment
      docs/src/content/docs/limitations.md:2637:`gh pr comment` prints #{POSTED_URL}
    OUT

    run_hook(claude_transcript(command: %q(grep -rn "gh pr comment" app/ docs/), output: output))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778),
      "a grep for the literal is a read, and its output is somebody else's comment"
  end

  test "does NOT record a permalink from rg for the gh pr review literal" do
    output = "app/services/transcript_hooks/github_comment_authorship_hook.rb:46:  # gh pr review — see #{POSTED_URL}"

    run_hook(claude_transcript(command: %q(rg "gh pr review" app/), output: output))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "does NOT record a permalink printed by an echo that quotes gh issue comment" do
    run_hook(claude_transcript(
      command: "echo \"gh issue comment posts to #{POSTED_URL}\"",
      output: POSTED_URL
    ))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "does NOT record a comments READ whose own jq filter quotes a write flag" do
    # The write flag inside the segment's own quoted argument, where segmentation
    # cannot help: there is only one command. Read off the raw segment, this list of
    # a whole thread is a post, and every comment in it — the human's included — is
    # suppressed fleet-wide.
    output = [
      { "id" => 5145406778, "html_url" => POSTED_URL, "user" => { "login" => "tadasant" } }
    ].to_json

    run_hook(claude_transcript(
      command: %q{gh api repos/tadasant/tadasant-internal/issues/281/comments --paginate --jq 'map(select(.body | test("rm -f ")))'},
      output: output
    ))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "does NOT record a comments READ written as an explicit GET with query fields" do
    # `gh api -X GET <path> -f per_page=100` is gh's own idiom for a GET with query
    # parameters. Reading the field flag as the write would record the whole thread
    # this lists — the human's comments included.
    output = [
      { "id" => 5145406778, "html_url" => POSTED_URL, "user" => { "login" => "tadasant" } }
    ].to_json

    run_hook(claude_transcript(
      command: "gh api -X GET repos/tadasant/tadasant-internal/issues/281/comments -f per_page=100",
      output: output
    ))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  # --- The other direction: a real post must still be seen -------------------
  #
  # A lost recording is the self-reply loop this hook exists to break, so every
  # shape a post arrives in stays covered.

  test "records a gh pr comment run behind a timeout prefix" do
    run_hook(claude_transcript(command: "timeout 120 gh pr comment 281 --body 'done'", output: POSTED_URL))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "records a gh pr comment retried inside an until loop" do
    run_hook(claude_transcript(
      command: "until gh pr comment 281 --body 'done'; do sleep 5; done",
      output: POSTED_URL
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "records a gh pr comment inside a quoted shell wrapper" do
    run_hook(claude_transcript(
      command: %q(bash -lc "cd /repo && gh pr comment 281 --body 'done'"),
      output: POSTED_URL
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "records a gh pr review whose body quotes the literal it is talking about" do
    # The body is data and the invocation is not, in the same segment.
    run_hook(claude_transcript(
      command: %q(gh pr review 281 --comment --body "use gh pr comment next time"),
      output: POSTED_URL
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  test "records a gh api post whose method flag is quoted" do
    # The quoted method is blanked out of the view the flags are read from, so the
    # field flag is what carries the write — which is the same answer.
    output = { "id" => 13131, "html_url" => "https://github.com/o/r/pull/7#issuecomment-13131" }.to_json

    run_hook(claude_transcript(
      command: %q(gh api repos/o/r/issues/7/comments -X "POST" -f body='done'),
      output: output
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 13131)
  end

  test "records a gh api post whose endpoint path is quoted" do
    # The endpoint is a value the write needs, quoted or not, so it is read off the
    # command as written rather than off the #unquoted view.
    output = { "id" => 12121, "html_url" => "https://github.com/o/r/pull/7#issuecomment-12121" }.to_json

    run_hook(claude_transcript(
      command: %q(gh api "repos/o/r/issues/7/comments" -f body='done'),
      output: output
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 12121)
  end

  test "reads a tool result whose content is an array of text blocks" do
    transcript = <<~JSONL
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"gh pr comment 281 --body done"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":[{"type":"text","text":"#{POSTED_URL}"}],"is_error":false}]}}
    JSONL

    run_hook(transcript)

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
  end

  # --- One call, two commands: whose output is this? -------------------------
  #
  # #901. Classification is per command segment, but a tool result is one blob for the
  # whole call. A post that shares its call with a read has that read's output in the
  # same result, and free-text scanning it records every comment the read listed.

  test "does NOT record the rest of a thread the same call listed after posting" do
    # The natural post-then-confirm move. Free-text scanning its result records the
    # human's comment as agent-posted, which suppresses it for every session forever.
    listing = [
      { "id" => 50, "html_url" => HUMAN_COMMENT_URL, "user" => { "login" => "tadasant" } },
      { "id" => 100, "html_url" => AGENT_COMMENT_URL }
    ].to_json

    run_hook(claude_transcript(
      command: "gh pr comment 281 --body 'done' && gh api repos/tadasant/tadasant-internal/issues/281/comments",
      output: "#{AGENT_COMMENT_URL}\n#{listing}\n"
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 100),
      "the comment the call posted is what the call vouches for"
    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 50),
      "a comment the listing printed is the human's, and recording it silences it fleet-wide"
  end

  test "does NOT record a comment the same call read back after posting" do
    read = { "id" => 50, "html_url" => HUMAN_COMMENT_URL, "user" => { "login" => "tadasant" } }.to_json

    run_hook(claude_transcript(
      command: "gh pr comment 281 --body 'done' && gh api repos/tadasant/tadasant-internal/issues/comments/50",
      output: "#{AGENT_COMMENT_URL}\n#{read}\n"
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 100)
    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 50)
  end

  test "does NOT record a thread the same call listed as bare permalink lines" do
    # `--jq '.[].html_url'` prints a whole thread in exactly the shape a post prints,
    # so nothing tells the post's line from the human's. Recording neither costs this
    # post its suppression; recording both would cost the human their reply.
    run_hook(claude_transcript(
      command: "gh pr comment 281 --body 'done' && gh api repos/tadasant/tadasant-internal/issues/281/comments --jq '.[].html_url'",
      output: "#{AGENT_COMMENT_URL}\n#{HUMAN_COMMENT_URL}\n#{AGENT_COMMENT_URL}\n"
    ))

    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 50),
      "the human's comment must not be suppressed"
    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 100),
      "and the post is given up with it, since the two are indistinguishable here"
  end

  test "records a post whose own command wrapped its URL in other text" do
    # The other direction, which the narrowing must not take: this call ran nothing but
    # the post, so everything it printed is the post's output — even though the URL does
    # not have a line to itself. A lost recording is the self-reply loop this hook exists
    # to break.
    run_hook(claude_transcript(
      command: "echo posted $(gh pr comment 281 --repo tadasant/tadasant-internal --body 'done')",
      output: "posted #{AGENT_COMMENT_URL}"
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 100)
  end

  test "records every comment a loop posted in one call" do
    # One posting segment, several posts, and nothing else in the call that reached
    # GitHub — so there is no count to hold the lines it printed against.
    run_hook(claude_transcript(
      command: "for n in 281 282; do gh pr comment $n --body 'done'; done",
      output: "#{AGENT_COMMENT_URL}\n#{HUMAN_COMMENT_URL}\n"
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 100)
    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 50)
  end

  test "records every comment a fan-out posted alongside a listing of PRs" do
    # One posting segment, many posts, and a `gh` read beside it that lists PRs rather
    # than comments — so nothing it printed is somebody else's comment, and there is no
    # count to hold the post's own lines against. Counting posting *segments* against
    # the lines of a fan-out would give up every recording in the call.
    run_hook(claude_transcript(
      command: "gh pr list --json number --jq '.[].number' | xargs -I{} gh pr comment {} --body 'done'",
      output: "#{AGENT_COMMENT_URL}\n#{HUMAN_COMMENT_URL}\n"
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 100)
    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 50)
  end

  test "records only the bare-permalink post when a call posts twice, two ways" do
    # The accepted cost of reading a mixed call by the shape a post prints: the `gh api`
    # reply's own JSON is indistinguishable, in a shared result, from the JSON of a
    # comment merely read back — which is the case above, and the one that must not be
    # recorded. So the reply is given up. A lost recording costs a comment its
    # suppression; recording the read one costs a human their reply.
    reply = { "id" => 900, "html_url" => "https://github.com/tadasant/tadasant-internal/pull/281#discussion_r900" }.to_json

    run_hook(claude_transcript(
      command: "gh pr comment 281 --body 'done' && gh api repos/tadasant/tadasant-internal/pulls/281/comments -f body='[CC Says] ok' -f in_reply_to=5",
      output: "#{AGENT_COMMENT_URL}\n#{reply}\n"
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 100)
    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "review", comment_id: 900)
  end

  test "reads a permalink line that ends in a carriage return" do
    run_hook(claude_transcript(
      command: "cd /repo && gh pr comment 281 --body 'done'",
      output: "#{AGENT_COMMENT_URL}\r\n"
    ))

    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 100)
  end
end

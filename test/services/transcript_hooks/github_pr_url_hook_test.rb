require "test_helper"

# The hook's specification is a matrix: (where the URL appeared) × (does the
# transcript show THIS session opening it). Only the second column decides
# whether the URL is recorded — the first decides how much evidence is needed.
#
#   where it appeared                          | this session opened it | recorded
#   -------------------------------------------|------------------------|---------
#   successful `gh pr create` result           | yes                    | yes
#   `gh api .../pulls -X POST` result          | yes                    | yes
#   MCP `create_pull_request` result           | yes (same repo)        | yes
#   MCP `create_pull_request` on another repo  | not this session's     | no
#   any other MCP tool's result                | no                     | no
#   failed `gh pr create`, "already exists"    | yes (same repo)        | yes
#   failed `gh pr create`, other failure       | unknown                | no
#   `gh api .../pulls` with no POST (a list)   | no                     | no
#   `gh pr view` / `gh pr list` / WebFetch     | no                     | no
#   assistant prose claiming creation          | yes (same repo)        | yes
#   assistant prose merely referencing a PR    | no                     | no
#   user message (incl. Zimmer notifications)  | no                     | no
#   any of the above, at/before a fork's point | no (the source did)    | no
#   any of the above, after a fork's point     | as above               | as above
class TranscriptHooks::GithubPrUrlHookTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @session.update!(custom_metadata: {}, git_root: "https://github.com/owner/repo.git")
  end

  # --- Claude Code transcript helpers -----------------------------------------

  def claude_shell_call(id:, command:)
    {
      type: "assistant",
      message: { role: "assistant", content: [ { type: "tool_use", id: id, name: "Bash", input: { command: command } } ] }
    }.to_json
  end

  def claude_tool_result(id:, content:, is_error: false)
    {
      type: "user",
      message: { content: [ { tool_use_id: id, type: "tool_result", content: content, is_error: is_error } ] }
    }.to_json
  end

  def claude_assistant_text(text)
    { type: "assistant", message: { role: "assistant", content: [ { type: "text", text: text } ] } }.to_json
  end

  def claude_user_text(text)
    { type: "user", message: { role: "user", content: text } }.to_json
  end

  # A complete `gh pr create` round trip: the invocation and its result.
  def claude_pr_create(output, id: "toolu_create", is_error: false, command: "gh pr create --fill")
    [ claude_shell_call(id: id, command: command), claude_tool_result(id: id, content: output, is_error: is_error) ]
  end

  def run_hook(*lines)
    TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: lines.flatten.join("\n"),
      new_messages: []
    ).call
  end

  def tracked_urls
    @session.reload.custom_metadata["github_pull_request_urls"]
  end

  # === Column: the session opened the PR (recorded) ============================

  test "records a same-repo PR opened by gh pr create" do
    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_equal [ "https://github.com/owner/repo/pull/123" ], tracked_urls
  end

  test "records a PR opened by gh pr create with surrounding output" do
    run_hook claude_pr_create("Creating pull request for feat into main\n\nhttps://github.com/owner/repo/pull/456\n")

    assert_equal [ "https://github.com/owner/repo/pull/456" ], tracked_urls
  end

  test "records a cross-repo PR opened by gh pr create" do
    # An agent on owner/repo opening a PR against a foreign repo: a successful
    # create is strong enough evidence to skip the same-repo guard entirely.
    run_hook claude_pr_create(
      "https://github.com/other/proj/pull/42",
      command: "gh pr create --repo other/proj --head fork:b --title T --body B"
    )

    assert_equal [ "https://github.com/other/proj/pull/42" ], tracked_urls
  end

  test "records only the created repo's PR when the create command is chained with another repo's list" do
    # A command is a whole shell line, so one result can hold URLs the create had
    # nothing to do with. The repo the create names bounds what it vouches for.
    run_hook claude_pr_create(
      "https://github.com/other/proj/pull/10\nhttps://github.com/third/party/pull/99",
      command: "gh pr create --repo other/proj && gh pr list --repo third/party --json url"
    )

    assert_equal [ "https://github.com/other/proj/pull/10" ], tracked_urls
  end

  test "records an upstream PR when the create names no repo" do
    # `gh pr create` from a fork clone opens against the parent repo without ever
    # naming it, so a create with no --repo keeps vouching for any repo.
    run_hook claude_pr_create("https://github.com/upstream/proj/pull/10")

    assert_equal [ "https://github.com/upstream/proj/pull/10" ], tracked_urls
  end

  test "records a cross-repo gh pr create PR even when git_root is not a GitHub URL" do
    @session.update!(git_root: "https://gitlab.com/group/proj.git")

    run_hook claude_pr_create("https://github.com/other/proj/pull/42", command: "gh pr create --repo other/proj")

    assert_equal [ "https://github.com/other/proj/pull/42" ], tracked_urls
  end

  # --- The shapes a real `gh pr create` arrives in -----------------------------
  #
  # A create counts wherever a command actually runs one, and #772 narrowed that
  # to what the command runs rather than what it quotes. Every shape below either
  # puts something in front of the create or puts quotes near it, and every one of
  # them still counts — narrowing far enough to miss a real create is the worse
  # failure (#89), because it switches every GitHub integration off for that
  # session in silence.

  test "records a PR opened by gh pr create after a cd into the clone" do
    run_hook claude_pr_create(
      "https://github.com/owner/repo/pull/50",
      command: "cd /home/rails/clones/repo && gh pr create --fill"
    )

    assert_equal [ "https://github.com/owner/repo/pull/50" ], tracked_urls
  end

  test "records a PR opened by gh pr create behind an environment prefix" do
    run_hook claude_pr_create(
      "https://github.com/owner/repo/pull/51",
      command: "GH_TOKEN=ghp_token GH_HOST=github.com gh pr create --fill"
    )

    assert_equal [ "https://github.com/owner/repo/pull/51" ], tracked_urls
  end

  test "records a PR opened by gh pr create behind the words a shell allows in command position" do
    # A create sits behind a great many things and the list has no end: loop and
    # conditional keywords, `timeout`, `sudo`, `xargs`. Reading only the front of
    # the segment would drop every one of them that went unenumerated, so the
    # create is read wherever it is run.
    [
      "for i in 1 2 3; do gh pr create --fill && break; done",
      "until gh pr create --fill; do sleep 5; done",
      "if ! gh pr create --fill; then echo failed; fi",
      "timeout 120 gh pr create --fill",
      "sudo -E gh pr create --fill",
      "echo x | xargs -I{} gh pr create --fill"
    ].each_with_index do |command, index|
      @session.update!(custom_metadata: {})

      run_hook claude_pr_create(
        "https://github.com/owner/repo/pull/52",
        id: "toolu_create_#{index}",
        command: command
      )

      assert_equal [ "https://github.com/owner/repo/pull/52" ], tracked_urls, "#{command} opens a pull request"
    end
  end

  test "records a PR opened by a gh pr create inside a quoted shell wrapper" do
    # What a shell is handed is a script, not data. ShellSegments splits it in
    # place of the wrapper, so the create is a command of its own rather than
    # something the wrapper quoted.
    run_hook claude_pr_create(
      "https://github.com/owner/repo/pull/55",
      command: %q(sh -c "cd /home/rails/clones/repo && gh pr create --fill")
    )

    assert_equal [ "https://github.com/owner/repo/pull/55" ], tracked_urls
  end

  test "records a PR opened by gh pr create whose title carries a shell separator" do
    # The pipe is inside the quoted title, so it is part of the title rather than
    # a command boundary — the create keeps a segment of its own, and blanking the
    # title out of it leaves the create in place.
    run_hook claude_pr_create(
      "https://github.com/owner/repo/pull/53",
      command: %q(gh pr create --title "fix: read a|b as one token" --body B)
    )

    assert_equal [ "https://github.com/owner/repo/pull/53" ], tracked_urls
  end

  test "records a PR opened by gh pr create after a heredoc body carrying apostrophes" do
    # A body written with `cat > file <<'EOF'` is the fleet's own `--body-file`
    # shape, and English prose puts stray apostrophes in it. Read as quotes across
    # the whole script they would enclose the create on the line after `EOF`; read
    # a line at a time they cannot reach it. One apostrophe or two makes no
    # difference, which is the point — a hook that recorded the odd count and lost
    # the even one would be worse than either.
    [ "It's ready for review.", "It's ready, and I've rerun CI." ].each_with_index do |body, index|
      @session.update!(custom_metadata: {})

      command = <<~SH
        cat > /tmp/body.md <<'EOF'
        #{body}
        EOF
        gh pr create --title T --body-file /tmp/body.md
      SH

      run_hook claude_pr_create(
        "https://github.com/owner/repo/pull/54",
        id: "toolu_create_heredoc_#{index}",
        command: command
      )

      assert_equal [ "https://github.com/owner/repo/pull/54" ], tracked_urls, "body: #{body}"
    end
  end

  test "records a PR opened by a gh pr create surrounded by comments carrying apostrophes" do
    # The same hazard without a heredoc: two stray apostrophes on either side of
    # the create would re-balance and swallow the line between them.
    command = "# Let's open the PR\ngh pr create --fill\n# That's it"

    run_hook claude_pr_create("https://github.com/owner/repo/pull/56", command: command)

    assert_equal [ "https://github.com/owner/repo/pull/56" ], tracked_urls
  end

  # --- REST API creates -------------------------------------------------------
  #
  # `gh pr create` goes through GraphQL, so a GraphQL outage sends agents to the
  # REST endpoint instead. A POST to a repo's /pulls collection opens a PR; the
  # same endpoint without a method lists them.

  test "records a PR opened by a REST API POST when gh pr create is down" do
    # Session 5679's shape verbatim: three `gh pr create` calls had just failed
    # with "HTTP 503 ... (https://api.github.com/graphql)", so the agent POSTed
    # to REST inside a retry loop. Its result holds a failed attempt and the
    # created URL in the same output, and the tool call did not error.
    command = <<~SH
      for i in 1 2 3 4 5 6; do
        out=$(gh api repos/owner/repo/pulls -X POST -f title="T" -f head=feat -f base=main --jq '.html_url' 2>&1)
        if echo "$out" | grep -q "github.com/owner/repo/pull/"; then echo "CREATED: $out"; exit 0; fi
        echo "attempt $i failed"
        command sleep 60
      done
      echo "STILL DOWN"
    SH

    run_hook(
      claude_shell_call(id: "toolu_rest", command: command),
      claude_tool_result(id: "toolu_rest", content: "attempt 1 failed\nCREATED: https://github.com/owner/repo/pull/175")
    )

    assert_equal [ "https://github.com/owner/repo/pull/175" ], tracked_urls
  end

  test "records a PR opened by a REST API POST inside a quoted shell wrapper" do
    # What a shell is handed is a script, not data: the `cd` in front of the create
    # is a command of its own, and the create is read as one too.
    run_hook(
      claude_shell_call(
        id: "toolu_rest",
        command: %q(bash -lc "cd /repo && gh api repos/owner/repo/pulls -X POST -f title=T")
      ),
      claude_tool_result(id: "toolu_rest", content: "https://github.com/owner/repo/pull/176")
    )

    assert_equal [ "https://github.com/owner/repo/pull/176" ], tracked_urls
  end

  test "ignores the PR list a quoted shell wrapper reads next to an unrelated write" do
    # The same wrapper in the other direction: read as one command, the comment
    # POST beside the list vouches for every PR the list printed (#214).
    run_hook(
      claude_shell_call(
        id: "toolu_list",
        command: %q(bash -lc "gh api repos/owner/repo/pulls --paginate && gh api repos/owner/repo/issues/1/comments -X POST -f body=x")
      ),
      claude_tool_result(id: "toolu_list", content: "https://github.com/owner/repo/pull/1\nhttps://github.com/owner/repo/pull/2")
    )

    assert_nil tracked_urls
  end

  test "records a PR opened by a REST API POST in every method-flag spelling" do
    [ "-X POST", "-XPOST", "--method POST", "--method=POST" ].each_with_index do |flag, index|
      @session.update!(custom_metadata: {})
      number = 200 + index

      run_hook(
        claude_shell_call(id: "toolu_rest", command: "gh api repos/owner/repo/pulls #{flag} -f title=T -f head=feat"),
        claude_tool_result(id: "toolu_rest", content: %({"html_url":"https://github.com/owner/repo/pull/#{number}"}))
      )

      assert_equal [ "https://github.com/owner/repo/pull/#{number}" ], tracked_urls, "method flag #{flag}"
    end
  end

  test "records a PR opened by a REST API POST written as a full api.github.com URL" do
    run_hook(
      claude_shell_call(id: "toolu_rest", command: "gh api --method POST https://api.github.com/repos/owner/repo/pulls -f title=T"),
      claude_tool_result(id: "toolu_rest", content: '{"html_url":"https://github.com/owner/repo/pull/31"}')
    )

    assert_equal [ "https://github.com/owner/repo/pull/31" ], tracked_urls
  end

  test "records a PR opened by a REST API POST split across continuation lines" do
    run_hook(
      claude_shell_call(id: "toolu_rest", command: "gh api repos/owner/repo/pulls \\\n  -X POST \\\n  -f title=T"),
      claude_tool_result(id: "toolu_rest", content: "https://github.com/owner/repo/pull/32")
    )

    assert_equal [ "https://github.com/owner/repo/pull/32" ], tracked_urls
  end

  test "records a PR opened by a REST API POST that uses gh's repo placeholders" do
    # `gh api` fills {owner}/{repo} in from the clone's remote, which is the
    # session's own repo.
    run_hook(
      claude_shell_call(id: "toolu_rest", command: "gh api repos/{owner}/{repo}/pulls -X POST -f title=T"),
      claude_tool_result(id: "toolu_rest", content: "https://github.com/owner/repo/pull/33")
    )

    assert_equal [ "https://github.com/owner/repo/pull/33" ], tracked_urls
  end

  test "records a cross-repo PR opened by a REST API POST" do
    # A successful create vouches for any repo, and the endpoint says which one.
    run_hook(
      claude_shell_call(id: "toolu_rest", command: "gh api repos/other/proj/pulls -X POST -f title=T"),
      claude_tool_result(id: "toolu_rest", content: "https://github.com/other/proj/pull/42")
    )

    assert_equal [ "https://github.com/other/proj/pull/42" ], tracked_urls
  end

  test "records only the posted repo's PR when a REST create is chained with another repo's list" do
    # The endpoint bounds what the result vouches for, and it outranks a --repo
    # flag belonging to a different subcommand on the same line.
    run_hook(
      claude_shell_call(
        id: "toolu_rest",
        command: "gh api repos/other/proj/pulls -X POST -f title=T && gh pr list --repo third/party --json url"
      ),
      claude_tool_result(
        id: "toolu_rest",
        content: "https://github.com/other/proj/pull/10\nhttps://github.com/third/party/pull/99"
      )
    )

    assert_equal [ "https://github.com/other/proj/pull/10" ], tracked_urls
  end

  test "records a PR opened by a REST API create that supplies fields and no method flag" do
    # `gh api` sends GET until a parameter is supplied and POST from then on, so
    # this opens a PR with no -X anywhere.
    run_hook(
      claude_shell_call(id: "toolu_rest", command: "gh api repos/owner/repo/pulls -f title=T -f head=feat -f base=main"),
      claude_tool_result(id: "toolu_rest", content: '{"html_url":"https://github.com/owner/repo/pull/34"}')
    )

    assert_equal [ "https://github.com/owner/repo/pull/34" ], tracked_urls
  end

  test "records a PR opened by a REST API create whose endpoint is built from a shell variable" do
    # A retry script hoists the slug into a variable, so the repo cannot be read
    # out of the text; `gh` resolves it against the clone, and so does the hook.
    run_hook(
      claude_shell_call(id: "toolu_rest", command: 'gh api "repos/$SLUG/pulls" -X POST -f title=T'),
      claude_tool_result(id: "toolu_rest", content: "https://github.com/owner/repo/pull/35")
    )

    assert_equal [ "https://github.com/owner/repo/pull/35" ], tracked_urls
  end

  test "records a PR opened by a REST API create wrapped in a command substitution" do
    # `out=$(gh api ...)` is how the outage fallback captured the URL to test it.
    run_hook(
      claude_shell_call(id: "toolu_rest", command: "out=$(gh api repos/owner/repo/pulls -X POST -f title=T --jq .html_url)"),
      claude_tool_result(id: "toolu_rest", content: "https://github.com/owner/repo/pull/36")
    )

    assert_equal [ "https://github.com/owner/repo/pull/36" ], tracked_urls
  end

  test "records the PR of a gh pr create that follows a failed REST create against another repo" do
    # The REST endpoint bounds the REST create, not the `gh pr create` after it:
    # both creates count, so the URL either of them produced is recorded.
    run_hook(
      claude_shell_call(
        id: "toolu_both",
        command: "gh api repos/upstream/proj/pulls -X POST -f title=T\ngh pr create --repo fork-target/proj --head fork:b"
      ),
      claude_tool_result(id: "toolu_both", content: "HTTP 503\nhttps://github.com/fork-target/proj/pull/12")
    )

    assert_equal [ "https://github.com/fork-target/proj/pull/12" ], tracked_urls
  end

  test "records a same-repo PR when a REST create fails because the branch already has one" do
    run_hook(
      claude_shell_call(id: "toolu_rest", command: "gh api repos/owner/repo/pulls -X POST -f title=T"),
      claude_tool_result(
        id: "toolu_rest",
        content: "gh: A pull request already exists for owner:feat.\nhttps://github.com/owner/repo/pull/37",
        is_error: true
      )
    )

    assert_equal [ "https://github.com/owner/repo/pull/37" ], tracked_urls
  end

  test "records a same-repo PR when gh pr create fails because the branch already has one" do
    # Re-running the open-pr flow on a branch that already has a PR: gh exits
    # non-zero and names the PR for OUR branch, which is ours to track.
    run_hook claude_pr_create(
      "a pull request for branch \"feat\" into branch \"main\" already exists:\nhttps://github.com/owner/repo/pull/7",
      is_error: true
    )

    assert_equal [ "https://github.com/owner/repo/pull/7" ], tracked_urls
  end

  test "records a same-repo PR the agent says it opened" do
    # #89: the creation path was not `gh pr create` (a wrapper script, an MCP
    # tool, the web UI) and the URL only ever appears in the agent's own prose.
    run_hook claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/12 — CI is running now.")

    assert_equal [ "https://github.com/owner/repo/pull/12" ], tracked_urls
  end

  test "records a same-repo PR from assistant prose in several natural phrasings" do
    phrasings = [
      "I've opened https://github.com/owner/repo/pull/%d for review.",
      "Created pull request https://github.com/owner/repo/pull/%d",
      "PR created: https://github.com/owner/repo/pull/%d",
      "Submitted the PR at https://github.com/owner/repo/pull/%d",
      "Opened a draft PR here: https://github.com/owner/repo/pull/%d",
      "Filed the pull request — https://github.com/owner/repo/pull/%d"
    ]

    phrasings.each_with_index do |phrasing, index|
      @session.update!(custom_metadata: {})
      number = index + 1

      run_hook claude_assistant_text(format(phrasing, number))

      assert_equal [ "https://github.com/owner/repo/pull/#{number}" ], tracked_urls,
                   "expected #{phrasing.inspect} to read as a creation claim"
    end
  end

  test "records a PR claimed in a string-shaped assistant message" do
    # Claude serializes assistant content as a bare String in some transcripts.
    run_hook({ type: "assistant", message: { role: "assistant", content: "Opened PR: https://github.com/owner/repo/pull/9" } }.to_json)

    assert_equal [ "https://github.com/owner/repo/pull/9" ], tracked_urls
  end

  test "records a PR once when both the create output and the agent's prose carry it" do
    run_hook(
      claude_pr_create("https://github.com/owner/repo/pull/5"),
      claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/5")
    )

    assert_equal [ "https://github.com/owner/repo/pull/5" ], tracked_urls
  end

  test "records both PRs when a session opens two" do
    run_hook(
      claude_pr_create("https://github.com/owner/repo/pull/1", id: "toolu_a"),
      claude_pr_create("https://github.com/other/proj/pull/2", id: "toolu_b", command: "gh pr create --repo other/proj")
    )

    assert_equal [ "https://github.com/owner/repo/pull/1", "https://github.com/other/proj/pull/2" ], tracked_urls
  end

  # --- MCP `create_pull_request` creates ---------------------------------------
  #
  # A session holding a GitHub MCP server opens a PR through a structured tool
  # call, not a shell command, so no command parsing can reach it (#559). Both
  # runtimes name an MCP tool `mcp__<server>__<tool>`; the input names the repo,
  # and the result is scanned for a URL exactly as a shell create's output is.
  #
  # The block shape is the one Claude Code writes verbatim: a `tool_use` with an
  # `id`, an `mcp__`-prefixed `name` and an `input` object, answered by a
  # `tool_result` whose content is an array of text blocks. What no server's
  # result *body* is assumed to look like is its structure — only that a PR URL
  # may appear somewhere in it.

  def claude_mcp_call(id:, name: "mcp__github__create_pull_request", input: { owner: "owner", repo: "repo", title: "T", head: "feat", base: "main" })
    {
      type: "assistant",
      message: { role: "assistant", content: [ { type: "tool_use", id: id, name: name, input: input } ] }
    }.to_json
  end

  def claude_mcp_result(id:, text:, is_error: false)
    {
      type: "user",
      message: { content: [ { tool_use_id: id, type: "tool_result", content: [ { type: "text", text: text } ], is_error: is_error } ] }
    }.to_json
  end

  test "records a PR opened by an MCP create_pull_request call" do
    run_hook(
      claude_mcp_call(id: "toolu_mcp"),
      claude_mcp_result(id: "toolu_mcp", text: %({"number":123,"html_url":"https://github.com/owner/repo/pull/123"}))
    )

    assert_equal [ "https://github.com/owner/repo/pull/123" ], tracked_urls
  end

  test "records a PR opened by an MCP create_pull_request whose input names one owner/repo slug" do
    # github-mcp-server takes `owner` and `repo` separately; a server that takes
    # one slug spells it `repo` or `repository`.
    run_hook(
      claude_mcp_call(id: "toolu_mcp", input: { repository: "owner/repo", title: "T" }),
      claude_mcp_result(id: "toolu_mcp", text: "Created pull request https://github.com/owner/repo/pull/124")
    )

    assert_equal [ "https://github.com/owner/repo/pull/124" ], tracked_urls
  end

  test "records a PR opened by an MCP create_pull_request whose input names no repo" do
    # A server that infers the repo from its own configuration names none in the
    # input, which leaves the same-repo guard on the URL as the only bound.
    run_hook(
      claude_mcp_call(id: "toolu_mcp", input: { title: "T", head: "feat", base: "main" }),
      claude_mcp_result(id: "toolu_mcp", text: "https://github.com/owner/repo/pull/125")
    )

    assert_equal [ "https://github.com/owner/repo/pull/125" ], tracked_urls
  end

  test "ignores an MCP create_pull_request against a different repository" do
    # #214, the direction this tier must not open: a create on someone else's
    # repo is not this session's PR to be notified about. Unlike a shell create,
    # which vouches for any repo it names, an MCP tool name is a convention
    # matched across servers whose semantics Zimmer has not verified, so the tier
    # is held to the session's own repo on both ends.
    run_hook(
      claude_mcp_call(id: "toolu_mcp", input: { owner: "other", repo: "proj", title: "T" }),
      claude_mcp_result(id: "toolu_mcp", text: %({"html_url":"https://github.com/other/proj/pull/42"}))
    )

    assert_nil tracked_urls
  end

  test "ignores a same-repo PR the create's own body cites" do
    # A create result is routinely the created PR serialized back, `body` and
    # all — and a body written by the `open-pr` skill cites other pull requests
    # as a matter of course. One create opens one PR, so the result vouches for
    # the first URL on this repo and no others; without that cap the session
    # would be handed every PR it linked to (#214).
    run_hook(
      claude_mcp_call(id: "toolu_mcp"),
      claude_mcp_result(
        id: "toolu_mcp",
        text: %({"html_url":"https://github.com/owner/repo/pull/140",) +
              %("body":"Supersedes https://github.com/owner/repo/pull/12 and follows https://github.com/owner/repo/pull/13"})
      )
    )

    assert_equal [ "https://github.com/owner/repo/pull/140" ], tracked_urls
  end

  test "ignores a same-repo PR quoted by an MCP create against a different repository" do
    # The half of the guard the URL's own repo cannot decide: the create opened
    # someone else's PR, and its result echoes a URL on *this* repo. The repo the
    # input names is what rejects it.
    run_hook(
      claude_mcp_call(id: "toolu_mcp", input: { owner: "other", repo: "proj", title: "T", body: "ports https://github.com/owner/repo/pull/141" }),
      claude_mcp_result(
        id: "toolu_mcp",
        text: %({"html_url":"https://github.com/other/proj/pull/9","body":"ports https://github.com/owner/repo/pull/141"})
      )
    )

    assert_nil tracked_urls
  end

  test "ignores a foreign PR quoted in the result of an MCP create on this repo" do
    # The repo the input names bounds what its result may vouch for, the same way
    # a create command's `--repo` does: a body that echoes back a related PR must
    # not be adopted alongside the one that was opened.
    run_hook(
      claude_mcp_call(id: "toolu_mcp"),
      claude_mcp_result(
        id: "toolu_mcp",
        text: %({"html_url":"https://github.com/owner/repo/pull/126","body":"follows https://github.com/other/proj/pull/7"})
      )
    )

    assert_equal [ "https://github.com/owner/repo/pull/126" ], tracked_urls
  end

  test "ignores a failed MCP create_pull_request" do
    # There is no "already exists" reading here: that one matches gh's own
    # failure text, and every MCP server writes its own. A PR the call failed to
    # open is not evidence it opened one.
    run_hook(
      claude_mcp_call(id: "toolu_mcp"),
      claude_mcp_result(
        id: "toolu_mcp",
        text: "failed to create pull request: a pull request already exists for owner:feat " \
              "(https://github.com/owner/repo/pull/127)",
        is_error: true
      )
    )

    assert_nil tracked_urls
  end

  test "ignores an MCP tool that writes about a pull request rather than opening one" do
    # `create_pull_request_review` and `create_pull_request_review_comment` sit
    # next to `create_pull_request` in github-mcp-server's tool list. The tool
    # half of the name is matched whole, so neither reads as a create.
    [ "mcp__github__create_pull_request_review", "mcp__github__create_pull_request_review_comment" ].each do |tool|
      @session.update!(custom_metadata: {})

      run_hook(
        claude_mcp_call(id: "toolu_mcp", name: tool, input: { owner: "owner", repo: "repo", pullNumber: 128 }),
        claude_mcp_result(id: "toolu_mcp", text: %({"html_url":"https://github.com/owner/repo/pull/128#discussion_r1"}))
      )

      assert_nil tracked_urls, tool
    end
  end

  test "ignores a PR the session only read through an MCP tool" do
    # The #214 shape through the MCP door: reading a repo's PRs is not opening
    # one, however structured the call that read them.
    run_hook(
      claude_mcp_call(id: "toolu_mcp", name: "mcp__github__list_pull_requests", input: { owner: "owner", repo: "repo" }),
      claude_mcp_result(id: "toolu_mcp", text: %([{"html_url":"https://github.com/owner/repo/pull/1"}]))
    )

    assert_nil tracked_urls
  end

  test "ignores a create_pull_request tool that is not namespaced to an MCP server" do
    # `mcp__<server>__` is the namespace Zimmer configured the server into. A bare
    # tool name belongs to whatever a runtime, a plugin or a subagent exposes,
    # which is not a namespace this can reason about.
    run_hook(
      claude_mcp_call(id: "toolu_mcp", name: "create_pull_request"),
      claude_mcp_result(id: "toolu_mcp", text: "https://github.com/owner/repo/pull/129")
    )

    assert_nil tracked_urls
  end

  test "records a PR opened by an MCP create_pull_request on a server whose name carries a hyphen" do
    # Claude Code keeps a server name verbatim in the tool name, and Zimmer's own
    # server keys are hyphenated (`remote-fs-screenshots`, `zimmer-self-session`).
    run_hook(
      claude_mcp_call(id: "toolu_mcp", name: "mcp__github-mcp-server__create_pull_request"),
      claude_mcp_result(id: "toolu_mcp", text: "https://github.com/owner/repo/pull/130")
    )

    assert_equal [ "https://github.com/owner/repo/pull/130" ], tracked_urls
  end

  test "records a PR opened by an MCP create_pull_request when git_root is an SSH URL" do
    @session.update!(git_root: "git@github.com:owner/repo.git")

    run_hook(
      claude_mcp_call(id: "toolu_mcp"),
      claude_mcp_result(id: "toolu_mcp", text: "https://github.com/owner/repo/pull/131")
    )

    assert_equal [ "https://github.com/owner/repo/pull/131" ], tracked_urls
  end

  # === Column: the session did NOT open the PR (ignored) =======================

  test "ignores a same-repo PR the session only read with gh pr view" do
    # #214: the same-repo fast path used to record this, which is how merge-gate
    # and reviewer sessions were handed PRs they had nothing to do with — and
    # then received their comments and merge-conflict notifications.
    run_hook(
      claude_shell_call(id: "toolu_view", command: "gh pr view 89"),
      claude_tool_result(id: "toolu_view", content: "title:\tSomething else\nurl:\thttps://github.com/owner/repo/pull/89")
    )

    assert_nil tracked_urls
  end

  test "ignores a PR URL in the output of a grep for the gh pr create literal" do
    # #772, session 11898 verbatim: a read-only grep over this hook's own source,
    # whose result is therefore the header above GH_PR_CREATE_PATTERN — example
    # URL included. The literal is the grep's argument, so the command runs a grep
    # and opens nothing. Note the pattern's escaped pipes: reading them as command
    # boundaries cuts the argument into pieces, one of which is the bare literal,
    # and no amount of care about the rest of the segment survives that. The URL
    # went into the session's list beside its real PR, and
    # The PR poll pass ran `gh pr view` against a repo that does not
    # exist on every poll from then on.
    @session.update!(git_root: "https://github.com/tadasant/zimmer.git")

    run_hook(
      claude_shell_call(
        id: "toolu_grep",
        command: %q(grep -n "def \|pull/\|gh pr create\|GH_PR_CREATE\|REPO_FLAG" app/services/transcript_hooks/github_pr_url_hook.rb)
      ),
      claude_tool_result(
        id: "toolu_grep",
        content: "12:  # Captures URLs like: https://github.com/owner/repo/pull/123\n" \
                 "18:  GH_PR_CREATE_PATTERN = /\\bgh\\s+pr\\s+create\\b/\n"
      )
    )

    assert_nil tracked_urls
  end

  test "ignores a PR URL in the output of commands that merely quote gh pr create" do
    # The same shape as the grep above, in its other spellings: the literal is
    # quoted, so it is an argument rather than the command. The URL here is on the
    # session's *own* repo, which is not what would have caught it — a create
    # vouches for any repo, this one included.
    [
      "rg -n 'gh pr create' app/services",
      %q(grep -rE "gh pr create|gh api" app/),
      %q(echo "reminder: gh pr create once CI is green" >> notes.md),
      %q(sed -i 's/gh pr create/gh pr create --draft/' script.sh)
    ].each_with_index do |command, index|
      @session.update!(custom_metadata: {})

      run_hook(
        claude_shell_call(id: "toolu_read_#{index}", command: command),
        claude_tool_result(id: "toolu_read_#{index}", content: "https://github.com/owner/repo/pull/123")
      )

      assert_nil tracked_urls, "#{command} does not open a pull request"
    end
  end

  test "ignores same-repo PRs listed by gh pr list" do
    run_hook(
      claude_shell_call(id: "toolu_list", command: "gh pr list --json url"),
      claude_tool_result(id: "toolu_list", content: '[{"url":"https://github.com/owner/repo/pull/1"},{"url":"https://github.com/owner/repo/pull/2"}]')
    )

    assert_nil tracked_urls
  end

  test "ignores same-repo PRs listed by a gh api call with no POST method" do
    # #214 at the REST endpoint: `repos/OWNER/REPO/pulls` without a method is a
    # *list* of the repo's open PRs. A session that read one owns none of them.
    run_hook(
      claude_shell_call(id: "toolu_list", command: "gh api repos/owner/repo/pulls --jq '.[].html_url'"),
      claude_tool_result(id: "toolu_list", content: "https://github.com/owner/repo/pull/1\nhttps://github.com/owner/repo/pull/2")
    )

    assert_nil tracked_urls
  end

  test "ignores same-repo PRs listed by a gh api call whose POST belongs to another line" do
    # The list and the POST are separate commands; the POST cannot vouch for the
    # list's output just by sharing a tool call with it.
    run_hook(
      claude_shell_call(
        id: "toolu_list",
        command: "gh api repos/owner/repo/pulls --jq '.[].html_url'\ngh api repos/owner/repo/issues/7/comments -X POST -f body=ack"
      ),
      claude_tool_result(id: "toolu_list", content: "https://github.com/owner/repo/pull/1")
    )

    assert_nil tracked_urls
  end

  test "ignores a same-repo PR named by a POST to an endpoint nested under pulls" do
    # Posting a review or a review comment writes *about* a pull request; it
    # does not open one.
    run_hook(
      claude_shell_call(id: "toolu_review", command: "gh api repos/owner/repo/pulls/89/reviews -X POST -f event=APPROVE"),
      claude_tool_result(id: "toolu_review", content: '{"pull_request_url":"https://github.com/owner/repo/pull/89"}')
    )

    assert_nil tracked_urls
  end

  test "ignores a placeholder REST create when the clone is not a GitHub repo" do
    # Nothing resolves {owner}/{repo}, so nothing bounds what the result may
    # vouch for — safer to record nothing than to adopt every URL in its output.
    @session.update!(git_root: "https://gitlab.com/group/proj.git")

    run_hook(
      claude_shell_call(id: "toolu_rest", command: "gh api repos/{owner}/{repo}/pulls -X POST -f title=T"),
      claude_tool_result(id: "toolu_rest", content: "https://github.com/other/proj/pull/9")
    )

    assert_nil tracked_urls
  end

  test "ignores same-repo PRs listed by a gh api call chained with a POST on the same line" do
    # A shell line holds several commands. Reading the line as one would let the
    # comment POST vouch for the list beside it — #214 through a new door.
    run_hook(
      claude_shell_call(
        id: "toolu_list",
        command: "gh api repos/owner/repo/pulls --jq '.[].html_url' && gh api repos/owner/repo/issues/7/comments -X POST -f body=ack"
      ),
      claude_tool_result(id: "toolu_list", content: "https://github.com/owner/repo/pull/1\nhttps://github.com/owner/repo/pull/2")
    )

    assert_nil tracked_urls
  end

  test "ignores the PR list a failed REST create falls back to reading" do
    # `POST || list` is the retry shape: the list's output is every open PR on the
    # repo, and only the create's own output is evidence.
    run_hook(
      claude_shell_call(
        id: "toolu_retry",
        command: "gh api repos/owner/repo/pulls -X POST -f title=T || gh api repos/owner/repo/pulls --jq '.[].html_url'"
      ),
      claude_tool_result(id: "toolu_retry", content: "HTTP 503\nhttps://github.com/owner/repo/pull/1\nhttps://github.com/owner/repo/pull/2", is_error: true)
    )

    assert_nil tracked_urls
  end

  test "ignores same-repo PRs listed by a gh api call that asks for GET explicitly" do
    # An explicit method outranks the field flag that would otherwise imply POST.
    run_hook(
      claude_shell_call(id: "toolu_list", command: "gh api repos/owner/repo/pulls -X GET -f state=open --jq '.[].html_url'"),
      claude_tool_result(id: "toolu_list", content: "https://github.com/owner/repo/pull/1")
    )

    assert_nil tracked_urls
  end

  test "ignores a same-repo PR whose creation is claimed by someone else inside a tool result" do
    # `gh pr view --comments` quotes other people's prose. A creation claim is
    # only evidence when the agent itself makes it.
    run_hook(
      claude_shell_call(id: "toolu_view", command: "gh pr view 89 --comments"),
      claude_tool_result(id: "toolu_view", content: "tadasant commented: Opened PR: https://github.com/owner/repo/pull/89 to fix this.")
    )

    assert_nil tracked_urls
  end

  test "ignores a same-repo PR fetched from the web" do
    run_hook(
      claude_shell_call(id: "toolu_fetch", command: "curl -s https://api.github.com/repos/owner/repo/pulls"),
      claude_tool_result(id: "toolu_fetch", content: '{"html_url":"https://github.com/owner/repo/pull/321"}')
    )

    assert_nil tracked_urls
  end

  test "ignores a same-repo PR that arrives in a user message" do
    # Zimmer's own trigger prompts carry PR URLs ("comments on your PR <url>").
    # Adopting them would let one misrouted notification create a permanent
    # wrong association — the exact loop #214 describes.
    run_hook claude_user_text("GitHub Comment Response Required on https://github.com/owner/repo/pull/89 — please respond.")

    assert_nil tracked_urls
  end

  test "ignores a same-repo PR the agent merely refers to" do
    run_hook claude_assistant_text("I'm creating a plan to review https://github.com/owner/repo/pull/999 before touching it.")

    assert_nil tracked_urls
  end

  test "ignores a same-repo PR described as an open PR" do
    # "open" is an adjective as often as a verb, and this is how prose refers to
    # someone else's PR — so only inflected verbs read as a creation claim.
    [
      "There are two open PRs: https://github.com/owner/repo/pull/1 and one more.",
      "I reviewed the open PR: https://github.com/owner/repo/pull/1 and left comments.",
      "I will open the PR after https://github.com/owner/repo/pull/1 lands.",
      "Changed files: https://github.com/owner/repo/pull/1",
      "Opening https://github.com/owner/repo/pull/1 to read the discussion."
    ].each do |text|
      @session.update!(custom_metadata: {})

      run_hook claude_assistant_text(text)

      assert_nil tracked_urls, "expected #{text.inspect} not to read as a creation claim"
    end
  end

  test "records a same-repo PR claimed on the line above the URL" do
    run_hook claude_assistant_text("I've opened the pull request:\n\nhttps://github.com/owner/repo/pull/276")

    assert_equal [ "https://github.com/owner/repo/pull/276" ], tracked_urls
  end

  test "ignores a same-repo PR referenced without any creation claim" do
    run_hook claude_assistant_text("See https://github.com/owner/repo/pull/999 for the earlier approach.")

    assert_nil tracked_urls
  end

  test "ignores a creation claim about a different PR in an earlier sentence" do
    # The claim has to vouch for THIS url, not for one two sentences back.
    text = "I opened PR https://github.com/owner/repo/pull/1 yesterday. Unrelated background reading lives in the tracking issue, " \
           "and the CI failure it exposed is described at https://github.com/owner/repo/pull/2 which someone else owns."

    run_hook claude_assistant_text(text)

    assert_equal [ "https://github.com/owner/repo/pull/1" ], tracked_urls
  end

  test "ignores a cross-repo PR the agent claims to have opened" do
    # Prose is the weakest evidence, so it keeps the same-repo guard: an agent
    # summarizing "opened PR <url>" about a foreign repo is more often quoting
    # than reporting.
    run_hook claude_assistant_text("Opened PR: https://github.com/other/proj/pull/3")

    assert_nil tracked_urls
  end

  test "ignores a cross-repo PR named by a failed gh pr create" do
    run_hook claude_pr_create(
      "a pull request for branch \"fork:b\" into branch \"main\" already exists:\nhttps://github.com/other/proj/pull/55",
      is_error: true,
      command: "gh pr create --repo other/proj --head fork:b"
    )

    assert_nil tracked_urls
  end

  test "ignores a PR URL in a gh pr create failure that is not an already-exists message" do
    run_hook claude_pr_create(
      "pull request create failed: GraphQL: Resource not accessible by integration. See https://github.com/owner/repo/pull/44 for the prior attempt.",
      is_error: true
    )

    assert_nil tracked_urls
  end

  test "ignores non-GitHub PR URLs" do
    run_hook claude_pr_create("https://gitlab.com/owner/repo/pull/123\nhttps://github.evil.com/owner/repo/pull/5")

    assert_nil tracked_urls
  end

  test "ignores everything when the transcript is empty" do
    run_hook ""

    assert_nil tracked_urls
  end

  test "ignores a tool result that has no matching tool call" do
    # A create result with no invocation to vouch for it is just text.
    run_hook claude_tool_result(id: "toolu_orphan", content: "https://github.com/owner/repo/pull/123")

    assert_nil tracked_urls
  end

  # === git_root parsing (which repo counts as "same repo") =====================
  #
  # Exercised through the prose path, since that is the evidence kind the
  # same-repo guard qualifies.

  test "matches an SSH git_root" do
    @session.update!(git_root: "git@github.com:owner/repo.git")

    run_hook claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/1")

    assert_equal [ "https://github.com/owner/repo/pull/1" ], tracked_urls
  end

  test "matches an SSH git_root without the .git suffix" do
    @session.update!(git_root: "git@github.com:owner/repo")

    run_hook claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/1")

    assert_equal [ "https://github.com/owner/repo/pull/1" ], tracked_urls
  end

  test "matches an HTTPS git_root without the .git suffix" do
    @session.update!(git_root: "https://github.com/owner/repo")

    run_hook claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/1")

    assert_equal [ "https://github.com/owner/repo/pull/1" ], tracked_urls
  end

  test "matches repos case-insensitively" do
    @session.update!(git_root: "https://github.com/Owner/Repo.git")

    run_hook claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/1")

    assert_equal [ "https://github.com/owner/repo/pull/1" ], tracked_urls
  end

  test "does not match a different repo" do
    run_hook claude_assistant_text("Opened PR: https://github.com/other/repo/pull/1")

    assert_nil tracked_urls
  end

  test "does not match when git_root is blank" do
    # Session validates git_root's presence, so this state only arises for a row
    # written before that validation — update_column reproduces it.
    @session.update_column(:git_root, nil)

    run_hook claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/1")

    assert_nil tracked_urls
  end

  test "does not match when git_root is a GitLab URL" do
    @session.update!(git_root: "https://gitlab.com/owner/repo.git")

    run_hook claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/1")

    assert_nil tracked_urls
  end

  # === Accumulation and timestamps ============================================

  test "appends a newly opened PR to PRs already recorded" do
    @session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/1" ] })

    run_hook claude_pr_create("https://github.com/owner/repo/pull/999")

    assert_equal [ "https://github.com/owner/repo/pull/1", "https://github.com/owner/repo/pull/999" ], tracked_urls
  end

  test "does not duplicate a PR already recorded" do
    @session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_equal [ "https://github.com/owner/repo/pull/123" ], tracked_urls
  end

  test "stores a tracking timestamp when a PR is first recorded" do
    freeze_time do
      run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

      assert_equal Time.current.iso8601,
                   @session.reload.custom_metadata.dig("github_pr_tracking_started_at", "https://github.com/owner/repo/pull/123")
    end
  end

  test "does not overwrite the tracking timestamp of a PR already recorded" do
    original = "2025-01-01T00:00:00Z"
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/1" ],
      "github_pr_tracking_started_at" => { "https://github.com/owner/repo/pull/1" => original }
    })

    run_hook(
      claude_pr_create("https://github.com/owner/repo/pull/1", id: "toolu_a"),
      claude_pr_create("https://github.com/owner/repo/pull/2", id: "toolu_b")
    )

    timestamps = @session.reload.custom_metadata["github_pr_tracking_started_at"]
    assert_equal original, timestamps["https://github.com/owner/repo/pull/1"]
    assert_not_nil timestamps["https://github.com/owner/repo/pull/2"]
  end

  test "stores separate timestamps for PRs recorded at different times" do
    first_time = Time.utc(2025, 1, 15, 10, 0, 0)
    travel_to(first_time) { run_hook claude_pr_create("https://github.com/owner/repo/pull/1") }

    second_time = Time.utc(2025, 1, 15, 11, 0, 0)
    travel_to(second_time) { run_hook claude_pr_create("https://github.com/owner/repo/pull/2", id: "toolu_b") }

    timestamps = @session.reload.custom_metadata["github_pr_tracking_started_at"]
    assert_equal first_time.iso8601, timestamps["https://github.com/owner/repo/pull/1"]
    assert_equal second_time.iso8601, timestamps["https://github.com/owner/repo/pull/2"]
  end

  test "reads array-shaped Claude tool result content" do
    run_hook(
      claude_shell_call(id: "toolu_create", command: "gh pr create --fill"),
      {
        type: "user",
        message: { content: [ { tool_use_id: "toolu_create", type: "tool_result", content: [ { type: "text", text: "https://github.com/owner/repo/pull/77" } ] } ] }
      }.to_json
    )

    assert_equal [ "https://github.com/owner/repo/pull/77" ], tracked_urls
  end

  # === Codex runtime transcript shape =========================================
  #
  # Codex rollouts use a different schema than Claude: each line is
  # {timestamp, type, payload}. A shell call is a response_item with
  # payload.type "function_call" (name "shell", JSON-encoded arguments holding a
  # command argv) or "local_shell_call" (argv under action.command). The shell's
  # exit code lives on a separate event_msg line (exec_command_end), correlated
  # by call_id, and the command output is a response_item function_call_output
  # whose `output` is plain text. Assistant prose is a response_item `message`
  # (or the UI-side `agent_message` event). These helpers build those lines so
  # the fixtures mirror a real Codex rollout.

  TS = "2026-06-04T00:00:00.000Z"

  def codex_shell_call(call_id:, command:, name: "shell")
    {
      timestamp: TS,
      type: "response_item",
      payload: { type: "function_call", name: name, arguments: { command: command }.to_json, call_id: call_id }
    }.to_json
  end

  def codex_local_shell_call(call_id:, command:)
    {
      timestamp: TS,
      type: "response_item",
      payload: { type: "local_shell_call", call_id: call_id, action: { type: "exec", command: command } }
    }.to_json
  end

  def codex_exec_end(call_id:, exit_code:)
    {
      timestamp: TS,
      type: "event_msg",
      payload: {
        type: "exec_command_end", call_id: call_id, exit_code: exit_code,
        stdout: "", stderr: "", aggregated_output: "", duration: 1.0
      }
    }.to_json
  end

  def codex_output(call_id:, output:)
    {
      timestamp: TS,
      type: "response_item",
      payload: { type: "function_call_output", call_id: call_id, output: output }
    }.to_json
  end

  def codex_assistant_message(text)
    {
      timestamp: TS,
      type: "response_item",
      payload: { type: "message", role: "assistant", content: [ { type: "output_text", text: text } ] }
    }.to_json
  end

  def codex_agent_message_event(text)
    { timestamp: TS, type: "event_msg", payload: { type: "agent_message", message: text } }.to_json
  end

  def codex_user_message(text)
    {
      timestamp: TS,
      type: "response_item",
      payload: { type: "message", role: "user", content: [ { type: "input_text", text: text } ] }
    }.to_json
  end

  test "codex: records a same-repo PR opened by gh pr create" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --base main --title T --body B" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/4050\n")
    )

    assert_equal [ "https://github.com/owner/repo/pull/4050" ], tracked_urls
  end

  test "codex: records a cross-repo PR opened by gh pr create" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --repo other/proj" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/other/proj/pull/9")
    )

    assert_equal [ "https://github.com/other/proj/pull/9" ], tracked_urls
  end

  test "codex: records a PR opened by a gh pr create behind a cd in the joined argv" do
    # Codex's argv array joins back into `bash -lc cd ... && gh pr create ...`.
    # The wrapper is stripped and the `cd` is a segment of its own; nothing here
    # quotes the create.
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "cd /workspace/repo && gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/4051\n")
    )

    assert_equal [ "https://github.com/owner/repo/pull/4051" ], tracked_urls
  end

  test "codex: ignores a PR URL in the output of a grep for the gh pr create literal" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(
        call_id: "call_1",
        command: [ "bash", "-lc", %q(grep -n "def \|gh pr create\|pull/" app/services/transcript_hooks/github_pr_url_hook.rb) ]
      ),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "12:  # Captures URLs like: https://github.com/owner/repo/pull/123\n")
    )

    assert_nil tracked_urls
  end

  test "codex: records a PR opened via the local_shell_call argv variant" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_local_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/11")
    )

    assert_equal [ "https://github.com/owner/repo/pull/11" ], tracked_urls
  end

  test "codex: records a PR opened by a REST API POST" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh api repos/owner/repo/pulls -X POST -f title=T" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: '{"html_url":"https://github.com/owner/repo/pull/77"}')
    )

    assert_equal [ "https://github.com/owner/repo/pull/77" ], tracked_urls
  end

  test "codex: ignores same-repo PRs listed by a gh api call with no POST method" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh api repos/owner/repo/pulls --jq '.[].html_url'" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/78")
    )

    assert_nil tracked_urls
  end

  test "codex: records a same-repo PR the agent says it opened" do
    @session.update!(agent_runtime: "codex")

    run_hook codex_assistant_message("Opened PR: https://github.com/owner/repo/pull/12")

    assert_equal [ "https://github.com/owner/repo/pull/12" ], tracked_urls
  end

  test "codex: records a same-repo PR claimed in an agent_message event" do
    @session.update!(agent_runtime: "codex")

    run_hook codex_agent_message_event("Created pull request https://github.com/owner/repo/pull/13")

    assert_equal [ "https://github.com/owner/repo/pull/13" ], tracked_urls
  end

  test "codex: ignores a same-repo PR the session only read" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr view 89" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "url:\thttps://github.com/owner/repo/pull/89")
    )

    assert_nil tracked_urls
  end

  test "codex: ignores a same-repo PR that arrives in a user message" do
    @session.update!(agent_runtime: "codex")

    run_hook codex_user_message("Comments on your PR https://github.com/owner/repo/pull/89 need a response.")

    assert_nil tracked_urls
  end

  test "codex: records a same-repo PR when gh pr create exits non-zero with already-exists" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 1),
      codex_output(call_id: "call_1", output: "a pull request for branch already exists:\nhttps://github.com/owner/repo/pull/123")
    )

    assert_equal [ "https://github.com/owner/repo/pull/123" ], tracked_urls
  end

  test "codex: ignores a cross-repo PR when gh pr create exits non-zero" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --repo other/proj" ]),
      codex_exec_end(call_id: "call_1", exit_code: 1),
      codex_output(call_id: "call_1", output: "a pull request already exists:\nhttps://github.com/other/proj/pull/55")
    )

    assert_nil tracked_urls
  end

  test "codex: associates a cross-repo gh pr create PR when no exec_command_end line exists" do
    # Without an exit code the shell is treated as successful, matching the
    # parser's is_error derivation.
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --repo other/proj" ]),
      codex_output(call_id: "call_1", output: "https://github.com/other/proj/pull/70")
    )

    assert_equal [ "https://github.com/other/proj/pull/70" ], tracked_urls
  end

  test "codex: ignores gh pr create text inside a non-shell function_call" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "gh pr create --fill" ], name: "apply_patch"),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/other/proj/pull/71")
    )

    assert_nil tracked_urls
  end

  test "codex: reads array-shaped custom_tool_call_output" do
    @session.update!(agent_runtime: "codex")

    custom_output = {
      timestamp: TS,
      type: "response_item",
      payload: { type: "custom_tool_call_output", call_id: "call_1", output: [ { type: "text", text: "https://github.com/owner/repo/pull/88" } ] }
    }.to_json

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      custom_output
    )

    assert_equal [ "https://github.com/owner/repo/pull/88" ], tracked_urls
  end

  # Codex routes an MCP tool through the same `function_call` payload as its
  # built-in `shell`, naming it `mcp__<server>__<tool>` and JSON-encoding the
  # arguments — the shape CodexMcpStatusDetector reads a server's connection out
  # of. There is no `exec_command_end` for a tool that is not a shell, so nothing
  # correlates an exit code to it.

  def codex_mcp_call(call_id:, name: "mcp__github__create_pull_request", arguments: { owner: "owner", repo: "repo", title: "T", head: "feat", base: "main" })
    {
      timestamp: TS,
      type: "response_item",
      payload: { type: "function_call", name: name, arguments: arguments.to_json, call_id: call_id }
    }.to_json
  end

  test "codex: records a PR opened by an MCP create_pull_request call" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_mcp_call(call_id: "call_mcp"),
      codex_output(call_id: "call_mcp", output: %({"html_url":"https://github.com/owner/repo/pull/4060"}))
    )

    assert_equal [ "https://github.com/owner/repo/pull/4060" ], tracked_urls
  end

  test "codex: ignores an MCP create_pull_request against a different repository" do
    # #214 in the Codex shape: the arguments are a JSON string rather than an
    # object, and the repo they name is still what bounds the call.
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_mcp_call(call_id: "call_mcp", arguments: { owner: "other", repo: "proj", title: "T" }),
      codex_output(call_id: "call_mcp", output: %({"html_url":"https://github.com/other/proj/pull/4061"}))
    )

    assert_nil tracked_urls
  end

  test "codex: ignores an MCP tool that writes about a pull request rather than opening one" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_mcp_call(call_id: "call_mcp", name: "mcp__github__create_pull_request_review",
        arguments: { owner: "owner", repo: "repo", pullNumber: 4062 }),
      codex_output(call_id: "call_mcp", output: %({"html_url":"https://github.com/owner/repo/pull/4062#pullrequestreview-1"}))
    )

    assert_nil tracked_urls
  end

  test "codex: tolerates an MCP call whose arguments are not valid JSON" do
    @session.update!(agent_runtime: "codex")

    call = {
      timestamp: TS,
      type: "response_item",
      payload: { type: "function_call", name: "mcp__github__create_pull_request", arguments: "{not json", call_id: "call_mcp" }
    }.to_json

    # No readable input names a repo, so the same-repo guard on the URL is the
    # only bound left — and it holds.
    run_hook(call, codex_output(call_id: "call_mcp", output: "https://github.com/owner/repo/pull/4063"))

    assert_equal [ "https://github.com/owner/repo/pull/4063" ], tracked_urls
  end

  # === Status-summary forks (never recorded) ==================================

  # A summary fork is the one session whose transcript is not its own: it is a
  # copy of the source's, so the source's own `gh pr create` is sitting in it as
  # the strongest evidence the hook recognizes.

  def make_summary_fork(source_id: 42)
    @session.update!(
      metadata: @session.metadata.to_h.merge(SessionStatusSummaryGenerator::FORK_MARKER => source_id)
    )
    assert @session.status_summary_fork?, "the fixture must actually be a summary fork"
  end

  test "records nothing for a status-summary fork, whose gh pr create is the source's" do
    make_summary_fork

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_nil tracked_urls
  end

  test "records nothing for a status-summary fork on any other evidence either" do
    make_summary_fork

    run_hook(
      claude_pr_create("a pull request for branch feat already exists:\n" \
                       "https://github.com/owner/repo/pull/7", is_error: true),
      claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/8")
    )

    assert_nil tracked_urls
  end

  test "an uncredited summary fork stays out of the GitHub pollers' scope" do
    # This is the consequence the guard exists for. `with_github_prs` is keyed on
    # the URL list alone, so crediting the fork enrolls it in the PR, comment and
    # merge-conflict pollers — and the PR poller answers an open -> merged
    # transition by queueing "your PR merged, you may archive" onto a session the
    # harvest job archives as soon as the blurb is out. That retires the message
    # `undelivered` and pages (production session 6335).
    make_summary_fork

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_not Session.with_github_prs.exists?(id: @session.id)
  end

  test "does not stamp tracking timestamps on a status-summary fork" do
    make_summary_fork

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_nil @session.reload.custom_metadata["github_pr_tracking_started_at"]
  end

  test "leaves a summary fork's inherited URL list untouched rather than extending it" do
    # Nothing writes this list onto a fork today, but a fork created before this
    # guard shipped can still carry one. The guard must not top it up with the
    # source's newer PRs on the next transcript scan.
    @session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/1" ] })
    make_summary_fork

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_equal [ "https://github.com/owner/repo/pull/1" ], tracked_urls
  end

  # === User forks (only what they opened after the fork point) =================

  # A user-initiated fork has the same copied transcript as a summary fork, but
  # it is a live working session that may go on to open pull requests of its own
  # — so the guard cannot be "record nothing". The fork point is the line: at or
  # before `forked_at_message_index` the messages are the source's, after it they
  # are the fork's (#556).

  # `forked_at_message_index` is INCLUSIVE and 0-based, so a fork carrying `n`
  # copied messages records `n - 1`. Mirrors ForkSessionService, which slices
  # `parsed[0..message_index]`.
  def make_user_fork(inherited_message_count:, source_id: 42)
    @session.update!(metadata: @session.metadata.to_h.merge(
      "forked_from_session_id" => source_id,
      "forked_at_message_index" => inherited_message_count - 1
    ))
    assert_not @session.status_summary_fork?, "the fixture must be a user fork, not a summary fork"
    assert_equal inherited_message_count, @session.inherited_transcript_message_count
  end

  test "records nothing for a user fork whose only gh pr create is the source's" do
    # Deliberately the same source-copied `gh pr create` the summary-fork tests
    # above feed: two messages, both inherited, both from before the fork point.
    make_user_fork(inherited_message_count: 2)

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_nil tracked_urls
  end

  test "records nothing for a user fork on the source's re-created or claimed evidence either" do
    make_user_fork(inherited_message_count: 3)

    run_hook(
      claude_pr_create("a pull request for branch feat already exists:\n" \
                       "https://github.com/owner/repo/pull/7", is_error: true),
      claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/8")
    )

    assert_nil tracked_urls
  end

  test "records the PR a user fork opens itself after the fork point" do
    # This is the half a blanket fork guard would break: the source's PR is in
    # the copied prefix, the fork's own is in what it wrote next, and only the
    # second is the fork's provenance.
    make_user_fork(inherited_message_count: 2)

    run_hook(
      claude_pr_create("https://github.com/owner/repo/pull/123", id: "toolu_source"),
      claude_pr_create("https://github.com/owner/repo/pull/456", id: "toolu_fork")
    )

    assert_equal [ "https://github.com/owner/repo/pull/456" ], tracked_urls
  end

  test "records a user fork's own prose claim made after the fork point" do
    make_user_fork(inherited_message_count: 1)

    run_hook(
      claude_user_text("continue from here"),
      claude_assistant_text("Opened PR: https://github.com/owner/repo/pull/456")
    )

    assert_equal [ "https://github.com/owner/repo/pull/456" ], tracked_urls
  end

  test "a user fork that opens its own PR still reaches the GitHub pollers" do
    # The other direction of the consequence the summary-fork tests pin. Too
    # broad a guard would silently switch off the PR, comment and merge-conflict
    # pollers for a session that really did open the PR (#89).
    make_user_fork(inherited_message_count: 2)

    run_hook(
      claude_pr_create("https://github.com/owner/repo/pull/123", id: "toolu_source"),
      claude_pr_create("https://github.com/owner/repo/pull/456", id: "toolu_fork")
    )

    assert Session.with_github_prs.exists?(id: @session.id)
  end

  test "an uncredited user fork stays out of the GitHub pollers' scope" do
    make_user_fork(inherited_message_count: 2)

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_not Session.with_github_prs.exists?(id: @session.id)
  end

  test "an inherited create whose result lands past the fork point is not evidence" do
    # The fork point is any message index the user picks, so it can fall between a
    # `gh pr create` and its result. The command is then the source's, and a
    # result is only ever read through the command that produced it — so the
    # orphaned result vouches for nothing. Conservative on purpose: the half of
    # the round trip that says which repo was targeted is the half that is gone.
    make_user_fork(inherited_message_count: 1)

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_nil tracked_urls
  end

  test "codex: records nothing for a user fork whose gh pr create is the source's" do
    # The prefix is dropped before the runtime parser ever sees the transcript,
    # so this holds for both shapes. Pinned because the two parsers read entirely
    # different line types and only one of them was exercised above.
    @session.update!(agent_runtime: "codex")
    make_user_fork(inherited_message_count: 3)

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/123")
    )

    assert_nil tracked_urls
  end

  test "codex: records the PR a user fork opens itself after the fork point" do
    @session.update!(agent_runtime: "codex")
    make_user_fork(inherited_message_count: 3)

    run_hook(
      codex_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/123"),
      codex_shell_call(call_id: "call_2", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_2", exit_code: 0),
      codex_output(call_id: "call_2", output: "https://github.com/owner/repo/pull/456")
    )

    assert_equal [ "https://github.com/owner/repo/pull/456" ], tracked_urls
  end

  test "a fork with no recorded fork point is read exactly as an unforked session" do
    # Nothing writes `forked_from_session_id` without `forked_at_message_index`
    # today — ForkSessionService sets both in the same hash. This pins which way
    # the reader falls if that ever stops being true: a boundary it cannot locate
    # is not an excuse to discard the session's own evidence, which is the
    # failure mode (#89) that costs more than the duplicate routing.
    @session.update!(metadata: @session.metadata.to_h.merge("forked_from_session_id" => 42))

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_equal [ "https://github.com/owner/repo/pull/123" ], tracked_urls
  end

  test "a fork carrying more copied messages than its transcript holds records nothing" do
    make_user_fork(inherited_message_count: 50)

    run_hook claude_pr_create("https://github.com/owner/repo/pull/123")

    assert_nil tracked_urls
  end

  # === The missing-PR warning (#89) ===========================================

  test "warns once when a session with a PR goal pauses having recorded nothing" do
    @session.update!(goal: "Open a PR and leave it unmerged for review.")

    assert_difference -> { @session.logs.count }, 1 do
      TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(@session)
    end

    log = @session.logs.order(:created_at).last
    assert_equal "warning", log.level
    assert_match(/no PR URL has been captured/, log.content)

    assert_no_difference -> { @session.logs.count } do
      TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(@session.reload)
    end
  end

  test "reads the shipped goal catalog the way the catalog means it" do
    # The read-only goal mentions PRs precisely to forbid them ("do not create
    # files, PRs, or branches"), so a bare "does the goal say PR" would warn on
    # every codebase-question session. Assert against the real descriptions.
    GoalsConfig.all.each do |goal|
      @session.update!(goal: goal.description, custom_metadata: {})
      @session.logs.destroy_all

      TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(@session)
      warned = @session.logs.where(level: "warning").any?

      if goal.id == "codebase-question"
        assert_not warned, "goal #{goal.id} forbids PRs; it must not warn about a missing one"
      else
        assert warned, "goal #{goal.id} asks for a PR; a missing one must warn"
      end
    end
  end

  test "recognizes pull-request goals written without the abbreviation" do
    @session.update!(goal: "Open a reviewed, green pull request and stop.")

    assert_difference -> { @session.logs.count }, 1 do
      TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(@session)
    end
  end

  test "does not warn when a PR was recorded" do
    @session.update!(
      goal: "Open a PR and leave it unmerged for review.",
      custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/1" ] }
    )

    assert_no_difference -> { @session.logs.count } do
      TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(@session)
    end
  end

  test "does not warn when the goal is not about pull requests" do
    @session.update!(goal: "Research the codebase and answer the question inline.")

    assert_no_difference -> { @session.logs.count } do
      TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(@session)
    end
  end

  # The fork carve-out cannot ride on the goal check. ForkSessionService copies
  # the source's goal onto a status-summary fork, and the generator only strips
  # it in #prepare_fork — which #abandon_fork runs before on its early-exit
  # paths, archiving a throwaway that still says "open a PR".
  test "does not warn about a status-summary fork that still carries its inherited goal" do
    @session.update!(
      goal: "Open a PR and leave it unmerged for review.",
      metadata: @session.metadata.to_h.merge(SessionStatusSummaryGenerator::FORK_MARKER => 12_345)
    )

    assert_no_difference -> { @session.logs.count } do
      TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(@session)
    end
  end

  test "does not warn when the session has no goal" do
    @session.update!(goal: nil)

    assert_no_difference -> { @session.logs.count } do
      TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(@session)
    end
  end

  test "swallows errors raised while warning" do
    @session.update!(goal: "Open a PR.")
    @session.stub(:logs, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_nothing_raised { TranscriptHooks::GithubPrUrlHook.warn_if_pr_goal_captured_no_url(@session) }
    end
  end
end

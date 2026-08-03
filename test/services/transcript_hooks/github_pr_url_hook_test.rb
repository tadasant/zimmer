require "test_helper"

# The hook's specification is a matrix: (where the URL appeared) × (does the
# transcript show THIS session opening it). Only the second column decides
# whether the URL is recorded — the first decides how much evidence is needed.
#
#   where it appeared                          | this session opened it | recorded
#   -------------------------------------------|------------------------|---------
#   successful `gh pr create` result           | yes                    | yes
#   failed `gh pr create`, "already exists"    | yes (same repo)        | yes
#   failed `gh pr create`, other failure       | unknown                | no
#   `gh pr view` / `gh pr list` / WebFetch     | no                     | no
#   assistant prose claiming creation          | yes (same repo)        | yes
#   assistant prose merely referencing a PR    | no                     | no
#   user message (incl. Zimmer notifications)  | no                     | no
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

  test "ignores same-repo PRs listed by gh pr list" do
    run_hook(
      claude_shell_call(id: "toolu_list", command: "gh pr list --json url"),
      claude_tool_result(id: "toolu_list", content: '[{"url":"https://github.com/owner/repo/pull/1"},{"url":"https://github.com/owner/repo/pull/2"}]')
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

  test "codex: records a PR opened via the local_shell_call argv variant" do
    @session.update!(agent_runtime: "codex")

    run_hook(
      codex_local_shell_call(call_id: "call_1", command: [ "bash", "-lc", "gh pr create --fill" ]),
      codex_exec_end(call_id: "call_1", exit_code: 0),
      codex_output(call_id: "call_1", output: "https://github.com/owner/repo/pull/11")
    )

    assert_equal [ "https://github.com/owner/repo/pull/11" ], tracked_urls
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

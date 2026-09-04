# frozen_string_literal: true

require "test_helper"

# The retroactive half of https://github.com/tadasant/zimmer/issues/870: #899
# stopped the classifier reading a *quoted* mention of `gh pr comment` as a post,
# and this task deletes the rows an earlier reading already wrote
# (https://github.com/tadasant/zimmer/issues/907).
#
# Tested from both sides deliberately, because both failures are silent. Deleting
# a CORRECT row re-opens the cross-session self-reply loop #250 exists to stop;
# leaving a poisoned one costs what the status quo already costs and looks exactly
# like the task having correctly found nothing. So a genuine post surviving is as
# much of an assertion here as a false positive being removed — and every row the
# transcript cannot vouch for either way is asserted to SURVIVE, which is the
# direction this task is deliberately biased in.
class SweepMisrecordedAgentPostedGithubCommentsTest < ActiveSupport::TestCase
  POSTED_URL = "https://github.com/tadasant/tadasant-internal/pull/281#issuecomment-5145406778"
  POSTED_ID = 5_145_406_778
  PARENT_URL = "https://github.com/tadasant/tadasant-internal/pull/281"

  setup do
    @entry = PostDeployTask::Registry.find("20260904193000")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
    AgentPostedGithubComment.delete_all
  end

  # --- fixtures --------------------------------------------------------------

  def a_session(transcript: nil)
    Session.create!(
      prompt: "poster #{SecureRandom.hex(4)}",
      agent_runtime: "claude_code",
      status: :archived,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      transcript: transcript
    )
  end

  # The Claude Code shape: one Bash tool_use and the tool_result it produced.
  def claude_transcript(command:, output:, is_error: false)
    <<~JSONL
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":#{command.to_json}}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":#{output.to_json},"is_error":#{is_error}}]}}
    JSONL
  end

  # A real post: `gh pr comment` prints the new comment's permalink and nothing else.
  def genuine_post_transcript(url: POSTED_URL)
    claude_transcript(command: "gh pr comment 281 --repo tadasant/tadasant-internal --body 'done'", output: url)
  end

  # The same false positive over an arbitrary permalink.
  def quoted_mention_transcript_for(url)
    claude_transcript(command: %q(grep -rn "gh pr comment" docs/), output: "docs/src/content/docs/limitations.md:1:#{url}")
  end

  # The #870 false positive: a grep for the literal over this repo, whose own
  # source and docs quote both the command and example permalinks. Pre-#899 this
  # was read as a post and its output's permalinks recorded.
  def quoted_mention_transcript
    output = <<~OUT
      app/services/transcript_hooks/github_comment_authorship_hook.rb:44:  #   gh pr comment / gh issue comment
      docs/src/content/docs/limitations.md:2637:`gh pr comment` prints #{POSTED_URL}
    OUT
    claude_transcript(command: %q(grep -rn "gh pr comment" app/ docs/), output: output)
  end

  # The Codex rollout shape: a `function_call` carrying joined argv, its exit code
  # on a separate event_msg line, and a `function_call_output`.
  def codex_session(command:, output:)
    argv = { "command" => [ "bash", "-lc", command ] }.to_json
    transcript = <<~JSONL
      {"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"call_1","arguments":#{argv.to_json}}}
      {"type":"event_msg","payload":{"type":"exec_command_end","call_id":"call_1","exit_code":0}}
      {"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":#{output.to_json}}}
    JSONL
    session = a_session(transcript: transcript)
    session.update!(agent_runtime: "codex")
    session
  end

  def a_row(session:, comment_id: POSTED_ID, comment_type: "pr", comment_url: POSTED_URL, pr_url: PARENT_URL)
    AgentPostedGithubComment.create!(
      session: session,
      comment_type: comment_type,
      comment_id: comment_id,
      comment_url: comment_url,
      pr_url: pr_url
    )
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    assert run.claim!(owner: "test"), "the ledger row must be claimable"
    outcome = @task_class.new(run: run, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  # --- the two directions that matter ----------------------------------------

  test "keeps a row the fixed classifier still reads as an agent post" do
    row = a_row(session: a_session(transcript: genuine_post_transcript))

    run, outcome = run_task

    assert_nil outcome, "one batch is the whole sweep here"
    assert AgentPostedGithubComment.exists?(row.id),
      "deleting a correct row re-opens the self-reply loop #250 exists to stop"
    assert_equal 0, run.stats["rows_deleted"]
    assert_equal 1, run.stats["rows_kept"]
    assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_STILL_A_POST]
  end

  test "deletes a row written by the pre-#899 quoted-mention false positive" do
    row = a_row(session: a_session(transcript: quoted_mention_transcript))

    run, = run_task

    assert_not AgentPostedGithubComment.exists?(row.id),
      "a grep for the literal is a read, and its output was somebody else's comment"
    assert_equal 1, run.stats["rows_deleted"]
    assert_equal 0, run.stats["rows_kept"]
  end

  test "reports enough detail about a deletion to audit it" do
    session = a_session(transcript: quoted_mention_transcript)
    a_row(session: session)

    run, = run_task

    detail = run.stats["deleted_details"].sole
    assert_equal session.id, detail["session_id"]
    assert_equal "pr", detail["comment_type"]
    assert_equal POSTED_ID, detail["comment_id"]
    assert_equal POSTED_URL, detail["comment_url"]
    assert_equal PARENT_URL, detail["pr_url"]
    assert_includes detail["misread_commands"].first, "grep -rn",
      "the command whose output was misread is what makes the verdict checkable"
  end

  test "sorts a mixed population without touching the genuine post" do
    genuine = a_row(session: a_session(transcript: genuine_post_transcript))
    poisoned = a_row(
      session: a_session(transcript: quoted_mention_transcript),
      comment_id: 999_111,
      comment_url: "https://github.com/tadasant/tadasant-internal/pull/281#issuecomment-999111"
    )
    # The poisoned session's grep output has to actually carry that permalink for
    # the sweep to have evidence about it.
    poisoned.session.update!(transcript: quoted_mention_transcript_for(poisoned.comment_url))

    run, = run_task

    assert AgentPostedGithubComment.exists?(genuine.id)
    assert_not AgentPostedGithubComment.exists?(poisoned.id)
    assert_equal 2, run.stats["rows_examined"]
    assert_equal 1, run.stats["rows_deleted"]
    assert_equal 1, run.stats["rows_kept"]
  end

  test "examines several rows recorded by one session against one parse" do
    session = a_session(transcript: claude_transcript(
      command: %q(grep -rn "gh pr comment" docs/),
      output: "a #{POSTED_URL}\nb https://github.com/owner/repo/pull/7#discussion_r424242"
    ))
    pr_row = a_row(session: session)
    review_row = a_row(
      session: session,
      comment_type: "review",
      comment_id: 424_242,
      comment_url: "https://github.com/owner/repo/pull/7#discussion_r424242",
      pr_url: "https://github.com/owner/repo/pull/7"
    )

    run, = run_task

    assert_not AgentPostedGithubComment.exists?(pr_row.id)
    assert_not AgentPostedGithubComment.exists?(review_row.id)
    assert_equal 2, run.stats["rows_deleted"]
  end

  # --- rows the signal cannot reach: all kept, all counted -------------------

  test "keeps a row that carries no recording session" do
    row = a_row(session: nil)

    run, = run_task

    assert AgentPostedGithubComment.exists?(row.id)
    assert_equal 1, run.stats["rows_unreachable"]
    assert_equal 0, run.stats["rows_reachable"]
    assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_NO_SESSION]
  end

  test "keeps a row whose recording session has no stored transcript" do
    row = a_row(session: a_session(transcript: nil))

    run, = run_task

    assert AgentPostedGithubComment.exists?(row.id)
    assert_equal 1, run.stats["rows_unreachable"]
    assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_NO_TRANSCRIPT]
  end

  test "keeps a row whose stored transcript parses to nothing" do
    row = a_row(session: a_session(transcript: "not json\nstill not json\n"))

    run, = run_task

    assert AgentPostedGithubComment.exists?(row.id)
    assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_UNPARSABLE]
  end

  test "reports a vanished recording session as unreachable rather than as a verdict" do
    # The foreign key nullifies `session_id` when a session is destroyed, so this
    # branch is only reachable in the race where the row was loaded first. Asserted
    # directly on the collaborator, since the race cannot be staged through the FK.
    evidence = SweepMisrecordedAgentPostedGithubComments::Evidence.for(-1)

    assert_equal SweepMisrecordedAgentPostedGithubComments::KEPT_SESSION_GONE, evidence.unreachable_reason
  end

  test "keeps a row whose permalink is no longer anywhere in the transcript" do
    # A transcript that says nothing about the comment cannot distinguish a wrong
    # row from one whose evidence has since been trimmed away, so it keeps.
    row = a_row(session: a_session(transcript: claude_transcript(command: "ls -la", output: "README.md")))

    run, = run_task

    assert AgentPostedGithubComment.exists?(row.id)
    assert_equal 1, run.stats["rows_reachable"]
    assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_NO_EVIDENCE]
  end

  test "keeps a row whose only mention is in a failed command's output" do
    # The hook skips `is_error` results, before #899 as after, so no row was ever
    # written from one — and it is not evidence for deleting one either.
    row = a_row(session: a_session(transcript: claude_transcript(
      command: "gh pr comment 281 --body done",
      output: "could not create comment: HTTP 403\n#{POSTED_URL}",
      is_error: true
    )))

    run, = run_task

    assert AgentPostedGithubComment.exists?(row.id)
    assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_NO_EVIDENCE]
  end

  test "keeps a row whose permalink appears only in a result no classifier could have read" do
    # A `Read` of this repo's own limitations.md returns a quoted example permalink.
    # Nothing ever recorded a row from that, so it is not evidence for deleting one —
    # and a deletion with no command behind it is one nobody could audit.
    transcript = <<~JSONL
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"docs/src/content/docs/limitations.md"}}]}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"`gh pr comment` prints #{POSTED_URL}","is_error":false}]}}
    JSONL
    row = a_row(session: a_session(transcript: transcript))

    run, = run_task

    assert AgentPostedGithubComment.exists?(row.id)
    assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_NO_EVIDENCE]
  end

  test "deletes a row written by the pre-#899 reading of a gh api comments READ" do
    # The other population #899 changed: `gh api -X GET .../comments` is `gh`'s own
    # idiom for a GET with query parameters, and an earlier classifier read the field
    # flag as a write — recording every comment in the thread, the human's included.
    listing = [
      { "id" => POSTED_ID, "html_url" => POSTED_URL, "user" => { "login" => "tadasant" } }
    ].to_json
    row = a_row(session: a_session(transcript: claude_transcript(
      command: "gh api -X GET repos/tadasant/tadasant-internal/issues/281/comments -f per_page=100",
      output: listing
    )))

    run, = run_task

    assert_not AgentPostedGithubComment.exists?(row.id),
      "a GET of the comment thread is a read, and everything it listed is somebody else's"
    assert_equal 1, run.stats["rows_deleted"]
    assert_includes run.stats["deleted_details"].sole["misread_commands"].first, "gh api -X GET"
  end

  # --- runtimes and storage formats -----------------------------------------
  #
  # A regression in either would turn every row of that shape into a silent
  # KEPT_NO_EVIDENCE — which looks exactly like the sweep correctly finding
  # nothing, the failure this whole file exists to make impossible.

  test "reads a Codex rollout, keeping the genuine post and deleting the false positive" do
    genuine = codex_session(command: "gh pr comment 281 --body done", output: POSTED_URL)
    poisoned_url = "https://github.com/owner/repo/pull/7#issuecomment-8080"
    poisoned = codex_session(command: %q(grep -rn "gh pr comment" docs/), output: "docs/x.md:1:#{poisoned_url}")

    genuine_row = a_row(session: genuine)
    poisoned_row = a_row(session: poisoned, comment_id: 8080, comment_url: poisoned_url, pr_url: "https://github.com/owner/repo/pull/7")

    run_task

    assert AgentPostedGithubComment.exists?(genuine_row.id), "a Codex post must survive"
    assert_not AgentPostedGithubComment.exists?(poisoned_row.id), "a Codex grep must be swept"
  end

  test "reads the legacy array transcript format" do
    entries = JSON.parse("[" + quoted_mention_transcript.lines.map(&:strip).join(",") + "]")
    row = a_row(session: a_session(transcript: entries))

    run_task

    assert_not AgentPostedGithubComment.exists?(row.id),
      "an array-format transcript is normalized to the JSONL the hook was handed"
  end

  test "keeps a row whose transcript is neither a string nor an array" do
    # The column is `json` and nothing constrains its shape. An odd row must not
    # take the whole task down with it.
    row = a_row(session: a_session(transcript: { "unexpected" => "shape" }))

    run, = run_task

    assert AgentPostedGithubComment.exists?(row.id)
    assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_NO_TRANSCRIPT]
  end

  # --- what `stats` is allowed to grow to -----------------------------------

  test "bounds the detail it puts on the ledger row" do
    max = SweepMisrecordedAgentPostedGithubComments::MAX_DETAILED
    long_command = %(grep -rn "gh pr comment" #{'x' * 400})

    (max + 3).times do |i|
      url = "https://github.com/owner/repo/pull/1#issuecomment-#{900_000 + i}"
      a_row(
        session: a_session(transcript: claude_transcript(command: long_command, output: url)),
        comment_id: 900_000 + i,
        comment_url: url,
        pr_url: "https://github.com/owner/repo/pull/1"
      )
    end

    run, = run_task

    assert_equal max + 3, run.stats["rows_deleted"], "every row is still deleted and counted"
    assert_equal max, run.stats["deleted_details"].size, "the digest is capped"
    assert_operator run.stats["deleted_details"].first["misread_commands"].first.length,
      :<=, SweepMisrecordedAgentPostedGithubComments::MAX_COMMAND_CHARS
  end

  # --- the mechanism ---------------------------------------------------------

  test "is idempotent: a second pass deletes nothing" do
    other_url = "https://github.com/owner/repo/pull/7#issuecomment-4242"
    genuine = a_row(
      session: a_session(transcript: genuine_post_transcript(url: other_url)),
      comment_id: 4242,
      comment_url: other_url,
      pr_url: "https://github.com/owner/repo/pull/7"
    )
    poisoned = a_row(session: a_session(transcript: quoted_mention_transcript))
    unreachable = a_row(session: nil, comment_id: 111, comment_url: nil, pr_url: nil)

    first_run, = run_task
    assert_equal 3, first_run.stats["rows_examined"]
    assert_equal 1, first_run.stats["rows_deleted"]
    assert_not AgentPostedGithubComment.exists?(poisoned.id)

    # A pass from scratch, not a resumed slice: a fresh ledger row means an empty
    # cursor, so the sweep walks the surviving rows again rather than picking up
    # past them.
    PostDeployTaskRun.delete_all

    assert_no_difference "AgentPostedGithubComment.count" do
      second_run, = run_task
      assert_equal 2, second_run.stats["rows_examined"]
      assert_equal 0, second_run.stats["rows_deleted"]
    end

    assert AgentPostedGithubComment.exists?(genuine.id)
    assert AgentPostedGithubComment.exists?(unreachable.id)
  end

  test "an empty table is a valid outcome and is reported as one" do
    run, outcome = run_task

    assert_nil outcome
    assert_equal 0, run.stats["rows_examined"]
    assert_equal 0, run.stats["rows_deleted"]
    assert_equal 0, run.stats["rows_unreachable"]
  end

  test "accumulates every counter across slices rather than restarting them" do
    kept_url = "https://github.com/owner/repo/pull/1#issuecomment-700001"
    kept = a_row(
      session: a_session(transcript: genuine_post_transcript(url: kept_url)),
      comment_id: 700_001, comment_url: kept_url, pr_url: "https://github.com/owner/repo/pull/1"
    )
    doomed = (2..3).map do |i|
      url = "https://github.com/owner/repo/pull/1#issuecomment-70000#{i}"
      a_row(
        session: a_session(transcript: quoted_mention_transcript_for(url)),
        comment_id: 700_000 + i, comment_url: url, pr_url: "https://github.com/owner/repo/pull/1"
      )
    end

    run = PostDeployTaskRun.ledger_for(@entry)
    assert run.claim!(owner: "test")

    # A budget already spent: the sweep yields exactly one batch, then stops on the clock.
    stub_const_batch_size(1) do
      slice = -> { @task_class.new(run: run, deadline: 1.second.ago, logger: Rails.logger).up }

      assert_equal PostDeployTask::CONTINUE, slice.call, "a spent budget must ask to be resumed"
      assert_equal 1, run.reload.stats["rows_examined"]
      assert_equal 0, run.stats["rows_deleted"]
      assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_STILL_A_POST]

      # Each later slice resumes from the cursor and must ADD to every counter.
      assert_equal PostDeployTask::CONTINUE, slice.call
      assert_equal 2, run.reload.stats["rows_examined"]
      assert_equal 1, run.stats["rows_deleted"]
      assert_equal 1, run.stats["deleted_details"].size

      assert_equal PostDeployTask::CONTINUE, slice.call
      assert_equal 3, run.reload.stats["rows_examined"]
      assert_equal 2, run.stats["rows_deleted"]
      assert_equal 2, run.stats["deleted_details"].size,
        "the digest must survive the round trip through stats, not be rebuilt from this slice"
      assert_equal 1, run.stats["kept_by_reason"][SweepMisrecordedAgentPostedGithubComments::KEPT_STILL_A_POST],
        "a kept row must not be counted again on a later slice"
    end

    assert AgentPostedGithubComment.exists?(kept.id)
    doomed.each { |row| assert_not AgentPostedGithubComment.exists?(row.id) }
  end

  private

  # `BATCH_SIZE` is a constant on the task class, and the slicing test needs a
  # batch of one to force a mid-sweep stop.
  def stub_const_batch_size(size)
    original = @task_class.const_get(:BATCH_SIZE)
    @task_class.send(:remove_const, :BATCH_SIZE)
    @task_class.const_set(:BATCH_SIZE, size)
    yield
  ensure
    @task_class.send(:remove_const, :BATCH_SIZE)
    @task_class.const_set(:BATCH_SIZE, original)
  end
end

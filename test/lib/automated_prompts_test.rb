require "test_helper"
require "automated_prompts"

class AutomatedPromptsTest < ActiveSupport::TestCase
  test "system_recovery with no reason is byte-identical to the bare constant" do
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, AutomatedPrompts.system_recovery
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, AutomatedPrompts.system_recovery(reason: nil)
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, AutomatedPrompts.system_recovery(reason: "")
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, AutomatedPrompts.system_recovery(reason: "   ")
  end

  test "system_recovery appends the reason after the standing instructions" do
    prompt = AutomatedPrompts.system_recovery(reason: "an orphan sweep resumed this session")

    assert prompt.start_with?(AutomatedPrompts::SYSTEM_RECOVERY),
      "the reasoned variant must not alter the prompt an agent already knows"
    assert_includes prompt, "an orphan sweep resumed this session"
    assert_includes prompt, "No human sent it."
  end

  test "system_recovery? recognises both the bare and the reasoned prompt" do
    assert AutomatedPrompts.system_recovery?(AutomatedPrompts::SYSTEM_RECOVERY)
    assert AutomatedPrompts.system_recovery?(AutomatedPrompts.system_recovery(reason: "a deploy"))
  end

  # #815: the generic nudge is accurate and useless here — "a system event" invites the
  # agent to re-run the exact command that just exhausted the session's memory bound.
  test "memory_limit_recovery names the bound and what to do differently" do
    prompt = AutomatedPrompts.memory_limit_recovery(limit: "4 GB", peak: "4 GB")

    assert_includes prompt, "memory limit of 4 GB"
    assert_includes prompt, "peak usage: 4 GB"
    assert_includes prompt, "NOT USER INPUT"
    assert_match(/nothing outside this session was affected/, prompt,
      "an agent told only that it was killed will reasonably assume the box is broken")
    assert_match(/same limit again/, prompt,
      "the actionable part is 'do it differently', not 'you were killed'")
  end

  # It is not a SYSTEM_RECOVERY variant, and must not be mistaken for one: the paths that
  # treat a recovery nudge specially (preserving scheduled wake-ups, say) are reasoning
  # about a different kind of interruption.
  test "system_recovery? does not claim the memory-limit prompt" do
    assert_not AutomatedPrompts.system_recovery?(
      AutomatedPrompts.memory_limit_recovery(limit: "4 GB", peak: "4 GB")
    )
  end

  test "lost_clone_recovery names the repository and says the uncommitted work is gone" do
    prompt = AutomatedPrompts.lost_clone_recovery(
      git_root: "https://github.com/test/repo.git", branch: "feature/x"
    )

    assert_includes prompt, "NOT USER INPUT"
    assert_includes prompt, "https://github.com/test/repo.git"
    assert_includes prompt, "feature/x"
    assert_match(/uncommitted work in the old tree is gone/i, prompt,
      "an agent that does not know this will commit half of what its transcript says it wrote")
    assert_match(/Do not trust what this conversation says about the state of the tree/, prompt,
      "the transcript is the misleading part; re-reading the tree is the actionable instruction")
  end

  # Same reason as the memory-limit prompt: the paths that treat a recovery nudge
  # specially are reasoning about a different kind of interruption, and this one
  # carries an instruction of its own.
  test "system_recovery? does not claim the lost-clone prompt" do
    assert_not AutomatedPrompts.system_recovery?(
      AutomatedPrompts.lost_clone_recovery(git_root: "https://example.com/r.git", branch: "main")
    )
  end

  # ---- What the merge fired (tadasant/tadasant-internal#1969) ----
  #
  # "Merged" is the end of the work for a PR that fires nothing and the halfway point
  # for a PR whose merge fires a deploy, and a session cannot see which from the
  # inside. So the message answers it, and each branch below is a different answer.

  test "a merge with nothing known about it reads exactly as it always has" do
    plain = AutomatedPrompts.pr_merged_message("https://github.com/tadasant/zimmer/pull/1")

    assert_includes plain, "has been merged"
    assert_includes plain, "Archive this session with your Zimmer tools"
    refute_includes plain, "%{",
      "an unfilled placeholder would ship the template's own syntax to an agent"
    refute_includes plain, "Wait for those runs"
    assert_equal plain,
      AutomatedPrompts.pr_merged_message("https://github.com/tadasant/zimmer/pull/1", merge_commit_sha: nil),
      "an unreadable merge commit must fail open to the message the fleet already knows"
  end

  test "runs still in flight turn the merge into a bounded, sleeping wait" do
    message = AutomatedPrompts.pr_merged_message(
      "https://github.com/tadasant/zimmer/pull/1",
      merge_commit_sha: "abc1234",
      post_merge_runs: [
        { "name" => "Release image", "status" => "in_progress", "conclusion" => nil, "url" => "https://x/1" },
        { "name" => "CI", "status" => "completed", "conclusion" => "success", "url" => "https://x/2" }
      ]
    )

    assert_includes message, "- Release image — in_progress — https://x/1"
    refute_includes message, "https://x/2", "a run that already finished green is not something to wait on"
    assert_includes message, "Wait for those runs before you archive"
    assert_includes message, "wake_me_up_later"
    assert_includes message, "Do NOT park in `needs_input` for it"
    assert_match(/about 10 wakes/, message, "an unbounded wait is a session that never comes back")
  end

  test "a failed run is named as a failure and outranks archiving" do
    message = AutomatedPrompts.pr_merged_message(
      "https://github.com/tadasant/zimmer/pull/1",
      merge_commit_sha: "abc1234",
      post_merge_runs: [
        { "name" => "Deploy", "status" => "completed", "conclusion" => "failure", "url" => "https://x/1" },
        { "name" => "Docs", "status" => "completed", "conclusion" => "skipped", "url" => "https://x/2" }
      ]
    )

    assert_includes message, "already FAILED"
    assert_includes message, "- Deploy — completed / failure — https://x/1"
    refute_includes message, "https://x/2", "a skipped run is not a failure and not a wait"
  end

  test "automation that already finished green says so and leaves the session free to archive" do
    message = AutomatedPrompts.pr_merged_message(
      "https://github.com/tadasant/zimmer/pull/1",
      merge_commit_sha: "abc1234",
      post_merge_runs: [
        { "name" => "CI", "status" => "completed", "conclusion" => "success", "url" => "https://x/1" }
      ]
    )

    assert_includes message, "already finished successfully"
    refute_includes message, "Wait for those runs before you archive"
  end

  # The race this exists for: the poller can see a merge within a second of it
  # happening, before GitHub has created the runs it fired. One command settles it,
  # and an empty answer is explicitly the ordinary archive-now path.
  test "no runs seen hands the session one command rather than a wait" do
    message = AutomatedPrompts.pr_merged_message(
      "https://github.com/tadasant/zimmer/pull/1",
      merge_commit_sha: "abc1234"
    )

    assert_includes message, "gh run list --commit abc1234 --repo tadasant/zimmer --limit 10"
    assert_includes message, "option 1 below applies as written: archive"
    refute_includes message, "Wait for those runs before you archive"
  end

  # GitHub can report `completed` with the conclusion not yet filled in. Reading that
  # as "finished, and not a success" is how a healthy deploy gets announced as a red
  # one, so it counts as still running and the session looks again.
  test "a completed run with no conclusion yet is treated as still running" do
    run = { "name" => "Deploy", "status" => "completed", "conclusion" => nil, "url" => "https://x/1" }

    assert_not AutomatedPrompts.finished_run?(run)
    assert_not AutomatedPrompts.failed_run?(run)

    message = AutomatedPrompts.pr_merged_message(
      "https://github.com/tadasant/zimmer/pull/1", merge_commit_sha: "abc1234", post_merge_runs: [ run ]
    )

    refute_includes message, "already FAILED"
    assert_includes message, "Wait for those runs before you archive"
  end

  # A reading that is not a list of runs is not a list of anything. `Array()` would
  # turn a Hash into a list of pairs and render it as bullets.
  test "a runs value that is not an array reports no runs" do
    section = AutomatedPrompts.post_merge_automation_section(
      runs: { "workflow_runs" => [] }, merge_commit_sha: "abc1234", repo_slug: "o/r"
    )

    assert_includes section, "gh run list --commit abc1234"
    refute_includes section, "Wait for those runs before you archive"
  end

  test "a cancelled deploy counts as a failure and a skipped run does not" do
    assert AutomatedPrompts.failed_run?({ "status" => "completed", "conclusion" => "cancelled" })
    assert AutomatedPrompts.failed_run?({ "status" => "completed", "conclusion" => "timed_out" })
    assert_not AutomatedPrompts.failed_run?({ "status" => "completed", "conclusion" => "skipped" })
    assert_not AutomatedPrompts.failed_run?({ "status" => "completed", "conclusion" => "success" })
    assert_not AutomatedPrompts.failed_run?({ "status" => "in_progress", "conclusion" => nil })
  end

  test "repo_slug_from_pr_url claims only a PR url" do
    assert_equal "tadasant/zimmer",
      AutomatedPrompts.repo_slug_from_pr_url("https://github.com/tadasant/zimmer/pull/1")
    assert_nil AutomatedPrompts.repo_slug_from_pr_url("https://github.com/tadasant/zimmer/issues/1")
    assert_nil AutomatedPrompts.repo_slug_from_pr_url(nil)
  end

  # A message that names a repo it cannot name must still be usable: the section drops
  # the `--repo` flag rather than printing an empty one.
  test "a PR url the slug reader cannot parse still yields a runnable command" do
    section = AutomatedPrompts.post_merge_automation_section(
      runs: [], merge_commit_sha: "abc1234", repo_slug: nil
    )

    assert_includes section, "gh run list --commit abc1234 --limit 10"
    refute_includes section, "--repo "
  end

  # The re-read that suppresses a stale conflict notice needs the PR the notice
  # is about, and an EnqueuedMessage row carries only its content. So the reader
  # has to survive a reworded template — a silent nil here would silently disable
  # the guard behind tadasant/zimmer#835, not break anything visibly.
  test "merge_conflict_pr_url reads back the URL merge_conflict_message wrote" do
    url = "https://github.com/tadasant/zimmer/pull/834"

    assert_equal url, AutomatedPrompts.merge_conflict_pr_url(AutomatedPrompts.merge_conflict_message(url))
  end

  test "merge_conflict_pr_url claims nothing that is not a merge-conflict message" do
    assert_nil AutomatedPrompts.merge_conflict_pr_url(nil)
    assert_nil AutomatedPrompts.merge_conflict_pr_url(:symbol)
    assert_nil AutomatedPrompts.merge_conflict_pr_url("go fix the build")
    assert_nil AutomatedPrompts.merge_conflict_pr_url(AutomatedPrompts::HEARTBEAT)
    assert_nil AutomatedPrompts.merge_conflict_pr_url(
      AutomatedPrompts.pr_merged_message("https://github.com/tadasant/zimmer/pull/834")
    )
  end

  test "system_recovery? rejects anything else" do
    assert_not AutomatedPrompts.system_recovery?(nil)
    assert_not AutomatedPrompts.system_recovery?(:symbol)
    assert_not AutomatedPrompts.system_recovery?("go fix the build")
    assert_not AutomatedPrompts.system_recovery?(AutomatedPrompts::HEARTBEAT)
    assert_not AutomatedPrompts.system_recovery?(AutomatedPrompts.pr_merged_message("https://example.com/pull/1"))
  end

  # A prompt that names no task of its own is the one AgentSessionJob must not deliver
  # into a conversation that does not exist (#401). Both members matter, and so does
  # the REASONED variant: nearly every real sender calls system_recovery(reason:), so a
  # nudge? that only recognised the bare constant would leave the deploy sweep, the
  # orphan sweep, the spot-queue resume and the auth-outage unpark unprotected while
  # every test still passed.
  test "nudge? recognises the prompts that only mean something against an existing conversation" do
    assert AutomatedPrompts.nudge?(AutomatedPrompts::SYSTEM_RECOVERY)
    assert AutomatedPrompts.nudge?(AutomatedPrompts.system_recovery(reason: "the deploy sweep"))
    assert AutomatedPrompts.nudge?(AutomatedPrompts::HEARTBEAT)
  end

  # The rest carry their own instruction — a limit and what to do about it, a PR to
  # fix, a merge that happened — so they are ordinary turns and must not be replaced.
  test "nudge? claims nothing that carries its own instruction" do
    assert_not AutomatedPrompts.nudge?(nil)
    assert_not AutomatedPrompts.nudge?(:symbol)
    assert_not AutomatedPrompts.nudge?("")
    assert_not AutomatedPrompts.nudge?("Post the alert triage summary to #alerts")
    assert_not AutomatedPrompts.nudge?(AutomatedPrompts.memory_limit_recovery(limit: "4 GB", peak: "4.1 GB"))
    assert_not AutomatedPrompts.nudge?(AutomatedPrompts.merge_conflict_message("https://example.com/pull/1"))
    assert_not AutomatedPrompts.nudge?(AutomatedPrompts.pr_merged_message("https://example.com/pull/1"))
    assert_not AutomatedPrompts.nudge?(
      AutomatedPrompts.lost_clone_recovery(git_root: "https://example.com/r.git", branch: "main")
    )
  end
end

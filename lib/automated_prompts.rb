# frozen_string_literal: true

# AutomatedPrompts provides centralized constants for automated prompts sent
# to Claude Code by the Zimmer system.
#
# These prompts are sent automatically after system events (deployment recovery,
# session restart, health monitor retry) and are NOT user-initiated messages.
# The prompt wording is carefully chosen to communicate this context to the agent.
#
# @example
#   AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
module AutomatedPrompts
  # Prompt sent when the system automatically continues a session after:
  # - Deployment restart (DeploymentRecoveryJob)
  # - Session restart from failed state (SessionsController#restart)
  # - Health monitor retry (HealthMonitorService)
  # - Process death recovery (SessionsController#restore_agent_session_job)
  #
  # This prompt clarifies to the agent that:
  # 1. This is an automated system message, not user input
  # 2. A system interruption occurred (deployment, crash, etc.)
  # 3. The agent should resume its previous work if incomplete
  # 4. The agent should wait for human input if it was already waiting
  #
  # The prompt avoids the word "continue" which could be misinterpreted as
  # user agreement with a previous agent question or proposal.
  SYSTEM_RECOVERY = <<~PROMPT.strip
    [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

    This session may have been interrupted by a system event (deployment restart, process termination, or transient failure). This is an automated nudge from Zimmer to check on your status.

    If you were in the middle of a task, please continue where you left off.

    If you had completed your work and were waiting for human input, please wait - the human will respond when ready.
  PROMPT

  # Build a SYSTEM_RECOVERY nudge that names the path that sent it.
  #
  # A dozen different code paths enqueue this one constant — a deploy, an orphan sweep,
  # a SIGTERM retry, an API-error retry, an auth blip, a quota park lifting, a manual
  # restart. Sending all of them the same undifferentiated string means neither the agent
  # reading it nor the human reading the transcript over its shoulder can tell which
  # happened, and "I would only expect this on a deploy" is the reasonable conclusion it
  # invites. The reason is one line, appended after the standing instructions so the
  # meaning of the prompt is unchanged for an agent that ignores it.
  #
  # @param reason [String, nil] short phrase naming the emitting path; omit for the bare prompt
  # @return [String]
  def self.system_recovery(reason: nil)
    return SYSTEM_RECOVERY if reason.blank?

    "#{SYSTEM_RECOVERY}\n\n(What triggered this nudge: #{reason}. No human sent it.)"
  end

  # Whether `prompt` is a SYSTEM_RECOVERY nudge, with or without a reason suffix.
  #
  # Compare with this rather than `==` against the constant: a reasoned variant is still
  # a recovery nudge, and treating it as an ordinary follow-up would, for example,
  # consume the scheduled wake-ups that `resume_for_system_recovery!` exists to preserve.
  #
  # @param prompt [Object]
  # @return [Boolean]
  def self.system_recovery?(prompt)
    prompt.is_a?(String) && prompt.start_with?(SYSTEM_RECOVERY)
  end

  # Prompt sent when the kernel killed the agent process because the session reached
  # its own memory limit (SessionMemoryCgroup).
  #
  # SYSTEM_RECOVERY would resume the session accurately but blindly: "a system event"
  # invites the agent to retry the exact command that just died, and it will die again.
  # This says what the limit was, what it means, and what to do differently — which is
  # the "error the agent can see and react to" that tadasant/zimmer#815 asked for, as
  # opposed to a bare `Killed` and exit 137.
  MEMORY_LIMIT_RECOVERY_TEMPLATE = <<~PROMPT.strip
    [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

    This session was killed by the kernel because it reached its memory limit of %{limit} (peak usage: %{peak}). Zimmer gives every session its own memory bound so that one runaway command cannot take down the other sessions on the box — so this was your session's own limit, not a machine-wide failure, and nothing outside this session was affected.

    Zimmer has resumed you. Before you pick up where you left off, consider what was allocating: the usual cause is a command that holds a large result in memory rather than streaming it — a command substitution over a big output, reading a large file into a variable, an unbounded glob, or a pipeline whose left side produces far more than the right side consumes.

    If you were running something like that, do it a different way: write to a file and read it back in pieces, pipe into `head`/`grep`/`awk` so the data is never held whole, or narrow the input. Re-running the same command unchanged will hit the same limit again.

    If you were in the middle of a task and nothing you were doing looks memory-hungry, continue where you left off.
  PROMPT

  # Build the memory-limit recovery nudge.
  #
  # @param limit [String] human-readable bound, e.g. "4 GB"
  # @param peak [String] human-readable high-water mark for the session
  # @return [String]
  def self.memory_limit_recovery(limit:, peak:)
    format(MEMORY_LIMIT_RECOVERY_TEMPLATE, limit: limit, peak: peak)
  end

  # Prompt sent when the merge conflict poller detects that a session's PR
  # has merge conflicts with the base branch.
  #
  # This prompt:
  # 1. Identifies itself as an automated system message
  # 2. Tells the agent which PR has conflicts
  # 3. Instructs the agent to resolve conflicts before handing back to the user
  MERGE_CONFLICT_TEMPLATE = <<~PROMPT.strip
    [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

    There are merge conflicts on your PR (%{pr_url}). The base branch has diverged and your PR can no longer be merged cleanly.

    Please try to resolve the merge conflicts before handing back to the user. You can:
    1. Fetch the latest base branch and rebase or merge it into your branch
    2. Resolve any conflicts
    3. Push the updated branch

    If you are unable to resolve the conflicts automatically, let the user know what conflicts exist so they can help.
  PROMPT

  # Prompt sent when the PR poller sees one of a session's PRs go from open to
  # merged.
  #
  # A merge is the end of the road for some sessions and the starting gun for
  # others, and Zimmer cannot tell which from the outside — so the message names
  # both outcomes and hands the choice to the agent. It also says plainly that an
  # unanswered human request outranks archiving, because the failure mode that
  # actually costs the human something is a session that archives itself on top
  # of a question they asked and never got an answer to.
  #
  # `%{post_merge_automation}` is where the poller's reading of what the merge
  # actually SET IN MOTION goes — see post_merge_automation_section. For a PR whose
  # merge fires a deploy, merged is roughly the halfway point: the deploy takes
  # minutes and can fail for reasons that only exist on the deploy path, and the
  # session archiving on this message is the one holding the context to diagnose it
  # (tadasant/tadasant-internal#1969). Empty for a merge that fired nothing
  # detectable, which is the common case and leaves this message byte-identical to
  # what it has always been.
  PR_MERGED_TEMPLATE = <<~PROMPT.strip
    [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

    PR %{pr_url}, associated with this session, has been merged. This is Zimmer reporting a state change on GitHub — no human is speaking to you right now.
    %{post_merge_automation}
    Decide which of these two applies, and act on it:

    1. Nothing is left in this session's scope. The PR was the deliverable, and no human message in this conversation is still waiting on you. Archive this session with your Zimmer tools so it stops sitting in your human's queue.

    2. You were waiting on this merge to keep going — to rebase onto it, to start the next piece of work, or to verify something downstream. Do that work now.

    If a human asked you for something in this session that you have not delivered yet, that outranks archiving: finish it, or report back to them, and leave the session open for them to read.
  PROMPT

  # Prompt sent by HeartbeatSweepJob when a session with an active per-session
  # heartbeat is found in the needs_input state. The heartbeat nudges the agent
  # to keep working toward its goal, and tells it how to stop the heartbeat via
  # its Zimmer tools once there is genuinely nothing left to do (so
  # the beat does not loop forever against a session parked for a human).
  HEARTBEAT = <<~PROMPT.strip
    [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

    This session is under heartbeat monitoring because your human wants you to work toward full completion of the goal. If there is any way for you to continue making progress, please do so now.

    If you are genuinely blocked and there is nothing you can do without human input, use your Zimmer tools to turn off this session's heartbeat (set heartbeat_enabled to false) so we don't keep beating over and over.
  PROMPT

  # Whether `prompt` is a nudge — a message that names no task of its own and only
  # means anything read against a conversation that already exists ("continue where
  # you left off", "keep making progress toward the goal").
  #
  # The distinction matters wherever a turn may be delivered into a conversation that
  # is NOT there: a nudge arriving in an empty context tells the agent to carry on
  # with nothing, so it does nothing and the session comes to rest looking finished
  # (zimmer#401). AgentSessionJob asks this both about the prompt it was handed and
  # about the prompt it would replay instead, so a session whose `prompt` column has
  # itself been overwritten with a nudge — HeartbeatSweepJob does exactly that — is
  # not "recovered" by replaying one nudge in place of another.
  #
  # Deliberately narrow. The other automated prompts here carry their own instruction
  # (a memory limit and what to do about it, a PR to fix, a merge that happened), so
  # they are ordinary turns, not nudges.
  #
  # @param prompt [Object]
  # @return [Boolean]
  def self.nudge?(prompt)
    return false unless prompt.is_a?(String)

    system_recovery?(prompt) || prompt.start_with?(HEARTBEAT)
  end

  # Reads the PR URL back out of a merge-conflict message.
  #
  # The pattern lives next to the template it parses on purpose. A conflict
  # notice is re-validated against GitHub at the moment it is taken off a
  # session's queue (EnqueuedMessage#stale?), which needs the PR the notice is
  # about — and an EnqueuedMessage row carries only its content and its origin.
  # Keeping the writer and the reader in one file is what stops a reworded
  # template from silently disabling that check; the round trip is asserted in
  # test/lib/automated_prompts_test.rb.
  MERGE_CONFLICT_PR_URL_PATTERN = /merge conflicts on your PR \((\S+?)\)/

  # Build a merge conflict automated message for a specific PR URL
  #
  # @param pr_url [String] The full GitHub PR URL (e.g., "https://github.com/owner/repo/pull/123")
  # @return [String] The formatted automated message
  def self.merge_conflict_message(pr_url)
    format(MERGE_CONFLICT_TEMPLATE, pr_url: pr_url)
  end

  # The PR URL a merge-conflict message names, or nil if this is not one.
  #
  # @param prompt [Object]
  # @return [String, nil]
  def self.merge_conflict_pr_url(prompt)
    return nil unless prompt.is_a?(String)

    prompt[MERGE_CONFLICT_PR_URL_PATTERN, 1]
  end

  # What a session must do about post-merge automation, whichever branch it is on.
  #
  # One block, shared by every branch of post_merge_automation_section, so a
  # session that finds runs for itself gets the same rules as one the poller
  # listed them for. The wait is deliberately BOUNDED and deliberately a sleep:
  # a deploy is a machine wait, so parking in `needs_input` for it would put a
  # session in the human's action queue with nothing for a human to do — and an
  # unbounded wait would leave a session sleeping on a workflow that never ends.
  POST_MERGE_AUTOMATION_RULES = <<~RULES.strip
    Wait for those runs before you archive. This is a machine wait, not a human handoff — sleep on it with `wake_me_up_later` (about 2 minutes at a time) and re-check on each wake with `gh run view <run id> --repo <owner>/<repo>`. Do NOT park in `needs_input` for it, and do NOT watch it with a foreground or background shell loop. Bound the wait: about 10 wakes, roughly 20 minutes in total.

    - **Every run finished successfully** — the merge is complete. Option 1 below applies: archive.
    - **A run failed** — you hold more context about this change than anyone else does, and archiving throws it away at the moment it is worth most. Read the failing job's log, then either fix it (a follow-up PR, through the `open-pr` skill) or say in your final message what failed and why it is not yours to fix. Never archive silently on a red run.
    - **Still running when your budget is spent** — name the runs in your final message and archive anyway. Do not sleep indefinitely.
  RULES

  # The paragraph the merged-PR message carries about what the merge set in motion.
  #
  # Four shapes, and which one a session gets is a fact about its own merge rather
  # than a guess it has to make — that is the whole point. A session cannot see
  # whether its repository deploys on merge, so the message has to say:
  #
  #   - runs already failed      — the deploy is red now; do not archive on top of it
  #   - runs still in flight     — wait for them under POST_MERGE_AUTOMATION_RULES
  #   - runs all finished green  — nothing to wait for, said explicitly
  #   - no runs seen             — one command to settle it, then the ordinary path
  #
  # The last one is the race guard. The poller can detect a merge within a second
  # or two of it happening, before GitHub has created the workflow runs it fired,
  # and a session told "nothing fired" in that window is exactly the session this
  # whole change exists to stop from archiving into a failing deploy. One `gh run
  # list` seconds later is authoritative where the poller's reading was early, and
  # it costs a session that really did fire nothing a single command.
  #
  # Returns "" when `merge_commit_sha` is nil — the poller could not read the merge
  # commit at all, so there is nothing true to say and the message stays exactly as
  # it was before this branch existed. Failing open is deliberate: an unreadable
  # lookup must not strand a session that has finished its work.
  #
  # @param runs [Array<Hash>] `{ "name" =>, "status" =>, "conclusion" =>, "url" => }`
  # @param merge_commit_sha [String, nil]
  # @param repo_slug [String, nil] "owner/repo", for the commands this text suggests
  # @return [String]
  def self.post_merge_automation_section(runs:, merge_commit_sha:, repo_slug: nil)
    return "" if merge_commit_sha.blank?

    runs = Array(runs)
    repo_flag = repo_slug.present? ? " --repo #{repo_slug}" : ""

    if runs.empty?
      return <<~SECTION.strip
        **Before you archive, settle one thing.** Zimmer saw no workflow runs on merge commit #{merge_commit_sha} when it wrote this message, but it may simply have looked before GitHub created them. If merging this PR deploys or releases anything, merged is the halfway point and not the end.

        Run `gh run list --commit #{merge_commit_sha}#{repo_flag} --limit 10` once. **Empty output — or a command you cannot run — means this merge fired nothing, and option 1 below applies as written: archive.** If it does list runs, wait for them to finish before archiving, and treat a failure as yours to diagnose: you hold more context about this change than anyone else does.
      SECTION
    end

    failed = runs.select { |run| failed_run?(run) }
    unfinished = runs.reject { |run| finished_run?(run) }

    if failed.any?
      <<~SECTION.strip
        **Merging fired automation that has already FAILED. Do not archive on top of it.**

        #{render_runs(failed + unfinished)}

        A merge that fires a deploy can fail for reasons your PR's own CI could not catch, and you hold more context about this change than anyone else does. Read the failing job's log before you do anything else, then either fix it (a follow-up PR, through the `open-pr` skill) or say in your final message what failed and why it is not yours to fix.#{unfinished.any? ? " Runs above that have not finished still need watching — see below." : ""}

        #{POST_MERGE_AUTOMATION_RULES}
      SECTION
    elsif unfinished.any?
      <<~SECTION.strip
        **Merging fired automation that has not finished yet.** For a PR whose merge deploys, merged is roughly the halfway point:

        #{render_runs(unfinished)}

        #{POST_MERGE_AUTOMATION_RULES}
      SECTION
    else
      <<~SECTION.strip
        Merging fired #{runs.size == 1 ? "one workflow run" : "#{runs.size} workflow runs"} on commit #{merge_commit_sha}, and #{runs.size == 1 ? "it has" : "all of them have"} already finished successfully. Nothing is left to wait for on that account.
      SECTION
    end
  end

  # One bullet per run: what it was, where it got to, and where to read it.
  def self.render_runs(runs)
    runs.map do |run|
      state = [ run["status"], run["conclusion"] ].compact_blank.join(" / ")
      "- #{run['name'].presence || 'workflow run'} — #{state.presence || 'state unknown'} — #{run['url']}"
    end.join("\n")
  end

  # A run GitHub has stopped working on, whatever it concluded.
  def self.finished_run?(run)
    run["status"].to_s == "completed"
  end

  # A finished run whose conclusion is one a human would call a failure.
  #
  # `skipped` and `neutral` are not failures, and `cancelled` is: a deploy someone
  # cancelled did not deploy, which is the same fact about production as a red one.
  def self.failed_run?(run)
    finished_run?(run) && !%w[success skipped neutral].include?(run["conclusion"].to_s)
  end

  # Build a PR-merged automated message for a specific PR URL
  #
  # @param pr_url [String] The full GitHub PR URL (e.g., "https://github.com/owner/repo/pull/123")
  # @param post_merge_runs [Array<Hash>] workflow runs on the merge commit, as the
  #   poller read them; empty is meaningful and nil is not distinguished from it
  # @param merge_commit_sha [String, nil] nil when the poller could not read it, which
  #   suppresses the post-merge paragraph entirely
  # @return [String] The formatted automated message
  def self.pr_merged_message(pr_url, post_merge_runs: [], merge_commit_sha: nil)
    section = post_merge_automation_section(
      runs: post_merge_runs,
      merge_commit_sha: merge_commit_sha,
      repo_slug: repo_slug_from_pr_url(pr_url)
    )

    format(
      PR_MERGED_TEMPLATE,
      pr_url: pr_url,
      # The template puts this placeholder on a line of its own between two
      # paragraphs, so "" leaves the blank line that was always there and a
      # section slots in with a blank line on either side.
      post_merge_automation: section.empty? ? "" : "\n#{section}\n"
    )
  end

  # "owner/repo" out of a GitHub PR URL, or nil if it is not one.
  def self.repo_slug_from_pr_url(pr_url)
    return nil unless pr_url.is_a?(String)

    match = pr_url.match(%r{github\.com/([^/]+)/([^/]+)/pull/\d+})
    return nil unless match

    "#{match[1]}/#{match[2]}"
  end
end

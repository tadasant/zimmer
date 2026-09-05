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
  PR_MERGED_TEMPLATE = <<~PROMPT.strip
    [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

    PR %{pr_url}, associated with this session, has been merged. This is Zimmer reporting a state change on GitHub — no human is speaking to you right now.

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

  # Build a PR-merged automated message for a specific PR URL
  #
  # @param pr_url [String] The full GitHub PR URL (e.g., "https://github.com/owner/repo/pull/123")
  # @return [String] The formatted automated message
  def self.pr_merged_message(pr_url)
    format(PR_MERGED_TEMPLATE, pr_url: pr_url)
  end
end

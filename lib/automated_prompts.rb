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

  # Build a merge conflict automated message for a specific PR URL
  #
  # @param pr_url [String] The full GitHub PR URL (e.g., "https://github.com/owner/repo/pull/123")
  # @return [String] The formatted automated message
  def self.merge_conflict_message(pr_url)
    format(MERGE_CONFLICT_TEMPLATE, pr_url: pr_url)
  end
end

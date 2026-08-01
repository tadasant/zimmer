# frozen_string_literal: true

require "test_helper"
require "open3"

# The hook body is the only executable this catalog ships, and it runs inside an
# agent's session where nobody watches its output. Its contract is with an
# external runtime — Claude Code invokes it as a PostToolUse hook, hands it a JSON
# payload on stdin, and reads `hookSpecificOutput` back — so exercise it the way
# the runtime does: a real subprocess, real stdin, real stdout.
class GitPushCiReminderTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("hooks/git-push-ci-reminder/git-push-ci-reminder.mjs")

  # Commands that pushed something, so there is CI to wait for.
  REMINDS = [
    "git push",
    "git push origin main",
    "git -C /repo push",
    "git --no-pager push -u origin feature",
    "cd app && git push --force-with-lease",
    # A --dry-run belonging to some *other* command must not suppress a real push.
    "git push origin main && rsync --dry-run a b"
  ].freeze

  # Commands that pushed nothing.
  STAYS_QUIET = [
    "git push --dry-run",
    "git push -n",
    "git status",
    "git commit -m 'wip'",
    "npm run push"
  ].freeze

  def run_hook(payload)
    stdout, _stderr, status = Open3.capture3("node", SCRIPT.to_s, stdin_data: payload)
    [ stdout, status ]
  end

  def bash_payload(command)
    { tool_name: "Bash", tool_input: { command: command } }.to_json
  end

  test "reminds about CI after a command that actually pushed" do
    REMINDS.each do |command|
      stdout, status = run_hook(bash_payload(command))

      assert_predicate status, :success?, "hook failed on #{command.inspect}"
      assert stdout.present?, "expected a reminder for #{command.inspect}"

      result = JSON.parse(stdout)
      output = result["hookSpecificOutput"]
      assert_equal "PostToolUse", output["hookEventName"]
      assert_match(/wait-for-ci/, output["additionalContext"])
    end
  end

  test "stays silent when nothing was pushed" do
    STAYS_QUIET.each do |command|
      stdout, status = run_hook(bash_payload(command))

      assert_predicate status, :success?, "hook failed on #{command.inspect}"
      assert_equal "", stdout, "expected silence for #{command.inspect}"
    end
  end

  test "ignores tools other than Bash" do
    stdout, status = run_hook({ tool_name: "Read", tool_input: { command: "git push" } }.to_json)

    assert_predicate status, :success?
    assert_equal "", stdout
  end

  test "exits cleanly on malformed input rather than failing the tool call" do
    [ "", "not json", "[]", "{}" ].each do |payload|
      stdout, status = run_hook(payload)

      assert_predicate status, :success?, "hook must never fail the tool call it observes (#{payload.inspect})"
      assert_equal "", stdout
    end
  end
end

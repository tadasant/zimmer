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

  # The first line of the reminder the body injects, on either runtime.
  REMINDER_FIRST_LINE = "A git push just ran. Pushing is not the same as finishing:"

  # Commands that pushed something, so there is CI to wait for.
  REMINDS = [
    "git push",
    "git push origin main",
    "git -C /repo push",
    "git --no-pager push -u origin feature",
    "cd app && git push --force-with-lease",
    # A --dry-run belonging to some *other* command must not suppress a real push.
    "git push origin main && rsync --dry-run a b",
    # Quoted. A quote is a boundary like any other, on both sides of the invocation:
    # missing these reads as a hook that never fired, which is how zimmer#1073
    # misread the Pi runtime. The bare `push"` cases are the ones that need the
    # CLOSING quote to count — with arguments after it, whitespace already does.
    %q(echo "git push origin main"),
    %q(bash -c 'git push origin main'),
    %q(bash -c "git push"),
    %q(echo "git push")
  ].freeze

  # Commands that pushed nothing.
  STAYS_QUIET = [
    "git push --dry-run",
    "git push -n",
    # A closing quote ends the flag the way whitespace does; without that, widening
    # the matcher for quotes would have started reminding about dry runs.
    %q(bash -c "git push --dry-run"),
    %q(bash -c 'git push -n'),
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

  # The Pi half of the contract, which the live Pi test covers only when PI_E2E=1 —
  # i.e. never in CI, on a runner with no `pi` binary. The defect that made AIR hooks
  # look dead on Pi lived on this branch, so it gets a runner-independent test: a
  # real subprocess with PI_HOOK=1, Pi's payload naming in, Pi's reply shape out.
  test "answers in Pi's dialect, carrying the command's own output through" do
    payload = {
      event: "tool_result", toolName: "bash",
      input: { command: %q(echo "git push origin main") }, content: "git push origin main"
    }.to_json
    stdout, _stderr, status = Open3.capture3(
      { "PI_HOOK" => "1" }, "node", SCRIPT.to_s, stdin_data: payload
    )

    assert_predicate status, :success?
    reply = JSON.parse(stdout)
    # `content` REPLACES the tool result on Pi, so the command's own output has to
    # come back with it or the model never sees what the command did.
    assert_equal "git push origin main\n\n#{REMINDER_FIRST_LINE}", reply["content"].lines.first(3).join.chomp
    assert_nil reply["hookSpecificOutput"], "the Pi branch must not answer in Claude's dialect"
  end

  test "stays quiet in Pi's dialect when nothing was pushed" do
    payload = {
      event: "tool_result", toolName: "bash",
      input: { command: "git status" }, content: "On branch main"
    }.to_json
    stdout, _stderr, status = Open3.capture3(
      { "PI_HOOK" => "1" }, "node", SCRIPT.to_s, stdin_data: payload
    )

    assert_predicate status, :success?
    assert_empty stdout.strip
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

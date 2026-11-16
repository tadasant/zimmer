# frozen_string_literal: true

require "test_helper"

class CycleTimes::ToolClassifierTest < ActiveSupport::TestCase
  def category(tool, args = {}) = CycleTimes::ToolClassifier.classify(tool, args).category
  def shell(command) = category("Bash", { "command" => command })

  test "file tools are local I/O" do
    %w[Read Edit Write MultiEdit Grep Glob TodoWrite Skill ToolSearch].each do |tool|
      assert_equal "local_io", category(tool, { "file_path" => "x.rb" }), tool
    end
  end

  test "web tools and every MCP call are network" do
    assert_equal "network", category("WebFetch", { "url" => "https://x" })
    assert_equal "network", category("WebSearch", { "query" => "q" })
    assert_equal "network", category("mcp__zimmer__get_session", { "session_id" => 1 })
    assert_equal "network", category("mcp__playwright-custom__browser_execute")
  end

  test "subagents and human questions have their own categories" do
    assert_equal "subagent", category("Task", { "description" => "review" })
    assert_equal "subagent", category("Agent", { "subagent_type" => "Explore" })
    assert_equal "wait_human", category("AskUserQuestion")
  end

  test "unknown tools default to local I/O" do
    assert_equal "local_io", category("SomeNewTool")
  end

  test "CI watches are CI waits, whatever surrounds them" do
    assert_equal "wait_ci", shell("gh pr checks 12 --repo a/b --watch --fail-fast")
    assert_equal "wait_ci", shell("cd /x && timeout 900 gh pr checks 12 --watch")
    assert_equal "wait_ci", shell("gh run watch 43768033385 --exit-status")
    assert_equal "wait_ci", shell("until gh pr checks 12 | grep -q pass; do sleep 30; done")
  end

  test "a long plain sleep is a timed sleep, a short one is not" do
    assert_equal "wait_sleep", shell("sleep 60")
    assert_equal "wait_sleep", shell("sleep 2m && gh pr view 12")
    assert_equal "network", shell("sleep 1; gh pr view 12")
  end

  test "network-bound shell commands are network" do
    [
      "gh pr create --fill", "gh api repos/a/b/pulls", "git push -u origin x", "git fetch origin main",
      "git clone https://github.com/a/b", "curl -s https://example.com", "npm ci", "npm install left-pad",
      "bundle install", "pip install requests", "docker pull postgres:16"
    ].each { |command| assert_equal "network", shell(command), command }
  end

  test "local shell commands are local I/O" do
    [
      "bin/rails test test/models/session_test.rb", "git status", "git diff --stat", "bin/rubocop",
      "npm run build", "npx prettier --check .", "ls -la", "grep -rn foo app"
    ].each { |command| assert_equal "local_io", shell(command), command }
  end

  test "Codex shell calls classify by their argv" do
    assert_equal "network", category("shell", { "command" => [ "bash", "-lc", "git push origin x" ] })
    assert_equal "local_io", category("exec_command", { "cmd" => "bin/rails test" })
  end

  test "details are truncated and name the command" do
    result = CycleTimes::ToolClassifier.classify("Bash", { "command" => "echo #{'x' * 500}" })
    assert_operator result.detail.length, :<=, CycleTimes::ToolClassifier::DETAIL_LIMIT
    assert result.detail.start_with?("$ echo")
  end
end

# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# The regression test for tadasant/zimmer#1382: a session spawned against a
# third-party repository with no `.gitignore` entry for Zimmer's injected files
# ran `git commit -a`, and the `.mcp.json` carrying the gateway bearer token and
# the session's own API key was pushed to a public fork.
#
# Nothing is stubbed here. A real `air prepare` and the real post-processor write
# into a real git repository that has no `.gitignore` at all, and the assertions
# are the two commands an agent reaches for: `git status` and `git add -A`.
class InjectedFilesStayOutOfCommitsTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("injected-files-stay-out")
    @repo = File.join(@root, "third-party")
    FileUtils.mkdir_p(@repo)
    git("init", "-q", "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    File.write(File.join(@repo, "README.md"), "# a repository that ignores nothing\n")
    git("add", "README.md")
    git("commit", "-q", "-m", "initial")

    @session = sessions(:active_session)
    @session.update!(
      agent_runtime: "claude_code",
      mcp_servers: [ "playwright-custom" ],
      catalog_skills: [ "open-pr" ],
      metadata: { "agent_root_key" => "general-agent" }
    )
  end

  teardown do
    FileUtils.rm_rf(@root) if @root
  end

  test "a prepared clone of a repository with no .gitignore commits none of the injected files" do
    assert_not File.exist?(File.join(@repo, ".gitignore"))

    AirPrepareService.new(session: @session, working_directory: @repo).prepare!

    # The prepare really did inject what leaked: the MCP config, with the
    # self-session server Zimmer adds to every session, and the skills.
    servers = JSON.parse(File.read(File.join(@repo, ".mcp.json"))).fetch("mcpServers")
    assert_includes servers.keys, "playwright-custom"
    assert_includes servers.keys, SelfSessionInjector::SELF_SESSION_SERVER_NAME
    assert File.directory?(File.join(@repo, ".claude", "skills"))

    assert_equal "", git("status", "--porcelain", "--untracked-files=all"),
      "git status shows injected files"

    git("add", "-A")
    assert_equal "", git("diff", "--cached", "--name-only"), "git add -A staged injected files"

    File.write(File.join(@repo, "agent_change.rb"), "puts :hi\n")
    git("add", "-A")
    assert_equal "agent_change.rb", git("diff", "--cached", "--name-only").strip,
      "the guard must not hide the agent's own work"
  end

  test "a re-prepare leaves the exclude exactly as the first one did" do
    service = AirPrepareService.new(session: @session, working_directory: @repo)
    service.prepare!
    first = File.read(File.join(@repo, ".git", "info", "exclude"))

    AirPrepareService.new(session: @session, working_directory: @repo).prepare!

    assert_equal first, File.read(File.join(@repo, ".git", "info", "exclude"))
  end

  private

  def git(*args)
    stdout, stderr, status = Open3.capture3("git", "-C", @repo, *args)
    assert status.success?, "git #{args.join(' ')} failed: #{stderr}"
    stdout
  end
end

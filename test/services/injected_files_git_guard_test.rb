# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

class InjectedFilesGitGuardTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:active_session)
    @root = Dir.mktmpdir("injected-files-git-guard")
    @repo = File.join(@root, "repo")
    init_repo!(@repo)
  end

  teardown do
    FileUtils.rm_rf(@root) if @root
  end

  test "excludes every injected path in a repository with no .gitignore" do
    write_injected_files!(@repo)

    added = InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)

    assert_includes added, "/.mcp.json"
    assert_includes added, "/.env"
    assert_includes added, "/.claude/"
    assert_includes added, "/claude_stderr.log"
    assert_equal "", git(@repo, "status", "--porcelain", "--untracked-files=all")
    git(@repo, "add", "-A")
    assert_equal "", git(@repo, "diff", "--cached", "--name-only")
  end

  test "a file the agent wrote is still staged" do
    write_injected_files!(@repo)
    File.write(File.join(@repo, "feature.rb"), "puts 1\n")

    InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)

    git(@repo, "add", "-A")
    assert_equal "feature.rb", git(@repo, "diff", "--cached", "--name-only").strip
  end

  test "is idempotent: a second apply adds nothing and duplicates no line" do
    first = InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)
    second = InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)

    assert_not_empty first
    assert_empty second
    lines = File.read(exclude_path(@repo)).lines.map(&:strip).reject(&:empty?)
    assert_equal lines.uniq, lines
    assert_equal 1, lines.count(InjectedFilesGitGuard::HEADER)
  end

  test "keeps whatever the exclude already held" do
    File.write(exclude_path(@repo), "*.swp")

    InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)

    lines = File.read(exclude_path(@repo)).lines.map(&:chomp)
    assert_equal "*.swp", lines.first
    assert_includes lines, "/.mcp.json"
  end

  test "anchors the patterns at an agent-root subdirectory, not the repository root" do
    subdir = File.join(@repo, "agents", "foo")
    FileUtils.mkdir_p(subdir)
    write_injected_files!(subdir)
    # The same name at the repository root is the repository's business.
    File.write(File.join(@repo, ".env"), "NOT_INJECTED=1\n")

    InjectedFilesGitGuard.apply!(session: @session, working_directory: subdir)

    assert_includes File.read(exclude_path(@repo)).lines.map(&:chomp), "/agents/foo/.mcp.json"
    assert_equal "?? .env", git(@repo, "status", "--porcelain", "--untracked-files=all").strip
  end

  test "covers a linked worktree through the shared exclude" do
    worktree = File.join(@root, "worktree")
    git(@repo, "worktree", "add", "-q", "-b", "wt", worktree)
    write_injected_files!(worktree)

    InjectedFilesGitGuard.apply!(session: @session, working_directory: worktree)

    assert_equal "", git(worktree, "status", "--porcelain", "--untracked-files=all")
  end

  test "hides Zimmer's rewrite of a secret-bearing file the repository tracks" do
    File.write(File.join(@repo, ".mcp.json"), "{}\n")
    git(@repo, "add", ".mcp.json")
    git(@repo, "commit", "-q", "-m", "ship an mcp config")
    File.write(File.join(@repo, ".mcp.json"), %({"mcpServers":{"x":{"headers":{"Authorization":"Bearer redacted"}}}}\n))

    InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)

    assert_equal "", git(@repo, "status", "--porcelain")
    git(@repo, "commit", "-a", "-q", "--allow-empty", "-m", "commit -a")
    assert_equal "{}\n", git(@repo, "show", "HEAD:.mcp.json")
  end

  test "excludes AGENTS.md only for a runtime that delivers its prompt through it" do
    assert_includes InjectedFilesGitGuard.injected_paths("codex"), "AGENTS.md"
    assert_not_includes InjectedFilesGitGuard.injected_paths("claude_code"), "AGENTS.md"
  end

  test "excludes what every runtime's process writes into the working directory, whatever this session runs" do
    paths = InjectedFilesGitGuard.injected_paths("claude_code")

    %w[claude_stderr.log codex_stderr.log pi_stderr.log codex_events.jsonl codex_last_message.txt].each do |name|
      assert_includes paths, name
    end
  end

  test "a Codex clone commits none of its run's files" do
    codex = Session.new(agent_runtime: "codex")
    %w[codex_events.jsonl codex_last_message.txt codex_stderr.log AGENTS.md .codex/config.toml .agents/skills/x/SKILL.md].each do |relative|
      path = File.join(@repo, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "x")
    end

    InjectedFilesGitGuard.apply!(session: codex, working_directory: @repo)

    assert_equal "", git(@repo, "status", "--porcelain", "--untracked-files=all")
  end

  test "hides a tracked secret-bearing file under an agent-root subdirectory" do
    subdir = File.join(@repo, "agents", "foo")
    FileUtils.mkdir_p(subdir)
    File.write(File.join(subdir, ".mcp.json"), "{}\n")
    git(@repo, "add", "agents/foo/.mcp.json")
    git(@repo, "commit", "-q", "-m", "ship an mcp config in a subdirectory")
    File.write(File.join(subdir, ".mcp.json"), %({"headers":{"X-API-Key":"redacted"}}\n))

    InjectedFilesGitGuard.apply!(session: @session, working_directory: subdir)

    assert_equal "", git(@repo, "status", "--porcelain")
  end

  test "an exclude holding bytes that are not UTF-8 is appended to, not choked on" do
    File.binwrite(exclude_path(@repo), "/caf\xE9.txt\n".b)

    added = InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)

    assert_includes added, "/.mcp.json"
    assert File.binread(exclude_path(@repo)).start_with?("/caf\xE9.txt\n".b)
  end

  test "raises rather than standing down when git cannot read the repository" do
    File.write(File.join(@repo, ".git", "config"), "[core\n\tbroken = \"")

    assert_raises(InjectedFilesGitGuard::Error) do
      InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)
    end
  end

  test "does not run a fsmonitor the clone's config names" do
    marker = File.join(@root, "fsmonitor-ran")
    git(@repo, "config", "core.fsmonitor", "touch #{marker}; false")
    write_injected_files!(@repo)

    InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)

    assert_not File.exist?(marker), "the guard ran the clone's configured fsmonitor"
  end

  test "steps aside for a directory that is not a git repository" do
    plain = File.join(@root, "plain")
    FileUtils.mkdir_p(plain)

    assert_nil InjectedFilesGitGuard.apply!(session: @session, working_directory: plain)
    assert_nil InjectedFilesGitGuard.apply!(session: @session, working_directory: File.join(@root, "missing"))
  end

  test "raises when the exclude cannot be written" do
    info = File.dirname(exclude_path(@repo))
    FileUtils.rm_rf(info)
    File.write(info, "a file where the directory should be")

    assert_raises(InjectedFilesGitGuard::Error) do
      InjectedFilesGitGuard.apply!(session: @session, working_directory: @repo)
    end
  end

  private

  def init_repo!(dir)
    FileUtils.mkdir_p(dir)
    git(dir, "init", "-q", "-b", "main")
    git(dir, "config", "user.email", "test@example.com")
    git(dir, "config", "user.name", "Test")
    File.write(File.join(dir, "README.md"), "# fixture\n")
    git(dir, "add", "README.md")
    git(dir, "commit", "-q", "-m", "initial")
  end

  # One file under every path the guard claims, for a Claude session.
  def write_injected_files!(dir)
    {
      ".mcp.json" => "{}",
      ".env" => "SECRET=redacted",
      ".claude/skills/x/SKILL.md" => "x",
      ".claude/settings.json" => "{}",
      ".codex/config.toml" => "",
      ".agents/skills/x/SKILL.md" => "x",
      ".pi/zimmer-air/hooks.json" => "{}",
      ".npm-cache/_npx/abc/package.json" => "{}",
      ".bundle/config" => "",
      "claude_stderr.log" => "",
      "pi_system_prompt.md" => ""
    }.each do |relative, content|
      path = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  def exclude_path(repo)
    File.join(repo, ".git", "info", "exclude")
  end

  def git(dir, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", dir, *args)
    assert status.success?, "git #{args.join(' ')} failed: #{stderr}"
    stdout
  end
end

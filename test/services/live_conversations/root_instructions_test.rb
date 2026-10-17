# frozen_string_literal: true

require "test_helper"

# Against a real git repository on disk: the fetch is a blobless clone plus
# `git show`, and that is the path worth running.
class LiveConversations::RootInstructionsTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("live-root-repo-")
    git("init", "-q", "-b", "main")
    write("agent-roots/live-mode/AGENTS.md", "# Live Mode\nBe brief.\n")
    write("agent-roots/live-mode/modes/voice.md", "Short spoken turns.\n")
    write("agent-roots/live-mode/modes/text.md", "  \n")
    write("agent-roots/claude-only/CLAUDE.md", "# Only CLAUDE.md\n")
    git("add", "-A")
    git("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "roots")
    # A blobless clone of a local path needs the server side to allow filters.
    git("config", "uploadpack.allowFilter", "true")
  end

  teardown { FileUtils.rm_rf(@dir) }

  test "reads AGENTS.md from the root's subdirectory and says where it came from" do
    result = LiveConversations::RootInstructions.fetch(root("agent-roots/live-mode"))

    assert_equal "# Live Mode\nBe brief.\n", result.text
    assert_match %r{@[0-9a-f]{12}:agent-roots/live-mode/AGENTS\.md\z}, result.source
  end

  test "reads the per-mode style files the root ships, and skips a blank one" do
    result = LiveConversations::RootInstructions.fetch(root("agent-roots/live-mode"))

    assert_equal({ "voice" => "Short spoken turns." }, result.modes)
  end

  test "a root without mode files has no mode styles" do
    result = LiveConversations::RootInstructions.fetch(root("agent-roots/claude-only"))

    assert_equal({}, result.modes)
  end

  test "falls back to CLAUDE.md for a root that only ships that" do
    result = LiveConversations::RootInstructions.fetch(root("agent-roots/claude-only"))

    assert_equal "# Only CLAUDE.md\n", result.text
    assert result.source.end_with?("agent-roots/claude-only/CLAUDE.md")
  end

  test "a root with no instructions file is a readable error" do
    error = assert_raises(LiveConversations::RootInstructions::Error) do
      LiveConversations::RootInstructions.fetch(root("agent-roots/nothing-here"))
    end
    assert_match(/has no AGENTS.md or CLAUDE.md at .*agent-roots\/nothing-here/, error.message)
  end

  test "a repository that cannot be cloned is a readable error" do
    error = assert_raises(LiveConversations::RootInstructions::Error) do
      LiveConversations::RootInstructions.fetch(AgentRootsConfig::AgentRoot.new("gone", { "url" => "file:///nonexistent/repo", "default_branch" => "main" }))
    end
    assert_match(/Could not read agent root gone's instructions: git clone failed/, error.message)
  end

  private

  def root(subdirectory)
    AgentRootsConfig::AgentRoot.new("live-mode", { "url" => "file://#{@dir}", "default_branch" => "main", "subdirectory" => subdirectory })
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(File.join(@dir, path)))
    File.write(File.join(@dir, path), content)
  end

  def git(*args)
    _out, err, status = Open3.capture3("git", *args, chdir: @dir)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
  end
end

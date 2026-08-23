# frozen_string_literal: true

require "test_helper"

class ClaudeSessionConfigDirectoryTest < ActiveSupport::TestCase
  setup do
    @original_config_dir = ENV["CLAUDE_SESSION_CONFIG_DIR"]
    @original_clones_dir = ENV["AGENT_CLONES_DIR"]
  end

  teardown do
    restore_env("CLAUDE_SESSION_CONFIG_DIR", @original_config_dir)
    restore_env("AGENT_CLONES_DIR", @original_clones_dir)
  end

  # --- base ---------------------------------------------------------------

  test "defaults to a claude-config sibling of the clones base" do
    ENV.delete("CLAUDE_SESSION_CONFIG_DIR")
    ENV.delete("AGENT_CLONES_DIR")

    expected = File.join(File.dirname(ClonesDirectory.base), "claude-config")
    assert_equal expected, ClaudeSessionConfigDirectory.base
  end

  test "is a sibling of (not nested under) the clones base so the orphan sweep never reaps it" do
    ENV.delete("CLAUDE_SESSION_CONFIG_DIR")
    ENV.delete("AGENT_CLONES_DIR")

    refute ClaudeSessionConfigDirectory.base.start_with?("#{ClonesDirectory.base}/")
    assert_equal File.dirname(ClonesDirectory.base), File.dirname(ClaudeSessionConfigDirectory.base)
  end

  test "honors the CLAUDE_SESSION_CONFIG_DIR override" do
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = "/mnt/durable/claude-config"

    assert_equal "/mnt/durable/claude-config", ClaudeSessionConfigDirectory.base
  end

  test "blank CLAUDE_SESSION_CONFIG_DIR falls back to the default" do
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = ""
    ENV.delete("AGENT_CLONES_DIR")

    expected = File.join(File.dirname(ClonesDirectory.base), "claude-config")
    assert_equal expected, ClaudeSessionConfigDirectory.base
  end

  # --- path_for / credentials_path_for -------------------------------------

  test "path_for is keyed on the session id and stable across calls" do
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = "/mnt/durable/claude-config"

    assert_equal "/mnt/durable/claude-config/42", ClaudeSessionConfigDirectory.path_for(42)
    assert_equal "/mnt/durable/claude-config/42", ClaudeSessionConfigDirectory.path_for("42")
  end

  test "path_for raises on a blank session id" do
    assert_raises(ArgumentError) { ClaudeSessionConfigDirectory.path_for(nil) }
    assert_raises(ArgumentError) { ClaudeSessionConfigDirectory.path_for("") }
  end

  test "credentials_path_for names the .credentials.json inside the session's dir" do
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = "/mnt/durable/claude-config"

    assert_equal "/mnt/durable/claude-config/7/.credentials.json",
      ClaudeSessionConfigDirectory.credentials_path_for(7)
  end

  # --- ensure_for ----------------------------------------------------------

  test "ensure_for creates the directory and links projects at the shared transcript tree" do
    with_relocated_dirs do |config_base, claude_home|
      path = ClaudeSessionConfigDirectory.ensure_for(123)

      assert_equal File.join(config_base, "123"), path
      assert Dir.exist?(path)

      link = File.join(path, "projects")
      assert File.symlink?(link), "projects must be a symlink, not a directory"
      assert_equal File.join(claude_home, "projects"), File.readlink(link)
    end
  end

  # The transcript tree is what makes this a symlink rather than a fresh dir.
  # CLAUDE_CONFIG_DIR relocates `projects/` along with the credentials, and every
  # Zimmer reader (TranscriptPollerService, AuthRecoveryService, the MCP tools)
  # resolves it under ~/.claude. A real directory here would strand them.
  test "a transcript the CLI writes through the link lands in the shared tree" do
    with_relocated_dirs do |_config_base, claude_home|
      path = ClaudeSessionConfigDirectory.ensure_for(123)

      FileUtils.mkdir_p(File.join(path, "projects", "-some-clone"))
      File.write(File.join(path, "projects", "-some-clone", "abc.jsonl"), "{}\n")

      assert_equal "{}\n", File.read(File.join(claude_home, "projects", "-some-clone", "abc.jsonl"))
    end
  end

  test "ensure_for is idempotent and preserves existing contents" do
    with_relocated_dirs do
      path = ClaudeSessionConfigDirectory.ensure_for(123)
      File.write(File.join(path, ".credentials.json"), '{"mcpOAuth":{}}')

      again = ClaudeSessionConfigDirectory.ensure_for(123)

      assert_equal path, again
      assert_equal '{"mcpOAuth":{}}', File.read(File.join(path, ".credentials.json"))
    end
  end

  test "ensure_for leaves a real projects directory alone rather than replacing it" do
    with_relocated_dirs do |config_base, _claude_home|
      path = File.join(config_base, "123")
      FileUtils.mkdir_p(File.join(path, "projects", "-some-clone"))
      File.write(File.join(path, "projects", "-some-clone", "abc.jsonl"), "{}\n")

      ClaudeSessionConfigDirectory.ensure_for(123)

      refute File.symlink?(File.join(path, "projects"))
      assert_equal "{}\n", File.read(File.join(path, "projects", "-some-clone", "abc.jsonl"))
    end
  end

  # --- cleanup_for ---------------------------------------------------------

  test "cleanup_for removes the session's dir" do
    with_relocated_dirs do
      path = ClaudeSessionConfigDirectory.ensure_for(123)
      File.write(File.join(path, ".credentials.json"), "{}")

      ClaudeSessionConfigDirectory.cleanup_for(123)

      refute Dir.exist?(path)
    end
  end

  # The one way this could go badly wrong: following the symlink and deleting
  # every session transcript on the worker.
  test "cleanup_for deletes the projects symlink and never the tree behind it" do
    with_relocated_dirs do |_config_base, claude_home|
      ClaudeSessionConfigDirectory.ensure_for(123)
      FileUtils.mkdir_p(File.join(claude_home, "projects", "-some-clone"))
      File.write(File.join(claude_home, "projects", "-some-clone", "abc.jsonl"), "{}\n")

      ClaudeSessionConfigDirectory.cleanup_for(123)

      assert_equal "{}\n", File.read(File.join(claude_home, "projects", "-some-clone", "abc.jsonl"))
    end
  end

  test "cleanup_for is a no-op for a blank id or an absent dir" do
    with_relocated_dirs do
      assert_nothing_raised do
        ClaudeSessionConfigDirectory.cleanup_for(nil)
        ClaudeSessionConfigDirectory.cleanup_for(999)
      end
    end
  end

  private

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  # Point both the config base and the shared ~/.claude at temp dirs, so nothing
  # here can touch a real credentials file or transcript tree.
  def with_relocated_dirs
    Dir.mktmpdir("claude-config-base") do |config_base|
      Dir.mktmpdir("claude-home") do |claude_home|
        ENV["CLAUDE_SESSION_CONFIG_DIR"] = config_base
        original = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
        ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
        ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(claude_home, ".credentials.json"))
        begin
          yield config_base, claude_home
        ensure
          ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
          ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original)
        end
      end
    end
  end
end

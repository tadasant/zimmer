# frozen_string_literal: true

require "test_helper"

class SessionScratchDirectoryTest < ActiveSupport::TestCase
  setup do
    @original_scratch_dir = ENV["AGENT_SCRATCH_DIR"]
    @original_clones_dir = ENV["AGENT_CLONES_DIR"]
  end

  teardown do
    restore_env("AGENT_SCRATCH_DIR", @original_scratch_dir)
    restore_env("AGENT_CLONES_DIR", @original_clones_dir)
  end

  # --- base ---------------------------------------------------------------

  test "defaults to a session-scratch sibling of the clones base" do
    ENV.delete("AGENT_SCRATCH_DIR")
    ENV.delete("AGENT_CLONES_DIR")

    expected = File.join(File.dirname(ClonesDirectory.base), "session-scratch")
    assert_equal expected, SessionScratchDirectory.base
  end

  test "is a sibling of (not nested under) the clones base so the orphan sweep never reaps it" do
    ENV.delete("AGENT_SCRATCH_DIR")
    ENV.delete("AGENT_CLONES_DIR")

    refute SessionScratchDirectory.base.start_with?("#{ClonesDirectory.base}/"),
      "scratch base must not live under the clones base"
    assert_equal File.dirname(ClonesDirectory.base), File.dirname(SessionScratchDirectory.base)
  end

  test "honors the AGENT_SCRATCH_DIR override" do
    ENV["AGENT_SCRATCH_DIR"] = "/mnt/durable/session-scratch"

    assert_equal "/mnt/durable/session-scratch", SessionScratchDirectory.base
  end

  test "expands a relative AGENT_SCRATCH_DIR override to an absolute path" do
    ENV["AGENT_SCRATCH_DIR"] = "relative/scratch"

    assert_equal File.expand_path("relative/scratch"), SessionScratchDirectory.base
  end

  test "blank AGENT_SCRATCH_DIR falls back to the default" do
    ENV["AGENT_SCRATCH_DIR"] = ""
    ENV.delete("AGENT_CLONES_DIR")

    expected = File.join(File.dirname(ClonesDirectory.base), "session-scratch")
    assert_equal expected, SessionScratchDirectory.base
  end

  test "is resolved at call time so HOME changes are honored" do
    ENV.delete("AGENT_SCRATCH_DIR")
    ENV.delete("AGENT_CLONES_DIR")

    original_home = ENV["HOME"]
    Dir.mktmpdir("scratch-dir-home") do |tmp_home|
      ENV["HOME"] = tmp_home
      assert_equal File.join(tmp_home, ".zimmer", "session-scratch"),
        SessionScratchDirectory.base
    ensure
      ENV["HOME"] = original_home
    end
  end

  # --- path_for -----------------------------------------------------------

  test "path_for joins the base and the session id" do
    ENV["AGENT_SCRATCH_DIR"] = "/mnt/durable/session-scratch"

    assert_equal "/mnt/durable/session-scratch/42", SessionScratchDirectory.path_for(42)
    assert_equal "/mnt/durable/session-scratch/42", SessionScratchDirectory.path_for("42")
  end

  test "path_for raises on a blank session id" do
    assert_raises(ArgumentError) { SessionScratchDirectory.path_for(nil) }
    assert_raises(ArgumentError) { SessionScratchDirectory.path_for("") }
  end

  test "path_for is keyed on the session id, so it is stable across clone recreation" do
    ENV["AGENT_SCRATCH_DIR"] = "/mnt/durable/session-scratch"

    # The same session id always resolves to the same path, regardless of any
    # clone-path hash that may have changed underneath it.
    first = SessionScratchDirectory.path_for(7)
    second = SessionScratchDirectory.path_for(7)
    assert_equal first, second
  end

  # --- ensure_for / cleanup_for ------------------------------------------

  test "ensure_for creates the directory and returns its path" do
    Dir.mktmpdir("scratch-ensure") do |tmp|
      ENV["AGENT_SCRATCH_DIR"] = tmp

      path = SessionScratchDirectory.ensure_for(123)

      assert_equal File.join(tmp, "123"), path
      assert Dir.exist?(path), "ensure_for should create the directory"
    end
  end

  test "ensure_for is idempotent and preserves existing contents" do
    Dir.mktmpdir("scratch-idempotent") do |tmp|
      ENV["AGENT_SCRATCH_DIR"] = tmp

      path = SessionScratchDirectory.ensure_for(123)
      File.write(File.join(path, "state.txt"), "phase-6-output")

      # Calling again (e.g. on resume) must not wipe existing state.
      again = SessionScratchDirectory.ensure_for(123)

      assert_equal path, again
      assert_equal "phase-6-output", File.read(File.join(path, "state.txt"))
    end
  end

  test "cleanup_for removes the session directory" do
    Dir.mktmpdir("scratch-cleanup") do |tmp|
      ENV["AGENT_SCRATCH_DIR"] = tmp

      path = SessionScratchDirectory.ensure_for(123)
      File.write(File.join(path, "state.txt"), "throwaway")
      assert Dir.exist?(path)

      SessionScratchDirectory.cleanup_for(123)

      refute Dir.exist?(path), "cleanup_for should remove the directory"
    end
  end

  test "cleanup_for is a no-op when the directory does not exist" do
    Dir.mktmpdir("scratch-cleanup-missing") do |tmp|
      ENV["AGENT_SCRATCH_DIR"] = tmp

      assert_nothing_raised { SessionScratchDirectory.cleanup_for(999) }
    end
  end

  test "cleanup_for is a no-op for a blank session id" do
    assert_nothing_raised { SessionScratchDirectory.cleanup_for(nil) }
    assert_nothing_raised { SessionScratchDirectory.cleanup_for("") }
  end

  private

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end

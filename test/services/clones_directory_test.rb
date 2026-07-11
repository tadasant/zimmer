# frozen_string_literal: true

require "test_helper"

class ClonesDirectoryTest < ActiveSupport::TestCase
  setup do
    @original_clones_dir = ENV["AGENT_CLONES_DIR"]
  end

  teardown do
    if @original_clones_dir.nil?
      ENV.delete("AGENT_CLONES_DIR")
    else
      ENV["AGENT_CLONES_DIR"] = @original_clones_dir
    end
  end

  test "defaults to ~/.zimmer/clones under the home directory" do
    ENV.delete("AGENT_CLONES_DIR")

    expected = File.join(File.expand_path("~"), ".zimmer", "clones")
    assert_equal expected, ClonesDirectory.base
  end

  test "honors the AGENT_CLONES_DIR override" do
    ENV["AGENT_CLONES_DIR"] = "/mnt/durable/agent-clones"

    assert_equal "/mnt/durable/agent-clones", ClonesDirectory.base
  end

  test "expands a relative AGENT_CLONES_DIR override to an absolute path" do
    ENV["AGENT_CLONES_DIR"] = "relative/clones"

    assert_equal File.expand_path("relative/clones"), ClonesDirectory.base
  end

  test "is resolved at call time so HOME changes are honored" do
    ENV.delete("AGENT_CLONES_DIR")

    original_home = ENV["HOME"]
    Dir.mktmpdir("clones-dir-home") do |tmp_home|
      ENV["HOME"] = tmp_home
      assert_equal File.join(tmp_home, ".zimmer", "clones"), ClonesDirectory.base
    ensure
      ENV["HOME"] = original_home
    end
  end

  test "blank AGENT_CLONES_DIR falls back to the default" do
    ENV["AGENT_CLONES_DIR"] = ""

    expected = File.join(File.expand_path("~"), ".zimmer", "clones")
    assert_equal expected, ClonesDirectory.base
  end
end

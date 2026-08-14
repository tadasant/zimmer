# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests for EnvFile — the shared reader for a session clone's `.env`.
#
# Two callers depend on it agreeing with itself: CliSpawnEnv (the agent CLI
# process's environment) and RuntimeConfigPostProcessor (each stdio MCP server's
# own env table). The dialect is deliberately small; these lock it down.
class EnvFileTest < ActiveSupport::TestCase
  setup do
    @working_dir = "/clones/session-1"
    @file_system = MockFileSystemAdapter.new
    @logger = Logger.new(File::NULL)
  end

  test "returns an empty hash when the clone has no .env" do
    assert_empty EnvFile.load(@working_dir, file_system: @file_system, logger: @logger)
  end

  test "parses KEY=VALUE, comments, blank lines, quotes and empty values" do
    write_env(<<~ENV)
      # a comment
      PLAIN=value

      DOUBLE="quoted value"
      SINGLE='quoted value'
      EMPTY=
      WITH_EQUALS=a=b
        SPACED_KEY_LINE=trimmed
    ENV

    vars = EnvFile.load(@working_dir, file_system: @file_system, logger: @logger)

    assert_equal "value", vars["PLAIN"]
    assert_equal "quoted value", vars["DOUBLE"]
    assert_equal "quoted value", vars["SINGLE"]
    assert_equal "", vars["EMPTY"]
    assert_equal "a=b", vars["WITH_EQUALS"]
    assert_equal "trimmed", vars["SPACED_KEY_LINE"]
    assert_not vars.key?("# a comment")
  end

  test "skips lines that are not valid variable assignments" do
    write_env(<<~ENV)
      123INVALID=nope
      INVALID-NAME=nope
      no_equals_sign
      VALID=yes
    ENV

    vars = EnvFile.load(@working_dir, file_system: @file_system, logger: @logger)

    assert_equal({ "VALID" => "yes" }, vars)
  end

  test "skips a .env larger than the size cap instead of reading it into memory" do
    write_env("BIG=#{'x' * (EnvFile::MAX_BYTES + 1)}")

    assert_empty EnvFile.load(@working_dir, file_system: @file_system, logger: @logger)
  end

  test "returns an empty hash for a blank working directory instead of probing the filesystem root" do
    assert_empty EnvFile.load(nil, file_system: @file_system, logger: @logger)
    assert_empty EnvFile.load("", file_system: @file_system, logger: @logger)
  end

  test "returns an empty hash rather than raising when the file cannot be read" do
    @file_system.stubs(:exists?).returns(true)
    @file_system.stubs(:read).raises(Errno::EACCES, "denied")

    assert_empty EnvFile.load(@working_dir, file_system: @file_system, logger: @logger)
  end

  private

  def write_env(content)
    @file_system.write(File.join(@working_dir, ".env"), content)
  end
end

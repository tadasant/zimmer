# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests for SessionEnvFile — the writer for a session clone's `.env`.
#
# The values used here are obvious fakes ("value-for-<KEY>"). Nothing in this
# file asserts on, logs, or constructs a real credential, and the assertions are
# on key NAMES so a failure message can never carry one.
class SessionEnvFileTest < ActiveSupport::TestCase
  BUNDLE = %w[SLACK_BOT_TOKEN ZIMMER_PROD_API_KEY STRAD_API_KEY GITHUB_PERSONAL_ACCESS_TOKEN].freeze

  setup do
    @working_dir = "/clones/session-1"
    @path = File.join(@working_dir, EnvFile::FILENAME)
    @file_system = MockFileSystemAdapter.new
    @file_system.mkdir_p(@working_dir)
    SecretsLoader.stubs(:all).returns(BUNDLE.index_with { |key| "value-for-#{key}" })
  end

  def write(session)
    SessionEnvFile.write!(
      session: session,
      working_directory: @working_dir,
      file_system: @file_system
    )
  end

  def session(**attrs)
    Session.new({
      mcp_servers: [], catalog_skills: [], catalog_hooks: [],
      catalog_plugins: [], custom_metadata: {}
    }.merge(attrs))
  end

  def written_keys
    EnvFile.parse(@file_system.read(@path)).keys.sort
  end

  test "writes only the keys the session's own servers declare" do
    result = write(session(mcp_servers: %w[slack-workspace]))

    assert_equal %w[SLACK_BOT_TOKEN], written_keys
    assert_equal %w[SLACK_BOT_TOKEN], result.key_names
    assert_equal BUNDLE.size, result.available_count
  end

  test "a narrowly-provisioned session never receives an unrelated credential" do
    write(session(mcp_servers: %w[zimmer-sessions]))

    assert_equal %w[ZIMMER_PROD_API_KEY], written_keys
    assert_not_includes written_keys, "SLACK_BOT_TOKEN"
    assert_not_includes written_keys, "GITHUB_PERSONAL_ACCESS_TOKEN"
  end

  test "a session with nothing wired gets a .env with no secrets in it" do
    result = write(session)

    assert_empty written_keys
    assert_equal "no secrets", result.summary
  end

  test "the file is written owner-read-write only" do
    @file_system.expects(:chmod).with(0o600, @path).once

    write(session(mcp_servers: %w[slack-workspace]))
  end

  test "values survive the round trip through EnvFile" do
    SecretsLoader.stubs(:all).returns("SLACK_BOT_TOKEN" => 'a"b=c')
    write(session(mcp_servers: %w[slack-workspace]))

    assert_equal 'a\\"b=c', EnvFile.parse(@file_system.read(@path))["SLACK_BOT_TOKEN"],
      "EnvFile does not unescape, so the escaped form is what the consumer sees — " \
      "unchanged from the pre-scoping writer"
  end

  # ---------------------------------------------------------------------------
  # Rewriting: this runs on every prepare
  # ---------------------------------------------------------------------------

  test "a rewrite drops a managed key the session no longer has a server for" do
    write(session(mcp_servers: %w[slack-workspace zimmer-sessions]))
    assert_equal %w[SLACK_BOT_TOKEN ZIMMER_PROD_API_KEY], written_keys

    write(session(mcp_servers: %w[zimmer-sessions]))

    assert_equal %w[ZIMMER_PROD_API_KEY], written_keys,
      "removing a server has to remove its credential, or the narrowing never takes effect"
  end

  test "a rewrite preserves a variable Zimmer does not manage, verbatim" do
    @file_system.write(@path, <<~ENV)
      # operator override
      ELICITATION_REQUEST_URL="https://other.example/api/v1/elicitations"
      WINDOWS_PATH="C:\\\\Users\\\\agent"
    ENV

    write(session(mcp_servers: %w[slack-workspace]))
    content = @file_system.read(@path)

    assert_includes content, "# operator override"
    assert_includes content, 'ELICITATION_REQUEST_URL="https://other.example/api/v1/elicitations"'
    assert_includes content, 'WINDOWS_PATH="C:\\\\Users\\\\agent"',
      "a preserved line is copied as raw text; re-quoting it would double its backslashes"
    assert_includes written_keys, "SLACK_BOT_TOKEN"
  end

  test "a managed key an older unscoped write left behind is dropped even below the header" do
    @file_system.write(@path, <<~ENV)
      #{SessionEnvFile::MANAGED_HEADER}
      SLACK_BOT_TOKEN="stale"
      GITHUB_PERSONAL_ACCESS_TOKEN="stale"
      KEEP_ME="mine"
    ENV

    write(session(mcp_servers: %w[zimmer-sessions]))

    assert_equal %w[KEEP_ME ZIMMER_PROD_API_KEY], written_keys
  end

  test "repeated writes do not accumulate headers" do
    3.times { write(session(mcp_servers: %w[slack-workspace])) }

    assert_equal 1, @file_system.read(@path).scan(SessionEnvFile::MANAGED_HEADER).size
  end

  test "an oversized existing .env is replaced rather than merged" do
    @file_system.write(@path, "JUNK=#{'x' * (EnvFile::MAX_BYTES + 1)}")

    write(session(mcp_servers: %w[slack-workspace]))

    assert_equal %w[SLACK_BOT_TOKEN], written_keys
  end

  test "a log summary lists names up to a limit and counts the rest" do
    names = Array.new(SessionEnvFile::SUMMARY_NAME_LIMIT + 3) { |i| format("KEY_%02d", i) }
    summary = SessionEnvFile::Result.new(key_names: names, available_count: names.size).summary

    assert_includes summary, "KEY_00"
    assert_not_includes summary, names.last
    assert summary.end_with?("(+3 more)")
  end

  test "a new .env is created owner-read-write rather than under the umask" do
    @file_system.expects(:write).with(@path, anything, perm: 0o600).once
    @file_system.stubs(:chmod)

    write(session(mcp_servers: %w[slack-workspace]))
  end

  # ---------------------------------------------------------------------------
  # Degradation
  # ---------------------------------------------------------------------------

  test "returns nil and writes nothing when the deployment holds no secrets" do
    SecretsLoader.stubs(:all).returns({})

    assert_nil write(session(mcp_servers: %w[slack-workspace]))
    assert_not @file_system.exists?(@path)
  end

  test "returns nil without a session or a working directory" do
    assert_nil SessionEnvFile.write!(session: nil, working_directory: @working_dir,
      file_system: @file_system)
    assert_nil SessionEnvFile.write!(session: session, working_directory: "",
      file_system: @file_system)
  end

  test "a write failure is raised for the caller to report, never swallowed here" do
    @file_system.stubs(:write).raises(Errno::EACCES, "denied")

    assert_raises(Errno::EACCES) { write(session(mcp_servers: %w[slack-workspace])) }
  end
end

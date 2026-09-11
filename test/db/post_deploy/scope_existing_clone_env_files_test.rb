# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "tmpdir"

# The post-deploy task that narrows clone `.env` files already on disk (#372).
# Values are placeholders; assertions are on key NAMES only.
class ScopeExistingCloneEnvFilesTest < ActiveSupport::TestCase
  BUNDLE = %w[SLACK_BOT_TOKEN ZIMMER_PROD_API_KEY GCS_ADMIN_SERVICE_ACCOUNT_KEY_JSON].freeze

  setup do
    @entry = PostDeployTask::Registry.find("20260911170000")
    assert @entry
    @task_class = @entry.task_class
    @clones = Dir.mktmpdir("scope-existing-clones")
    SecretsLoader.stubs(:all).returns(BUNDLE.index_with { |key| "value-for-#{key}" })
  end

  teardown do
    FileUtils.rm_rf(@clones)
  end

  def clone_session(mcp_servers:, env: true)
    dir = File.join(@clones, SecureRandom.hex(4))
    FileUtils.mkdir_p(dir)
    if env
      File.write(File.join(dir, ".env"),
        BUNDLE.map { |key| "#{key}=\"value-for-#{key}\"" }.join("\n") + "\nKEEP_ME=\"mine\"\n")
    end
    Session.create!(
      prompt: "p", agent_runtime: "claude_code", status: :needs_input,
      git_root: "https://github.com/test/repo.git", branch: "main",
      mcp_servers: mcp_servers, metadata: { "clone_path" => dir, "working_directory" => dir }
    )
  end

  def keys_in(session)
    EnvFile.parse(File.read(File.join(session.working_directory, ".env"))).keys.sort
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    @outcome = @task_class.new(run: run).up
    run.reload
  end

  test "narrows an existing full-bundle .env to the session's own scope, keeping foreign lines" do
    slack = clone_session(mcp_servers: %w[slack-workspace])
    nothing = clone_session(mcp_servers: [])

    run = run_task

    assert_equal %w[KEEP_ME SLACK_BOT_TOKEN], keys_in(slack)
    assert_equal %w[KEEP_ME], keys_in(nothing)
    assert_equal 2, run.stats["rewritten"]
    assert_nil @outcome
  end

  test "leaves a clone with no .env alone and does not create one" do
    # Fixture sessions can record a clone_path that is not on disk; they are
    # counted the same way, so measure against them rather than from zero.
    already_bare = Session.where("metadata ->> 'clone_path' IS NOT NULL").count
    bare = clone_session(mcp_servers: %w[slack-workspace], env: false)

    run = run_task

    assert_not File.exist?(File.join(bare.working_directory, ".env"))
    assert_equal already_bare + 1, run.stats["no_env_file"]
    assert_equal 0, run.stats["rewritten"]
  end

  test "a second pass writes the same bytes" do
    session = clone_session(mcp_servers: %w[slack-workspace])
    run = run_task
    first = File.read(File.join(session.working_directory, ".env"))

    # A fresh cursor, or the sweep would start past this row and prove nothing.
    run.update!(cursor: {})
    @task_class.new(run: run).up

    assert_equal 2, run.reload.stats["rewritten"], "the second pass did rewrite the file"
    assert_equal first, File.read(File.join(session.working_directory, ".env"))
  end

  test "one clone that fails does not stop the rest, and is reported by id" do
    broken = clone_session(mcp_servers: %w[slack-workspace])
    fine = clone_session(mcp_servers: %w[slack-workspace])
    SessionEnvFile.stubs(:write!).with { |kw| kw[:session].id == broken.id }.raises(Errno::EACCES, "denied")
    SessionEnvFile.stubs(:write!).with { |kw| kw[:session].id == fine.id }.returns(
      SessionEnvFile::Result.new(key_names: [], available_count: 3)
    )

    run = run_task

    assert_equal 1, run.stats["failed"]
    assert_equal [ broken.id ], run.stats["failed_session_ids"]
    assert_equal 1, run.stats["rewritten"]
  end
end

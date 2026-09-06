# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# A clone must have its gems decided BEFORE the agent is spawned, not after (#592).
#
# Clone setup used to do one thing here: `BundleInstallJob.perform_later`. For a clone of
# this repo at a commit that has not touched the Gemfile that job does no work at all — it
# writes a `.bundle/config` naming the image's bundle and stops — but it did that work on
# the `:maintenance` queue, whenever the queue got to it.
#
# The queue was the bug. `CliSpawnEnv` strips every `BUNDLE_*` and `GEM_*` from the agent's
# environment, deliberately, so `.bundle/config` is the ONLY thing telling a clone where
# its gems live. Until the job ran there was no such file, and every `bin/rails` in the
# clone died with `Bundler::GemNotFound` listing gems that were sitting in the image — over
# the agent's opening turns, which are exactly when it would run a test.
#
# So spawn takes the fast path inline. These pin the two halves of that: it is taken when
# it is available, and the background job still gets its clone when it is not.
class AgentSessionJobInlineBundleTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/inline-bundle-test-clone"

  setup do
    @session = Session.create!(
      prompt: nil,
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
  end

  test "a clone that can share the image's bundle is pinned inline and never queued" do
    BundleInstallJob.expects(:adopt_image_bundle_now).with(CLONE_PATH).returns("/usr/local/bundle")

    assert_no_enqueued_jobs(only: BundleInstallJob) { run_clone_setup }

    log = log_matching(/Gems ready/)
    assert_not_nil log, "the timeline has to say the clone is ready, since nothing else will"
    assert_includes log.content, "/usr/local/bundle", "name the bundle it was pinned to"
    refute_includes all_log_content, "Preparing gems in the background",
                    "a clone with nothing to install must not claim an install is coming"
  end

  test "a clone that needs gems of its own still goes to the background job" do
    BundleInstallJob.expects(:adopt_image_bundle_now).with(CLONE_PATH).returns(nil)

    assert_enqueued_with(job: BundleInstallJob, args: [ @session.id, CLONE_PATH ]) { run_clone_setup }

    assert_includes all_log_content, "Preparing gems in the background"
    refute_includes all_log_content, "Gems ready"
  end

  test "a clone with no Gemfile is neither probed nor queued" do
    BundleInstallJob.expects(:adopt_image_bundle_now).never

    assert_no_enqueued_jobs(only: BundleInstallJob) { run_clone_setup(gemfile: false) }
  end

  # The inline call happens inside session spawn, so its failure mode is the session's.
  # `.adopt_image_bundle_now` swallows its own errors (pinned in BundleInstallJobTest);
  # this is the other end of that contract — a clone that could not be decided inline is
  # still handed to the job rather than lost.
  test "a fast path that declines leaves the clone with a job, not with nothing" do
    BundleInstallJob.stubs(:adopt_image_bundle_now).returns(nil)

    assert_enqueued_with(job: BundleInstallJob, args: [ @session.id, CLONE_PATH ]) { run_clone_setup }
    assert_equal "needs_input", @session.reload.status, "the spawn itself must still have succeeded"
  end

  private

  # Drive the real clone-setup block with the filesystem, the process manager and the
  # runtime mocked out. `clone_only` is the shortest path through it that still runs
  # every line of the setup: it prepares the clone and returns without spending a turn.
  def run_clone_setup(gemfile: true)
    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.file_system = MockFileSystemAdapter.new
    job.cli_adapter = MockClaudeCliAdapter.new

    job.file_system.mkdir_p(CLONE_PATH)
    job.file_system.write(File.join(CLONE_PATH, "Gemfile"), "source 'https://rubygems.org'\n") if gemfile

    GitCloneService.stubs(:create_clone).returns(
      { clone_path: CLONE_PATH, working_directory: CLONE_PATH }
    )

    job.perform(@session.id, nil, resume_monitoring: false, clone_only: true)
    job
  end

  def all_log_content = @session.logs.reload.map(&:content).join("\n")

  def log_matching(pattern) = @session.logs.reload.find { |entry| entry.content.match?(pattern) }
end

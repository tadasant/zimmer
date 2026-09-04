# frozen_string_literal: true

require "test_helper"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# What a failed session's timeline says about its clone must be true of the disk.
#
# THE BUG THESE PIN (#816). The teardown's `failed?` arm logged "Clone preserved
# for debugging: <path>" whenever `metadata["clone_path"]` was set — the metadata
# records where a clone was MADE, not that the tree is still there. It was most
# wrong in the case that needs it most: session 12280 failed *because* its clone
# directory was missing, and four seconds later was told the clone had been
# preserved for debugging. `ls` on that path returned ENOENT. That line is the
# only thing a person reads when deciding whether anything is left to recover,
# and it was stated as fact.
#
# Both branches are driven through the real resume-monitoring failure path, the
# same one that produced the observed case, so the assertions are about what
# #perform writes to the session's own timeline.
class AgentSessionJobFailedCloneLogTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/failed-clone-log-test-clone"
  PRESERVED = "Clone preserved for debugging"
  NOTHING_LEFT = "No clone to preserve"
  UNCHECKED = "Could not check whether the clone at"

  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :running,
      metadata: {
        "clone_path" => CLONE_PATH,
        "working_directory" => CLONE_PATH,
        "process_pid" => 4242,
        "runtime_started" => true
      },
      transcript: { "type" => "user", "message" => { "content" => "Test prompt" } }.to_json
    )
  end

  # ---------------------------------------------------------------------------
  # Clone still on disk — the claim is true, so it is still made
  # ---------------------------------------------------------------------------

  test "a failure with the clone still on disk keeps the preserved-for-debugging line" do
    # A failure that has nothing to do with the clone: the row lost its runtime
    # session id, so the resume cannot proceed, and the tree is untouched.
    @session.update!(session_id: nil)

    run_failing_resume(clone_on_disk: true)

    assert_equal "failed", @session.reload.status, "the branch under test only runs for a failed session"

    log = failed_clone_log
    assert_not_nil log, "a failed session must still be told what is on disk"
    assert_includes log.content, PRESERVED
    assert_includes log.content, CLONE_PATH
    assert_includes log.content, "Archive this session to cleanup the clone directory.",
                    "the clone is there, so the cleanup instruction is still the right next step"
    assert_equal "info", log.level
  end

  # ---------------------------------------------------------------------------
  # Clone gone — the observed case
  # ---------------------------------------------------------------------------

  test "a failure whose clone is gone is not told the clone was preserved" do
    run_failing_resume(clone_on_disk: false)

    assert_equal "failed", @session.reload.status
    assert_equal "clone directory not found at #{CLONE_PATH}", @session.metadata["failure_reason"],
                 "this is the observed shape: the missing clone is what failed the session"

    refute_includes all_log_content, PRESERVED,
                    "a session that failed because its clone vanished must not be told it was preserved"
  end

  test "a failure whose clone is gone says what actually remains, and asks for no cleanup" do
    run_failing_resume(clone_on_disk: false)

    log = failed_clone_log
    assert_not_nil log, "silence would leave the reader to guess; say the tree is gone"
    assert_includes log.content, NOTHING_LEFT
    assert_includes log.content, CLONE_PATH, "name the path that was checked"
    assert_includes log.content, "its prompt, and whatever transcript Zimmer had polled",
                    "the reader needs to know what survives, and it is the session record — hedged, " \
                    "because neither column was read"
    refute_includes log.content, "Archive this session to cleanup",
                    "there is no clone directory left to delete, so do not ask for it"
    assert_equal "info", log.level
  end

  # A half-unlinked tree can leave a plain file where the clone was. `exists?`
  # would call that preserved; `directory?` is the question worth asking.
  test "a plain file at the clone path is not a preserved clone" do
    # The session fails for its own reason; what is at the path is what decides
    # which line the timeline gets.
    @session.update!(session_id: nil)

    run_failing_resume(clone_on_disk: false) do |job|
      job.file_system.write(CLONE_PATH, "not a directory")
    end

    refute_includes all_log_content, PRESERVED
    assert_includes all_log_content, NOTHING_LEFT
  end

  # ---------------------------------------------------------------------------
  # Teardown safety: a job that raises here strands the failed session
  # ---------------------------------------------------------------------------

  test "the failure teardown raises in neither case" do
    assert_nothing_raised { run_failing_resume(clone_on_disk: false) }
    assert_equal "failed", @session.reload.status

    # The same teardown again, this time with the tree in place and the agent
    # process still alive — so the whole branch runs, terminate_process included,
    # rather than only the log emission.
    @session.update_columns(status: Session.statuses[:running], session_id: nil)
    job = nil
    assert_nothing_raised do
      job = run_failing_resume(clone_on_disk: true) do |j|
        j.process_manager.set_process_state(4242, :running)
      end
    end
    # Terminated as a process group, so the recorded pid is negated.
    assert_includes job.process_manager.killed_processes.map { |k| k[:pid].abs }, 4242,
                    "the live process must still have been terminated"
    assert_equal "failed", @session.reload.status
    assert_includes all_log_content, PRESERVED
  end

  test "a stat that raises claims nothing and does not take the job down" do
    @session.update!(session_id: nil)

    exploding_fs = MockFileSystemAdapter.new
    exploding_fs.mkdir_p(CLONE_PATH)
    def exploding_fs.directory?(path)
      raise ArgumentError, "path contains null byte" if path == CLONE_PATH

      super
    end

    assert_nothing_raised { run_failing_resume(clone_on_disk: true, file_system: exploding_fs) }

    assert_equal "failed", @session.reload.status
    refute_includes all_log_content, PRESERVED, "an unanswered stat must not be reported as an answer"
    refute_includes all_log_content, NOTHING_LEFT, "nor as the opposite answer"

    # Silence would leave the reader to guess, and the Rails log is not somewhere
    # they can reach. The timeline says the question went unanswered.
    hedged = @session.logs.reload.find { |entry| entry.content.include?(UNCHECKED) }
    assert_not_nil hedged, "an unanswered stat must still be visible in the session's own timeline"
    assert_includes hedged.content, CLONE_PATH
    assert_includes hedged.content, "ArgumentError", "name what went wrong"
    assert_equal "warning", hedged.level
  end

  # ---------------------------------------------------------------------------
  # A row with no clone_path at all has nothing to say about a clone
  # ---------------------------------------------------------------------------

  test "a failure with no clone_path recorded logs neither line" do
    @session.update!(metadata: @session.metadata.merge("clone_path" => nil, "working_directory" => nil))

    # A resume with no clone_path recorded cannot proceed at all: the guard above
    # the validation raises, the rescue fails the session, and the teardown then
    # runs with a nil clone_path. That nil is what must not blow the branch up.
    error = assert_raises(RuntimeError) { run_failing_resume(clone_on_disk: false) }
    assert_match(/missing process_pid or clone_path/, error.message,
                 "pin the raise this test means, so an unrelated one cannot keep it green")

    assert_equal "failed", @session.reload.status
    refute_includes all_log_content, PRESERVED
    refute_includes all_log_content, NOTHING_LEFT
    refute_includes all_log_content, UNCHECKED, "there is no path to have a question about"
  end

  private

  # Drive the real job down the resume-monitoring validation failure — the path
  # the observed case (#808's session 12280) took — with the filesystem, the
  # process manager and the runtime mocked out. Returns once #perform has run its
  # ensure block, which is where the branch under test lives.
  def run_failing_resume(clone_on_disk:, session: @session, file_system: nil)
    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.file_system = file_system || MockFileSystemAdapter.new
    job.cli_adapter = MockClaudeCliAdapter.new
    job.file_system.mkdir_p(CLONE_PATH) if clone_on_disk && file_system.nil?
    yield job if block_given?

    job.perform(session.id, nil, resume_monitoring: true)
    job
  end

  def all_log_content
    @session.logs.reload.map(&:content).join("\n")
  end

  def failed_clone_log
    @session.logs.reload.find { |entry| entry.content.include?(PRESERVED) || entry.content.include?(NOTHING_LEFT) }
  end
end

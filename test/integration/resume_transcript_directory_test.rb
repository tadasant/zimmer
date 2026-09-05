require "test_helper"
require "minitest/mock"
require "mocha/minitest"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_claude_cli_adapter"
require "path_sanitizer"

# zimmer#576 — the verification the issue itself names: resume a session twice
# and exactly one transcript directory holds its conversation.
#
# This drives the real resume path end to end. Real `git clone` from a real local
# repository, the real filesystem adapter, the real `SessionClonePath` decision,
# the real `AgentSessionJob#write_transcript_to_clone`, and the real
# `ClaudeTranscriptSource` slug derivation. Only the CLI process itself is a
# double — nothing between the resume and the bytes on disk is stubbed, because
# the defect lives exactly there.
#
# Each "resume" here is the production sequence: a reaper takes the clone while
# the session is idle, and a trigger/user/recovery then sends a follow-up prompt
# into the same conversation.
class ResumeTranscriptDirectoryTest < ActiveJob::TestCase
  setup do
    @tmp = Dir.mktmpdir("resume_transcript_directory_test")
    @clones_base = File.join(@tmp, "clones")
    @projects_root = File.join(@tmp, "claude", "projects")
    FileUtils.mkdir_p([ @clones_base, @projects_root ])

    @original_clones_dir = ENV["AGENT_CLONES_DIR"]
    ENV["AGENT_CLONES_DIR"] = @clones_base
    ClaudeTranscriptSource.stubs(:projects_root).returns(@projects_root)

    @repo = create_git_repository

    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: @repo,
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      transcript: transcript_lines(2)
    )
  end

  teardown do
    ENV["AGENT_CLONES_DIR"] = @original_clones_dir
    FileUtils.rm_rf(@tmp)
  end

  # The headline assertion. Two resumes, each preceded by the clone being reaped,
  # and one transcript directory at the end.
  test "resuming twice leaves exactly one transcript directory holding the conversation" do
    first_clone = start_in_a_fresh_clone

    reap_clone!
    resume_with_follow_up!("second turn")
    assert_equal first_clone, @session.reload.metadata["clone_path"],
      "the first resume must put the clone back where it was"

    reap_clone!
    resume_with_follow_up!("third turn")
    assert_equal first_clone, @session.reload.metadata["clone_path"],
      "the second resume must put the clone back where it was"

    assert_equal 1, transcript_directories_holding_the_conversation.length,
      "one conversation must hold one transcript directory across two resumes, found: " \
      "#{transcript_directories_holding_the_conversation.inspect}"

    # ...and it is the live one: the file the next `--resume` reads carries the
    # full stored conversation, not a truncated prefix.
    only = transcript_directories_holding_the_conversation.first
    assert_equal @session.reload.transcript,
      File.read(File.join(@projects_root, only, "#{@session.session_id}.jsonl"))
  end

  # The before half of the before/after evidence, from the same harness. With the
  # path decision disabled — i.e. `main` before this change — each resume writes
  # the conversation out under a new slug.
  test "without the path decision the same two resumes write the conversation into three directories" do
    SessionClonePath.stubs(:for_recreate).returns(nil)

    start_in_a_fresh_clone
    reap_clone!
    resume_with_follow_up!("second turn")
    reap_clone!
    resume_with_follow_up!("third turn")

    assert_equal 3, transcript_directories_ever_occupied.length,
      "this is the defect: one full copy of the JSONL per clone the session lived in"
  end

  test "the conversation is only ever written into one directory" do
    start_in_a_fresh_clone
    reap_clone!
    resume_with_follow_up!("second turn")
    reap_clone!
    resume_with_follow_up!("third turn")

    assert_equal 1, transcript_directories_ever_occupied.length,
      "after the fix, the conversation is written into exactly one directory for its whole life"
  end

  # The redundancy the issue measured is what is *left on disk*, and that is what
  # a reaper that never reached the transcript directory leaves behind: a clone
  # deleted outside CloneReaper, a transcript reap that was refused, one that
  # failed. Before the fix that is three copies; after it, one.
  test "a reap that misses the transcript directory leaves one copy, not three" do
    SessionClonePath.stubs(:for_recreate).returns(nil)
    start_in_a_fresh_clone
    reap_clone!(reap_transcript: false)
    resume_with_follow_up!("second turn")
    reap_clone!(reap_transcript: false)
    resume_with_follow_up!("third turn")
    assert_equal 3, transcript_directories_holding_the_conversation.length,
      "before: every copy but the newest is dead weight on disk"

    SessionClonePath.unstub(:for_recreate)
    FileUtils.rm_rf(Dir.glob(File.join(@projects_root, "*")))
    @occupied = Set.new
    start_in_a_fresh_clone
    reap_clone!(reap_transcript: false)
    resume_with_follow_up!("fourth turn")
    reap_clone!(reap_transcript: false)
    resume_with_follow_up!("fifth turn")
    assert_equal 1, transcript_directories_holding_the_conversation.length,
      "after: there is only ever one directory to leave behind"
  end

  test "a clone that still exists is reused untouched, dirty tree and all" do
    clone_path = start_in_a_fresh_clone
    File.write(File.join(clone_path, "uncommitted.txt"), "work in progress")
    File.write(File.join(clone_path, "README.md"), "locally modified")

    resume_with_follow_up!("second turn")

    assert_equal clone_path, @session.reload.metadata["clone_path"]
    assert_equal "work in progress", File.read(File.join(clone_path, "uncommitted.txt")),
      "an existing clone is never re-cloned, so uncommitted work survives a resume"
    assert_equal "locally modified", File.read(File.join(clone_path, "README.md"))
    assert_equal 1, transcript_directories_holding_the_conversation.length
  end

  test "a session whose branch moved re-clones the branch on the row, at its old path" do
    first_clone = start_in_a_fresh_clone
    run_git("checkout", "-q", "-b", "feature", cwd: @repo)
    File.write(File.join(@repo, "feature.txt"), "on the feature branch")
    run_git("add", ".", cwd: @repo)
    run_git("commit", "-q", "-m", "feature", cwd: @repo)
    run_git("checkout", "-q", "main", cwd: @repo)
    @session.update!(branch: "feature")

    reap_clone!
    resume_with_follow_up!("second turn")

    assert_equal first_clone, @session.reload.metadata["clone_path"],
      "the directory name still spells the branch it was first cut for; that is cosmetic"
    assert_path_exists File.join(first_clone, "feature.txt"),
      "the re-clone must check out the branch on the row, not the one in the directory name"
    assert_equal 1, transcript_directories_holding_the_conversation.length
  end

  test "a session whose agent root subdirectory moved follows its cwd to a new transcript directory" do
    @session.update!(subdirectory: "packages/app")
    first_clone = start_in_a_fresh_clone
    assert_equal File.join(first_clone, "packages/app"), @session.reload.metadata["working_directory"]

    reap_clone!
    resume_with_follow_up!("second turn")

    assert_equal first_clone, @session.reload.metadata["clone_path"]
    assert_equal 1, transcript_directories_holding_the_conversation.length,
      "a subdirectory session's transcript directory is named for the subdirectory cwd, " \
      "and reusing the clone path keeps that stable too"
  end

  # A trashed clone is the case AgentSessionJob's recreate branch was written
  # for: the directory is gone, and there is nothing at the path to inherit.
  test "a trashed clone is recreated at its old path with a working tree" do
    first_clone = start_in_a_fresh_clone
    reap_clone!
    refute File.exist?(first_clone)

    resume_with_follow_up!("second turn")

    assert_equal first_clone, @session.reload.metadata["clone_path"]
    assert_path_exists File.join(first_clone, "README.md")
    assert_path_exists File.join(first_clone, ".git")
  end

  # A transcript directory and the clone that named it live on different volumes,
  # so the directory can outlive the clone. At a reused path the resume now meets
  # that survivor — and must not overwrite it with a stored record the poller had
  # not finished catching up to.
  test "a longer on-disk transcript that outlived its clone is resumed, not overwritten" do
    start_in_a_fresh_clone
    working_directory = @session.reload.metadata["working_directory"]
    transcript_path = ClaudeTranscriptSource.new.resume_transcript_path(
      session: @session, working_directory: working_directory
    )
    ahead_of_the_poller = @session.transcript + transcript_lines(1)
    File.write(transcript_path, ahead_of_the_poller)

    reap_clone!(reap_transcript: false)
    resume_with_follow_up!("second turn", write_transcript: false)

    assert_equal ahead_of_the_poller, File.read(transcript_path),
      "the resume must not shorten a conversation the stored record had not caught up to"
    assert_equal 1, transcript_directories_holding_the_conversation.length
  end

  # ...and the case the restore exists for still fires: a missing on-disk copy is
  # re-materialized from the stored record before the runtime resumes.
  test "a transcript that went with its clone is re-materialized before the resume" do
    start_in_a_fresh_clone
    stored = @session.reload.transcript

    reap_clone!
    resume_with_follow_up!("second turn", write_transcript: false)

    path = ClaudeTranscriptSource.new.resume_transcript_path(
      session: @session.reload, working_directory: @session.metadata["working_directory"]
    )
    assert_equal stored, File.read(path),
      "a resume with no on-disk transcript must restore the stored one, or it drops the prompt"
  end

  private

  # The session's first clone, created the way AgentSessionJob's fresh-start path
  # creates it, with the runtime's transcript directory materialized underneath.
  def start_in_a_fresh_clone
    result = GitCloneService.create_clone(@repo, branch: @session.branch, subdirectory: @session.subdirectory)
    @session.update!(metadata: (@session.metadata || {}).merge(
      "clone_path" => result[:clone_path],
      "working_directory" => result[:working_directory],
      "full_clone_path" => result[:working_directory],
      # The session has already taken a turn: there is a conversation to resume
      # into, which is what makes the next prompt a `--resume` rather than a
      # first spawn.
      "runtime_started" => true
    ))
    write_runtime_transcript(result[:working_directory])
    result[:clone_path]
  end

  # What a reaper does between turns: the clone goes, and — when the deletion
  # went through CloneReaper — the transcript directory named after it goes with
  # it (zimmer#434 / #951). `reap_transcript: false` is the other half of that
  # `if`: a clone removed any other way, or a transcript reap that was refused or
  # failed, leaves the directory standing.
  def reap_clone!(reap_transcript: true)
    clone_path = @session.reload.metadata["clone_path"]
    working_directory = @session.metadata["working_directory"]
    FileUtils.rm_rf(clone_path)
    return unless reap_transcript

    FileUtils.rm_rf(ClaudeTranscriptSource.new.transcript_directory(working_directory: working_directory))
  end

  # A follow-up prompt through the real job: this is the resume path.
  def resume_with_follow_up!(prompt, write_transcript: true)
    @session.update!(status: :needs_input, running_job_id: nil)

    job = AgentSessionJob.new
    process_manager = MockProcessManager.new
    cli_adapter = MockClaudeCliAdapter.new
    cli_adapter.process_manager = process_manager
    job.process_manager = process_manager
    job.cli_adapter = cli_adapter

    process_manager.wait_hook = ->(pid, _flags) { [ pid, MockProcessManager::MockStatus.new(0) ] }

    TranscriptPollerService.stub(:new, ->(_session, file_system: nil, broadcast_service: nil) {
      poller = Object.new
      def poller.poll_and_broadcast; end
      poller
    }) do
      Thread.stub(:new, ->(&_block) {
        thread = Object.new
        def thread.alive? = false
        def thread.kill; end
        def thread.join(*); end
        thread
      }) do
        job.perform(@session.id, prompt)
      end
    end

    @session.reload
    # The runtime keeps appending to the file Zimmer restored for it.
    write_runtime_transcript(@session.metadata["working_directory"]) if write_transcript
    assert_equal 1, cli_adapter.resumed_sessions.length,
      "the follow-up must reach the runtime as a resume, not be dropped"
  end

  # Everything under the projects root that holds this conversation's JSONL right
  # now — the redundancy that is actually sitting on disk.
  def transcript_directories_holding_the_conversation
    Dir.children(@projects_root).select do |entry|
      File.exist?(File.join(@projects_root, entry, "#{@session.session_id}.jsonl"))
    end.sort
  end

  # Every distinct transcript directory the conversation has been written into
  # over its life, whether or not a reaper has since caught up with it. This is
  # the number the issue measures: each one cost a full copy of the JSONL.
  def transcript_directories_ever_occupied
    @occupied.to_a.sort
  end

  # Stand in for the runtime: grow the conversation by one line and leave it both
  # on disk (where `--resume` reads it) and in the stored record (where the poller
  # would have put it).
  def write_runtime_transcript(working_directory)
    @turns = (@turns || 2) + 1
    @session.update!(transcript: transcript_lines(@turns))
    path = ClaudeTranscriptSource.new.resume_transcript_path(
      session: @session, working_directory: working_directory
    )
    (@occupied ||= Set.new) << File.basename(File.dirname(path))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, @session.transcript)
  end

  def transcript_lines(count)
    (1..count).map do |i|
      { "type" => i.odd? ? "user" : "assistant",
        "message" => { "role" => i.odd? ? "user" : "assistant", "content" => "turn #{i}" } }.to_json
    end.join("\n") + "\n"
  end

  def create_git_repository
    repo = File.join(@tmp, "repo")
    FileUtils.mkdir_p(File.join(repo, "packages", "app"))
    File.write(File.join(repo, "README.md"), "# Test repository\n")
    File.write(File.join(repo, "packages", "app", "app.rb"), "# app\n")
    run_git("init", "-q", cwd: repo)
    run_git("config", "user.email", "test@example.com", cwd: repo)
    run_git("config", "user.name", "Test User", cwd: repo)
    run_git("add", ".", cwd: repo)
    run_git("commit", "-q", "-m", "Initial commit", cwd: repo)
    run_git("branch", "-M", "main", cwd: repo)
    repo
  end

  def run_git(*args, cwd:)
    out, status = Open3.capture2e("git", *args, chdir: cwd)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end
end

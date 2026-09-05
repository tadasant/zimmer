# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# zimmer#434. The half that works off the backlog: transcript directories under
# `~/.claude/projects` whose clone was deleted before anything reaped transcripts.
#
# Everything here is about what must NOT be deleted. A wrongly-classified
# directory costs a running session its conversation — the `.jsonl` `--resume`
# reads, which exists nowhere else on the box — while a wrongly-kept one costs a
# few hundred kilobytes until the rules widen.
class OrphanTranscriptDirectoryCleanupJobTest < ActiveJob::TestCase
  OLD = 3.days.ago

  setup do
    @clones_base = Dir.mktmpdir("orphan-transcript-clones")
    @projects_root = Dir.mktmpdir("orphan-transcript-projects")
    ClonesDirectory.stubs(:base).returns(@clones_base)
    ClaudeTranscriptSource.stubs(:projects_root).returns(@projects_root)
  end

  teardown do
    FileUtils.rm_rf(@clones_base)
    FileUtils.rm_rf(@projects_root)
  end

  # --- edge case 1: a subdirectory cwd belongs to a live clone ---------------

  test "a live clone's subdirectory-cwd transcript directory survives the sweep" do
    clone = live_clone("zimmer-main-1785661439-005ceef3")
    # The agent root has `subdirectory: zimmer`, so the session's cwd — and
    # therefore the name Claude Code gives its transcript directory — is
    # <clone>/zimmer, NOT the clone root. Nothing in `@projects_root` is named
    # after the clone root at all.
    subdir_transcript = transcript_dir_for(File.join(clone, "zimmer"), age: OLD)
    orphan = transcript_dir_for(File.join(@clones_base, "zimmer-main-1770000000-deadbeef"), age: OLD)

    OrphanTranscriptDirectoryCleanupJob.new.perform

    assert File.directory?(subdir_transcript),
      "a running session's transcript must survive: matching clone name to directory name by " \
      "equality would classify this as orphaned and delete the file --resume reads"
    assert_not File.directory?(orphan)
  end

  test "a live clone claimed only by a session row, not present on disk, still protects its transcript" do
    # Liveness is the union of the filesystem and reap_protected sessions. Blind
    # the filesystem half and the database half must still hold the line.
    clone_path = File.join(@clones_base, "zimmer-main-1785661439-005ceef3")
    sessions(:running).update!(metadata: { "clone_path" => clone_path })
    transcript = transcript_dir_for(File.join(clone_path, "zimmer"), age: OLD)

    OrphanTranscriptDirectoryCleanupJob.new.perform

    assert File.directory?(transcript)
  end

  # --- edge case 2: not every transcript directory comes from a clone --------

  test "reaps the /tmp class while -rails survives" do
    headless = 3.times.map { |i| project_dir("-tmp-headless-inference-#{i}", age: OLD) }
    test_clone = project_dir("-tmp-test-clone-archived", age: OLD)
    rails = project_dir("-rails", age: OLD)
    someone_elses = project_dir("-Users-someone-code-a-project", age: OLD)

    OrphanTranscriptDirectoryCleanupJob.new.perform

    headless.each do |path|
      assert_not File.directory?(path),
        "a cwd under /tmp cannot survive a container restart, so no clone-based rule reaches these"
    end
    assert_not File.directory?(test_clone)
    assert File.directory?(rails), "-rails is the app root inside the container, and it is live"
    assert File.directory?(someone_elses), "an unrecognized shape keeps"
  end

  # --- the ordinary case, and the bars around it ----------------------------

  test "reaps a clone-derived directory whose clone is gone" do
    orphan = transcript_dir_for(File.join(@clones_base, "zimmer-main-1770000000-deadbeef"), age: OLD)

    OrphanTranscriptDirectoryCleanupJob.new.perform

    assert_not File.directory?(orphan)
  end

  test "an orphan inside the age bar is left for a later run" do
    recent = transcript_dir_for(File.join(@clones_base, "zimmer-main-1770000000-deadbeef"),
                                age: 1.hour.ago)

    OrphanTranscriptDirectoryCleanupJob.new.perform

    assert File.directory?(recent)
  end

  test "removes no more than BATCH_LIMIT directories in one run" do
    stub_const(OrphanTranscriptDirectoryCleanupJob, :BATCH_LIMIT, 2) do
      3.times { |i| transcript_dir_for(File.join(@clones_base, "zimmer-main-177000000#{i}-deadbee#{i}"), age: OLD) }

      OrphanTranscriptDirectoryCleanupJob.new.perform

      assert_equal 1, Dir.children(@projects_root).size
    end
  end

  # --- abort guards on list integrity ---------------------------------------

  test "aborts rather than treating every directory as orphaned when the clones base is missing" do
    orphan = transcript_dir_for(File.join(@clones_base, "zimmer-main-1770000000-deadbeef"), age: OLD)
    FileUtils.rm_rf(@clones_base)

    OrphanTranscriptDirectoryCleanupJob.new.perform

    assert File.directory?(orphan),
      "a clones base that is gone makes every clone-derived directory look orphaned at once, which " \
      "is the shape of a mass deletion, not of a sweep"
  end

  test "aborts when the live-clone set cannot be read from the database" do
    orphan = transcript_dir_for(File.join(@clones_base, "zimmer-main-1770000000-deadbeef"), age: OLD)
    Session.stubs(:unscoped).raises(ActiveRecord::StatementInvalid, "boom")

    OrphanTranscriptDirectoryCleanupJob.new.perform

    assert File.directory?(orphan)
  end

  test "refuses to sweep when the clones base is the default durable root outside a deployment" do
    default_base = File.join(File.expand_path("~"), ClonesDirectory::DEFAULT_HOME_SUBDIR, "clones")
    ClonesDirectory.stubs(:base).returns(default_base)
    orphan = project_dir("-tmp-headless-inference-0", age: OLD)

    OrphanTranscriptDirectoryCleanupJob.new.perform

    assert File.directory?(orphan),
      "outside production/staging, ~/.claude/projects is a person's own Claude Code history"
  end

  # --- the production mix, end to end ---------------------------------------

  # A synthetic tree in the shape zimmer#434 measured on production, swept for
  # real. The counts are the direct evidence that nothing live is lost.
  test "sweeps a synthetic production mix, keeping every live and unattributable directory" do
    live = 3.times.map { |i| live_clone("zimmer-main-178566143#{i}-005ceef#{i}") }
    keep = live.flat_map do |clone|
      [ transcript_dir_for(clone, age: OLD), transcript_dir_for(File.join(clone, "zimmer"), age: OLD) ]
    end
    keep << project_dir("-rails", age: OLD)

    reap = 10.times.map { |i| transcript_dir_for(File.join(@clones_base, "zimmer-main-17700000#{i}-deadbee#{i}"), age: OLD) }
    reap += 4.times.map { |i| transcript_dir_for(File.join(@clones_base, "zimmer-main-17600000#{i}-cafebab#{i}", "zimmer"), age: OLD) }
    reap += 5.times.map { |i| project_dir("-tmp-headless-inference-#{i}", age: OLD) }
    reap << project_dir("-tmp-test-clone-archived", age: OLD)

    assert_equal 27, Dir.children(@projects_root).size

    OrphanTranscriptDirectoryCleanupJob.new.perform

    keep.each { |path| assert File.directory?(path), "#{File.basename(path)} must survive" }
    reap.each { |path| assert_not File.directory?(path), "#{File.basename(path)} should have been reaped" }
    assert_equal 7, Dir.children(@projects_root).size
  end

  private

  # A clone directory that exists on disk.
  def live_clone(name)
    File.join(@clones_base, name).tap { |path| FileUtils.mkdir_p(path) }
  end

  # The transcript directory Claude Code would create for `working_directory`,
  # through the app's own derivation, with a transcript file in it.
  def transcript_dir_for(working_directory, age:)
    dir = ClaudeTranscriptSource.new.transcript_directory(working_directory: working_directory)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{SecureRandom.uuid}.jsonl"), "{}\n")
    FileUtils.touch(dir, mtime: age.to_time)
    dir
  end

  # A transcript directory named literally, for the cwds that are not clones.
  def project_dir(name, age:)
    File.join(@projects_root, name).tap do |path|
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "#{SecureRandom.uuid}.jsonl"), "{}\n")
      FileUtils.touch(path, mtime: age.to_time)
    end
  end
end

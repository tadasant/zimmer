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
      "a liveness set difference computed against the wrong database reads every live clone as dead"
  end

  test "refuses to sweep a transcript root inside a real home directory outside a deployment" do
    # The clones base is relocated — which is the ordinary developer and CI
    # configuration, and which PASSES the clones-base fence — while
    # `~/.claude/projects` is not relocatable and is that person's own Claude Code
    # history. Fencing only on the clones base would permit exactly this.
    home = Dir.mktmpdir("orphan-transcript-home")
    original_home = ENV["HOME"]
    ENV["HOME"] = home
    begin
      @projects_root = File.join(home, ".claude", "projects")
      ClaudeTranscriptSource.stubs(:projects_root).returns(@projects_root)
      # An unambiguous orphan by every other rule, so only the fence can save it.
      orphan = project_dir("-tmp-headless-inference-0", age: OLD)

      OrphanTranscriptDirectoryCleanupJob.new.perform

      assert File.directory?(orphan),
        "outside production/staging, a transcript root under $HOME is a person's own Claude Code history"
    ensure
      ENV["HOME"] = original_home
      FileUtils.rm_rf(home)
    end
  end

  test "the age bar reads the newest file in the directory, not the directory's own mtime" do
    # POSIX bumps a directory's mtime when entries are created or removed in it,
    # never when an existing file is appended to — and Claude Code appends to one
    # .jsonl for the life of a session. Reading the directory alone would call a
    # transcript being written right now three days old.
    dir = transcript_dir_for(File.join(@clones_base, "zimmer-main-1770000000-deadbeef"), age: OLD)
    FileUtils.touch(Dir.glob(File.join(dir, "*.jsonl")).first, mtime: Time.current.to_time)

    OrphanTranscriptDirectoryCleanupJob.new.perform

    assert File.directory?(dir),
      "a directory whose transcript was written seconds ago is not a day-old orphan"
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
    populate(dir, age: age)
  end

  # A transcript directory named literally, for the cwds that are not clones.
  def project_dir(name, age:)
    populate(File.join(@projects_root, name), age: age)
  end

  # `age` is applied to the CONTENTS as well as the directory: the sweep reads
  # the newest mtime in the tree, not the directory's own, so a fixture that aged
  # only the directory would be a day old on the outside and seconds old on the
  # inside — which is precisely the state
  # OrphanTranscriptDirectoryCleanupJob#newest_mtime exists to refuse.
  def populate(dir, age:)
    FileUtils.mkdir_p(File.join(dir, "tool-results"))
    transcript = File.join(dir, "#{SecureRandom.uuid}.jsonl")
    File.write(transcript, "{}\n")
    FileUtils.touch([ transcript, File.join(dir, "tool-results"), dir ], mtime: age.to_time)
    dir
  end
end

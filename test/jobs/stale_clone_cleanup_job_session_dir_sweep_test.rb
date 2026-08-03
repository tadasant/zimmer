# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# StaleCloneCleanupJob's orphan sweep over the three roots whose per-session
# directories are named for the session id: scratch, prompt files, prompt images
# (#340).
#
# Every root here is redirected into a temp dir for the duration of the test. That
# is not just hygiene: under test the default roots resolve under the developer's
# real ~/.zimmer volume, and the sweep refuses to run against a root whose env
# override is unset for exactly that reason (see "refuses to sweep a root that is
# not explicitly relocated under test" below).
class StaleCloneCleanupJobSessionDirSweepTest < ActiveJob::TestCase
  ENV_KEYS = %w[AGENT_SCRATCH_DIR AGENT_FILES_DIR AGENT_IMAGES_DIR].freeze

  setup do
    @scratch_base = Dir.mktmpdir("sweep-scratch")
    @files_base = Dir.mktmpdir("sweep-files")
    @images_base = Dir.mktmpdir("sweep-images")
    @clones_base = Dir.mktmpdir("sweep-clones")

    @env_backup = ENV_KEYS.index_with { |key| ENV[key] }
    ENV["AGENT_SCRATCH_DIR"] = @scratch_base
    ENV["AGENT_FILES_DIR"] = @files_base
    ENV["AGENT_IMAGES_DIR"] = @images_base

    # Keep the clone half of the job pointed at an empty temp dir so it cannot
    # reach the real clones base while these tests run.
    StaleCloneCleanupJob.clones_directory_override = @clones_base

    # An id no row holds: what a hard-deleted session leaves behind on disk.
    @orphan_id = Session.maximum(:id).to_i + 10_000
  end

  teardown do
    StaleCloneCleanupJob.clones_directory_override = nil
    @env_backup.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    [ @scratch_base, @files_base, @images_base, @clones_base ].each { |dir| FileUtils.rm_rf(dir) }
  end

  test "reclaims scratch and both attachment roots once the session row is gone" do
    scratch, files, images = seed_all_roots(@orphan_id)
    backdate(scratch, files, images)

    assert_nil Session.find_by(id: @orphan_id), "the orphan id must not belong to any row"

    StaleCloneCleanupJob.perform_now

    assert_not Dir.exist?(scratch), "orphaned scratch dir should be swept"
    assert_not Dir.exist?(files), "orphaned prompt-file dir should be swept"
    assert_not Dir.exist?(images), "orphaned prompt-image dir should be swept"
  end

  test "never touches the directories of a session whose row still exists, however old they are" do
    live = sessions(:waiting)
    scratch, files, images = seed_all_roots(live.id)
    backdate(scratch, files, images, age: 30.days)

    StaleCloneCleanupJob.perform_now

    assert Dir.exist?(scratch), "a live session's scratch dir must survive the sweep"
    assert Dir.exist?(files), "a live session's prompt files must survive the sweep"
    assert Dir.exist?(images), "a live session's prompt images must survive the sweep"
    assert_equal "state", File.read(File.join(scratch, "state.txt"))
  end

  test "leaves a still-starting-up session's directories alone until they age past the threshold" do
    scratch, files, images = seed_all_roots(@orphan_id)

    StaleCloneCleanupJob.perform_now

    assert Dir.exist?(scratch), "a scratch dir younger than ORPHAN_AGE_THRESHOLD must survive"
    assert Dir.exist?(files)
    assert Dir.exist?(images)

    backdate(scratch, files, images)
    StaleCloneCleanupJob.perform_now

    assert_not Dir.exist?(scratch), "the same dir should be swept once it is old enough"
    assert_not Dir.exist?(files)
    assert_not Dir.exist?(images)
  end

  test "ignores directory names that are not session ids" do
    temp_upload = FileStorageService.new(session_id: "temp_#{SecureRandom.uuid}").session_dir
    junk = File.join(@scratch_base, "not-a-session")
    zero = File.join(@scratch_base, "0")
    padded = File.join(@scratch_base, "007")
    oversized = File.join(@scratch_base, "9" * 25)
    [ temp_upload, junk, zero, padded, oversized ].each { |dir| FileUtils.mkdir_p(dir) }
    backdate(temp_upload, junk, zero, padded, oversized)

    StaleCloneCleanupJob.perform_now

    assert Dir.exist?(temp_upload), "a pre-session temp_<uuid> upload dir has no session id to check and must survive"
    assert Dir.exist?(junk)
    assert Dir.exist?(zero)
    assert Dir.exist?(padded)
    assert Dir.exist?(oversized), "a numeric name too long for a bigint id must survive"
  end

  test "aborts the sweep when the sessions table has no rows" do
    scratch, files, images = seed_all_roots(@orphan_id)
    backdate(scratch, files, images)

    # Stub the relation, not the predicate: the guard itself has to be the thing
    # under test, or rewriting it to something always-true would stay green.
    Session.stubs(:unscoped).returns(Session.none)
    assert_not StaleCloneCleanupJob.new.send(:any_sessions_exist?)

    StaleCloneCleanupJob.perform_now

    assert Dir.exist?(scratch), "an empty sessions table makes every dir look orphaned; the sweep must not run"
    assert Dir.exist?(files)
    assert Dir.exist?(images)
  end

  test "removes at most ORPHAN_SWEEP_LIMIT directories from a root per run" do
    over_limit = StaleCloneCleanupJob::ORPHAN_SWEEP_LIMIT + 1
    orphans = (1..over_limit).map do |offset|
      dir = File.join(@scratch_base, (@orphan_id + offset).to_s)
      FileUtils.mkdir_p(dir)
      dir
    end
    backdate(*orphans)

    StaleCloneCleanupJob.perform_now

    survivors = orphans.count { |dir| Dir.exist?(dir) }
    assert_equal 1, survivors, "the cap should leave exactly one orphan for the next run"

    StaleCloneCleanupJob.perform_now

    assert_equal 0, orphans.count { |dir| Dir.exist?(dir) }, "the next run should take the remainder"
  end

  test "sweeps the same roots the writers write to" do
    labels_to_roots = StaleCloneCleanupJob.new.send(:session_directory_roots).to_h

    # Each assert is against the directory a writer would actually create, so a
    # root swapped for its sibling (storage_root instead of base_dir, say) fails.
    assert_equal File.dirname(SessionScratchDirectory.path_for(1)), labels_to_roots["scratch"]
    assert_equal File.dirname(FileStorageService.new(session_id: 1).session_dir), labels_to_roots["prompt files"]
    assert_equal File.dirname(ImageStorageService.new(session_id: 1).session_dir), labels_to_roots["prompt images"]
  end

  test "refuses to sweep a root inside the durable volume outside production and staging" do
    # Make the tmp scratch base look like it lives on the durable volume by
    # pointing the clones base (whose parent defines that volume) inside it.
    ClonesDirectory.stubs(:base).returns(File.join(@scratch_base, "clones"))
    orphan = File.join(@scratch_base, @orphan_id.to_s)
    FileUtils.mkdir_p(orphan)
    backdate(orphan)

    StaleCloneCleanupJob.perform_now

    assert Dir.exist?(orphan),
      "a root on the durable volume must not be swept by an environment whose database does not describe it"

    job = StaleCloneCleanupJob.new
    assert_not job.send(:sweepable_root?, "scratch", @scratch_base)
    assert job.send(:sweepable_root?, "prompt files", @files_base),
      "a root relocated clear of the durable volume is still swept"
  end

  test "sweeps a root inside the durable volume when this is the deployment that owns it" do
    ClonesDirectory.stubs(:base).returns(File.join(@scratch_base, "clones"))
    Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("production"))

    assert StaleCloneCleanupJob.new.send(:sweepable_root?, "scratch", @scratch_base)
  end

  test "skips a root that does not exist" do
    job = StaleCloneCleanupJob.new

    assert_not job.send(:sweepable_root?, "scratch", File.join(@scratch_base, "nope"))
    assert_not job.send(:sweepable_root?, "scratch", nil)
  end

  test "keeps sweeping the remaining roots when one cannot be listed" do
    file_service = FileStorageService.new(session_id: @orphan_id)
    file_service.store(data: "notes", filename: "notes.md")
    backdate(file_service.session_dir)
    FileUtils.mkdir_p(File.join(@scratch_base, @orphan_id.to_s))

    File.chmod(0o000, @scratch_base)

    assert_nothing_raised { StaleCloneCleanupJob.perform_now }
    assert_not Dir.exist?(file_service.session_dir),
      "an unlistable root must not stop the sweep from reaching the others"
  ensure
    File.chmod(0o755, @scratch_base)
  end

  private

  # Create the three per-session directories for an id, each with a file in it.
  def seed_all_roots(session_id)
    scratch = SessionScratchDirectory.ensure_for(session_id)
    File.write(File.join(scratch, "state.txt"), "state")

    file_service = FileStorageService.new(session_id: session_id)
    file_service.store(data: "notes", filename: "notes.md")

    image_service = ImageStorageService.new(session_id: session_id)
    png = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ].pack("C*") + ("x" * 32)
    image_service.store(data: Base64.strict_encode64(png), filename: "shot.png")

    [ scratch, file_service.session_dir, image_service.session_dir ]
  end

  def backdate(*paths, age: StaleCloneCleanupJob::ORPHAN_AGE_THRESHOLD + 1.hour)
    stamp = age.ago.to_time
    paths.each { |path| File.utime(stamp, stamp, path) }
  end
end

# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# zimmer#434. The half that stops the pile growing: when a clone goes, so does
# every transcript directory derived from a cwd inside it.
class TranscriptDirectoryReaperTest < ActiveSupport::TestCase
  setup do
    @clones_base = Dir.mktmpdir("transcript-reaper-clones")
    @projects_root = Dir.mktmpdir("transcript-reaper-projects")
    ClonesDirectory.stubs(:base).returns(@clones_base)
    ClaudeTranscriptSource.stubs(:projects_root).returns(@projects_root)

    @clone_name = "zimmer-main-1785661439-005ceef3"
    @clone_path = File.join(@clones_base, @clone_name)
    FileUtils.mkdir_p(@clone_path)
  end

  teardown do
    FileUtils.rm_rf(@clones_base)
    FileUtils.rm_rf(@projects_root)
  end

  test "removes the clone's own transcript directory" do
    dir = transcript_dir_for(@clone_path)

    assert_equal 1, TranscriptDirectoryReaper.reap_for_clone(@clone_path)
    assert_not File.directory?(dir)
  end

  test "removes the subdirectory-cwd transcript directory too" do
    own = transcript_dir_for(@clone_path)
    sub = transcript_dir_for(File.join(@clone_path, "zimmer"))

    assert_equal 2, TranscriptDirectoryReaper.reap_for_clone(@clone_path)
    assert_not File.directory?(own)
    assert_not File.directory?(sub), "an agent root with a subdirectory names its transcript dir " \
      "after <clone>/<subdir>, so the clone owns more than one"
  end

  test "leaves another clone's transcript directory alone" do
    other = transcript_dir_for(File.join(@clones_base, "zimmer-main-1770000000-deadbeef"))

    TranscriptDirectoryReaper.reap_for_clone(@clone_path)

    assert File.directory?(other)
  end

  test "leaves the non-clone directories alone" do
    survivors = %w[-rails -tmp-headless-inference-abc].map do |name|
      File.join(@projects_root, name).tap { |path| FileUtils.mkdir_p(path) }
    end

    TranscriptDirectoryReaper.reap_for_clone(@clone_path)

    survivors.each { |path| assert File.directory?(path) }
  end

  test "declines a path that is not a direct child of the clones base" do
    dir = transcript_dir_for(@clone_path)

    # The blast-radius fence. Without it, handing this the clones base itself
    # would match — and delete — every clone-derived transcript directory at once.
    assert_equal 0, TranscriptDirectoryReaper.reap_for_clone(@clones_base)
    assert_equal 0, TranscriptDirectoryReaper.reap_for_clone(File.join(@clone_path, "zimmer"))
    assert_equal 0, TranscriptDirectoryReaper.reap_for_clone("/")
    assert_equal 0, TranscriptDirectoryReaper.reap_for_clone(nil)

    assert File.directory?(dir)
  end

  test "unlinks a symlinked entry without following it to the target" do
    target = File.join(@projects_root, "-rails")
    FileUtils.mkdir_p(target)
    link = ClaudeTranscriptSource.new.transcript_directory(working_directory: @clone_path)
    File.symlink(target, link)

    assert_equal 1, TranscriptDirectoryReaper.reap_for_clone(@clone_path)
    assert_not File.symlink?(link)
    assert File.directory?(target), "rm_rf unlinks the link, never the tree it points at"
  end

  test "is a no-op when the projects root does not exist" do
    FileUtils.rm_rf(@projects_root)

    assert_equal 0, TranscriptDirectoryReaper.reap_for_clone(@clone_path)
  end

  test "only the runtimes with a per-working-directory root are swept" do
    sources = TranscriptDirectoryReaper.per_working_directory_sources

    assert_equal [ ClaudeTranscriptSource ], sources.map(&:class)
    assert_nil CodexTranscriptSource.new.per_working_directory_transcript_root,
      "Codex writes every session into one date-partitioned tree; a child of it is not attributable"
    assert_nil PiTranscriptSource.new.per_working_directory_transcript_root,
      "Pi writes inside the clone, so its transcripts already go when the clone does"
  end

  # --- through CloneReaper, which is where this actually fires ---------------

  test "CloneReaper takes the transcript directory with the clone" do
    own = transcript_dir_for(@clone_path)
    sub = transcript_dir_for(File.join(@clone_path, "zimmer"))

    assert_equal :removed, CloneReaper.reap(@clone_path, reason: "test")

    assert_not File.directory?(@clone_path)
    assert_not File.directory?(own)
    assert_not File.directory?(sub)
  end

  test "an absent clone path leaves the transcript directory to the sweep" do
    own = transcript_dir_for(@clone_path)
    FileUtils.rm_rf(@clone_path)

    # Nothing was removed here, so nothing is claimed to have been. The ordinary
    # producer of this is a second reaper reaching a clone the first already
    # took — whoever did remove it ran the hook — and if nobody did, the sweep
    # reclaims it rather than this deleting on the strength of an absent path.
    assert_equal :absent, CloneReaper.reap(@clone_path, reason: "test")
    assert File.directory?(own)
  end

  test "a refused clone keeps its transcript directory" do
    own = transcript_dir_for(@clone_path)
    sessions(:running).update!(metadata: { "clone_path" => @clone_path })

    assert_equal :refused, CloneReaper.reap(@clone_path, reason: "test")

    assert File.directory?(@clone_path)
    assert File.directory?(own), "the transcript must not go when the clone did not"
  end

  private

  # Create the transcript directory Claude Code would create for `working_directory`,
  # with a transcript file in it, through the app's own derivation.
  def transcript_dir_for(working_directory)
    dir = ClaudeTranscriptSource.new.transcript_directory(working_directory: working_directory)
    FileUtils.mkdir_p(File.join(dir, "tool-results"))
    File.write(File.join(dir, "#{SecureRandom.uuid}.jsonl"), "{}\n")
    dir
  end
end

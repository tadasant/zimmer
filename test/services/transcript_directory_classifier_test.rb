# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# zimmer#434. The classifier decides which transcript directories under
# `~/.claude/projects` get deleted, and the cost of a wrong `:orphaned` is a
# running session's conversation — the `.jsonl` `--resume` reads, which exists
# nowhere else on the box. So the two cases production surfaced (and staging did
# not) are pinned here explicitly.
class TranscriptDirectoryClassifierTest < ActiveSupport::TestCase
  CLONES_BASE = "/home/rails/.zimmer/clones"

  # A real clone name: {repo}-{branch}-{timestamp}-{random}.
  LIVE_CLONE = "zimmer-main-1785661439-005ceef3"
  DEAD_CLONE = "zimmer-main-1770000000-deadbeef"

  setup do
    @source = ClaudeTranscriptSource.new
  end

  # --- the name derivation these tests are built on -------------------------

  test "the derived name is the one Claude Code actually writes" do
    assert_equal "-home-rails--zimmer-clones-#{LIVE_CLONE}",
      File.basename(@source.transcript_directory(working_directory: "#{CLONES_BASE}/#{LIVE_CLONE}"))
  end

  # --- case 1: the slug comes from the cwd, not the clone root --------------

  test "a subdirectory-cwd directory belonging to a live clone is live, not orphaned" do
    classifier = classifier_with(live: [ LIVE_CLONE ])

    # An agent root with `subdirectory: zimmer` runs with cwd <clone>/zimmer, so
    # this is what Claude Code names its transcript directory. A classifier that
    # matched clone name -> directory name by equality would call it orphaned and
    # delete a running session's transcript.
    assert_equal :live, classifier.classify("-home-rails--zimmer-clones-#{LIVE_CLONE}-zimmer")
  end

  test "a nested subdirectory cwd is live too" do
    classifier = classifier_with(live: [ LIVE_CLONE ])

    assert_equal :live,
      classifier.classify("-home-rails--zimmer-clones-#{LIVE_CLONE}-apps-web")
  end

  test "the live clone's own directory is live" do
    assert_equal :live,
      classifier_with(live: [ LIVE_CLONE ]).classify("-home-rails--zimmer-clones-#{LIVE_CLONE}")
  end

  test "a subdirectory-cwd directory whose clone is gone is orphaned" do
    classifier = classifier_with(live: [ LIVE_CLONE ])

    assert_equal :orphaned, classifier.classify("-home-rails--zimmer-clones-#{DEAD_CLONE}-zimmer")
  end

  test "a clone-derived directory with no live clone behind it is orphaned" do
    assert_equal :orphaned,
      classifier_with(live: [ LIVE_CLONE ]).classify("-home-rails--zimmer-clones-#{DEAD_CLONE}")
  end

  test "a clone name that merely shares a prefix does not make another clone live" do
    # `zimmer-main-1785661439-005ceef3` and `zimmer-main-1785661439-005ceef9`
    # differ only in the last hex digit; neither is a `-`-extension of the other.
    classifier = classifier_with(live: [ LIVE_CLONE ])

    assert_equal :orphaned,
      classifier.classify("-home-rails--zimmer-clones-zimmer-main-1785661439-005ceef9")
  end

  test "a clone name containing dot and underscore is derived, not guessed" do
    # PathSanitizer maps `_` and `.` onto `-` as well as `/`, so the derived name
    # is not recoverable by string surgery on the clone name. Deriving forward is
    # the only way this matches.
    weird = "my_repo-release.v2-1785661439-005ceef3"
    classifier = classifier_with(live: [ weird ])

    assert_equal :live, classifier.classify("-home-rails--zimmer-clones-my-repo-release-v2-1785661439-005ceef3")
  end

  # --- case 2: not every transcript directory comes from a clone ------------

  test "a headless-inference directory under /tmp is orphaned" do
    # 2,543 of production's 6,612 directories. /tmp does not survive a container
    # restart, so no clone-based rule would ever reach these.
    assert_equal :orphaned, classifier_with.classify("-tmp-headless-inference-abc123")
  end

  test "the -tmp-test-clone-archived directory is orphaned" do
    assert_equal :orphaned, classifier_with.classify("-tmp-test-clone-archived")
  end

  test "-rails survives: it is live and nothing claims to know better" do
    # cwd /rails, the app root inside the container. Unrecognized shapes keep.
    assert_equal :unknown, classifier_with.classify("-rails")
  end

  test "an unrecognized directory keeps" do
    assert_equal :unknown, classifier_with.classify("-Users-someone-code-a-project")
  end

  test "the clones base itself as a cwd is unknown, not orphaned" do
    assert_equal :unknown, classifier_with.classify("-home-rails--zimmer-clones")
  end

  test "a blank entry keeps" do
    assert_equal :unknown, classifier_with.classify("")
    assert_equal :unknown, classifier_with.classify(nil)
  end

  # --- the production mix, end to end --------------------------------------

  # The most direct evidence that the data-loss risk is handled: the shape of
  # production's ~/.claude/projects as measured in zimmer#434, classified in one
  # pass, with the counts asserted.
  test "classifies a synthetic production mix without touching anything live" do
    live_clones = 3.times.map { |i| "zimmer-main-178566143#{i}-005ceef#{i}" }
    classifier = classifier_with(live: live_clones)

    entries = []
    # A live clone's own transcript directory, and its subdirectory-cwd sibling.
    live_clones.each do |clone|
      entries << "-home-rails--zimmer-clones-#{clone}"
      entries << "-home-rails--zimmer-clones-#{clone}-zimmer"
    end
    # Orphaned clone-derived directories, including subdirectory-cwd ones.
    10.times { |i| entries << "-home-rails--zimmer-clones-zimmer-main-17700000#{i}-deadbee#{i}" }
    4.times  { |i| entries << "-home-rails--zimmer-clones-zimmer-main-17600000#{i}-cafebab#{i}-zimmer" }
    # The /tmp class.
    5.times { |i| entries << "-tmp-headless-inference-#{i}" }
    entries << "-tmp-test-clone-archived"
    # Live and unattributable.
    entries << "-rails"

    counts = entries.group_by { |entry| classifier.classify(entry) }.transform_values(&:size)

    assert_equal 6,  counts[:live],     "3 live clones x (own cwd + subdirectory cwd)"
    assert_equal 20, counts[:orphaned], "10 clone-derived + 4 subdirectory-derived + 6 under /tmp"
    assert_equal 1,  counts[:unknown],  "-rails, which is live and must be preserved"

    # Every single kept directory, named, so a regression cannot hide in a count.
    kept = entries.reject { |entry| classifier.classify(entry) == :orphaned }
    live_clones.each do |clone|
      assert_includes kept, "-home-rails--zimmer-clones-#{clone}"
      assert_includes kept, "-home-rails--zimmer-clones-#{clone}-zimmer"
    end
    assert_includes kept, "-rails"
  end

  # --- derived_name + covers?, the clone-deletion direction -----------------
  #
  # Composed exactly as TranscriptDirectoryReaper composes them, so what is
  # pinned here is what production runs.

  test "a clone's derived name covers its own cwd and its subdirectory cwds" do
    name = TranscriptDirectoryClassifier.derived_name(
      transcript_source: @source, working_directory: "#{CLONES_BASE}/#{LIVE_CLONE}"
    )

    %W[
      -home-rails--zimmer-clones-#{LIVE_CLONE}
      -home-rails--zimmer-clones-#{LIVE_CLONE}-zimmer
      -home-rails--zimmer-clones-#{LIVE_CLONE}-apps-web
    ].each do |entry|
      assert TranscriptDirectoryClassifier.covers?(name, entry),
        "#{entry} should be covered by #{name}"
    end
  end

  test "a clone's derived name does not cover another clone's directory" do
    name = TranscriptDirectoryClassifier.derived_name(
      transcript_source: @source, working_directory: "#{CLONES_BASE}/#{LIVE_CLONE}"
    )

    assert_not TranscriptDirectoryClassifier.covers?(name, "-home-rails--zimmer-clones-#{DEAD_CLONE}")
  end

  test "a name that could not be derived covers nothing" do
    assert_nil TranscriptDirectoryClassifier.derived_name(transcript_source: @source, working_directory: "")
    assert_not TranscriptDirectoryClassifier.covers?(nil, "-home-rails--zimmer-clones-#{LIVE_CLONE}")
  end

  private

  def classifier_with(live: [])
    TranscriptDirectoryClassifier.new(
      transcript_source: @source, clones_base: CLONES_BASE, live_clone_names: live
    )
  end
end

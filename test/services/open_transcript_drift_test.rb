# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# The offline half of the drift guard.
#
# `app/services/open_transcript.rb` is a hand-written mirror of the OpenTranscripts
# v0.1 spec in pulsemcp/ai-artifacts. Drift can happen on either side of the pinned
# snapshot in `vendor/open_transcripts/`, so both sides are checked:
#
#   * snapshot ↔ upstream — scripts/check_open_transcripts_drift.rb, on a schedule
#   * Zimmer's Ruby ↔ snapshot — this file, on every CI run, with no network
#
# A failure here is not "someone broke the build". It is the question the whole
# mechanism exists to force: upstream says X, Zimmer says Y, which one is right?
class OpenTranscriptDriftTest < ActiveSupport::TestCase
  VENDOR_DIR = Rails.root.join("vendor", "open_transcripts")
  SNAPSHOT_DIR = VENDOR_DIR.join("upstream")
  MANIFEST_PATH = VENDOR_DIR.join("UPSTREAM.json")

  def manifest
    @manifest ||= JSON.parse(File.read(MANIFEST_PATH))
  end

  def snapshot(local)
    File.read(SNAPSHOT_DIR.join(local))
  end

  # --- The snapshot is intact -----------------------------------------------

  test "every file in the manifest exists in the snapshot" do
    manifest["files"].each do |entry|
      assert_path_exists SNAPSHOT_DIR.join(entry["local"]).to_s,
        "manifest lists #{entry['local']} but it is not in the snapshot"
    end
  end

  test "every snapshot file matches its recorded digest" do
    manifest["files"].each do |entry|
      actual = Digest::SHA256.hexdigest(File.binread(SNAPSHOT_DIR.join(entry["local"])))

      assert_equal entry["sha256"], actual,
        "#{entry['local']} no longer matches the digest in UPSTREAM.json. The snapshot is a " \
        "verbatim copy of upstream — edit it only by refreshing it, and update the digest " \
        "when you do (vendor/open_transcripts/README.md)."
    end
  end

  test "digest verification detects a tampered snapshot file" do
    Dir.mktmpdir do |dir|
      entry = manifest["files"].first
      tampered = File.join(dir, File.basename(entry["local"]))
      File.write(tampered, snapshot(entry["local"]) + "\n# a line upstream never wrote\n")

      refute_equal entry["sha256"], Digest::SHA256.hexdigest(File.binread(tampered)),
        "a modified snapshot file must not still hash to its recorded digest"
    end
  end

  test "the manifest pins a concrete upstream commit" do
    assert_match(/\A[0-9a-f]{40}\z/, manifest["ref"], "ref must be a full commit sha, not a branch name")
    assert_equal "pulsemcp/ai-artifacts", manifest["repository"]
    assert manifest["files"].any?, "the manifest must track at least one file"
  end

  # --- Zimmer's Ruby still agrees with the snapshot -------------------------

  test "OpenTranscript declares exactly the event types the snapshotted spec does" do
    # events.md documents the discriminators as `### 1. \`UserMessage\`` headings
    # under "The nine event types".
    spec_types = snapshot("schemas/events.md").scan(/^### \d+\.\s+`([A-Za-z]+)`/).flatten

    assert_equal 9, spec_types.length, "expected nine event types in the snapshotted spec, got #{spec_types.inspect}"
    assert_equal spec_types.sort, OpenTranscript::Types::ALL.sort,
      "OpenTranscript::Types has drifted from the snapshotted spec"
  end

  test "OpenTranscript declares the schema version the snapshotted spec does" do
    spec_version = snapshot("schemas/transcript.md")[/"schema_version":\s*"([^"]+)"/, 1]

    assert_equal spec_version, OpenTranscript::SCHEMA_VERSION
  end

  test "TranscriptRedactor covers every redaction label the upstream redactor ships" do
    upstream_labels = snapshot("redaction.py").scan(/^\s*\(\s*"([A-Z_]+)"/).flatten.uniq
    # The upstream file also declares some labels on their own line, ahead of a
    # multi-line compiled pattern.
    upstream_labels |= snapshot("redaction.py").scan(/^\s*"([A-Z_]+)",\s*$/).flatten

    assert upstream_labels.length >= 10, "failed to parse labels out of the upstream redactor: #{upstream_labels.inspect}"

    zimmer_labels = TranscriptRedactor::PATTERNS.map(&:label).uniq
    missing = upstream_labels - zimmer_labels

    assert_empty missing,
      "the upstream reference redactor covers #{missing.inspect} and Zimmer's does not. Either port " \
      "the pattern into TranscriptRedactor::PATTERNS or record why it does not apply here."
  end

  # --- The vendored mirror's own invariants ---------------------------------

  test "every declared event type is renderable and filterable" do
    OpenTranscript::Types::ALL.each do |type|
      refute_nil OpenTranscript.filter_category({ type: type }),
        "#{type} has no DOM filter category, so it would render into no filter bucket"
    end
  end
end

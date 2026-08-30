# frozen_string_literal: true

require "test_helper"

class TranscriptArchiveStatusTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("transcript_archive_status_test")
    @archive_path = Pathname.new(File.join(@dir, "latest.zip"))
    @metadata_path = Pathname.new(File.join(@dir, "latest_metadata.json"))
  end

  teardown do
    FileUtils.rm_rf(@dir) if @dir && File.directory?(@dir)
  end

  test "never_built when neither the zip nor its sidecar is there" do
    status = build_status

    assert_equal :never_built, status.state
    assert_not status.present?
    assert_match(/No transcript archive has ever been built at #{Regexp.escape(@archive_path.to_s)}/,
      status.unavailable_message)
    assert_match(/Waiting will not help on its own/, status.unavailable_message)
  end

  test "the unavailable message never promises a rebuild cadence as the recovery" do
    # The message this replaced — "The archive is built every 10 minutes." — asserted a
    # recovery the caller could not check and, under #714, could not ever happen.
    refute_match(/is built every 10 minutes/, build_status.unavailable_message)
  end

  test "missing when a previous run's sidecar survives but the zip does not" do
    write_metadata(generated_at: "2026-08-30T09:00:00Z", session_count: 12)

    status = build_status

    assert_equal :missing, status.state
    assert_not status.present?
    assert_match(/missing at #{Regexp.escape(@archive_path.to_s)}/, status.unavailable_message)
    assert_match(/12 session\(s\) at 2026-08-30T09:00:00Z/, status.unavailable_message)
  end

  test "present and fresh reports no staleness" do
    File.binwrite(@archive_path, "zip")
    write_metadata(generated_at: 4.minutes.ago.iso8601, session_count: 7, file_size_bytes: 2048)

    status = build_status

    assert_equal :present, status.state
    assert status.present?
    assert_not status.stale?
    assert_nil status.staleness_note
    assert_equal 7, status.session_count
    assert_equal 2048, status.file_size_bytes
  end

  test "present but old reports its actual age rather than withholding the archive" do
    File.binwrite(@archive_path, "zip")
    write_metadata(generated_at: 5.hours.ago.iso8601, session_count: 7)

    status = build_status

    assert status.present?, "a stale archive is still served"
    assert status.stale?
    assert_match(/5\.0 hours ago/, status.staleness_note)
    assert_match(/transcript_archive` cron job/, status.staleness_note)
  end

  test "falls back to the file's mtime when the sidecar is unreadable" do
    File.binwrite(@archive_path, "x" * 100)
    File.write(@metadata_path, "not json")

    status = build_status

    assert status.present?
    assert_equal 0, status.session_count
    assert_equal 100, status.file_size_bytes
    assert_in_delta File.mtime(@archive_path).to_f, status.generated_at.to_f, 2.0
  end

  test "an unparseable generated_at falls back to the file's mtime" do
    File.binwrite(@archive_path, "zip")
    write_metadata(generated_at: "whenever", session_count: 1)

    status = build_status

    # No usable timestamp in the sidecar, so it falls through to the zip's mtime —
    # which is now, so the archive reads as fresh. The age is observed either way;
    # nothing is invented from the recorded string.
    assert_in_delta File.mtime(@archive_path).to_f, status.generated_at.to_f, 2.0
    assert_not status.stale?
  end

  test "a zip that vanishes mid-request does not turn a 404 into a 500" do
    File.binwrite(@archive_path, "zip")
    status = build_status
    assert status.present?, "the stat is taken once, up front"

    FileUtils.rm_f(@archive_path)

    # present? is memoized, so the rest of the request still believes there is a file.
    # Both stats have to survive that rather than raising Errno::ENOENT out of a
    # response body.
    assert_nil status.generated_at
    assert_equal 0, status.file_size_bytes
    assert status.stale?, "an archive whose age cannot be read is not current"
  end

  private

  def build_status(stale_after: 1.hour)
    TranscriptArchiveStatus.new(
      archive_path: @archive_path, metadata_path: @metadata_path, stale_after: stale_after
    )
  end

  def write_metadata(**attrs)
    File.write(@metadata_path, attrs.transform_keys(&:to_s).to_json)
  end
end

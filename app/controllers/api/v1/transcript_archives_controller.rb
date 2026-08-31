# frozen_string_literal: true

# API controller for downloading pre-built transcript archive zip files.
#
# The archive is built incrementally by TranscriptArchiveJob (runs every 10 minutes)
# in the `worker` container, and read here in the `web` one — see the job's
# ARCHIVE_SUBDIR comment for why that dictates where it lives.
#
# Endpoints:
#   GET /api/v1/transcript_archive/download - Download the zip file
#   GET /api/v1/transcript_archive/status   - Get archive metadata (JSON)
#
# When there is no archive, both endpoints report what was observed on disk rather
# than a build cadence the caller cannot check — see TranscriptArchiveStatus.
#
class Api::V1::TranscriptArchivesController < Api::BaseController
  def download
    archive = archive_status
    unless archive.present?
      render_unavailable(archive)
      return
    end

    response.headers["X-Archive-Generated-At"] = archive.generated_at&.iso8601.to_s
    response.headers["X-Archive-Session-Count"] = archive.session_count.to_s
    response.headers["X-Archive-Stale"] = archive.stale?.to_s

    send_file archive.archive_path,
      type: "application/zip",
      filename: "transcript_archive_#{Time.current.strftime('%Y%m%d_%H%M%S')}.zip",
      disposition: "attachment"
  end

  def status
    archive = archive_status
    unless archive.present?
      render_unavailable(archive)
      return
    end

    render json: {
      state: archive.state,
      generated_at: archive.generated_at&.iso8601,
      session_count: archive.session_count,
      file_size_bytes: archive.file_size_bytes,
      stale: archive.stale?,
      stale_reason: archive.staleness_note,
      complete: archive.complete?,
      deferred_count: archive.deferred_count,
      incomplete_reason: archive.incompleteness_note
    }
  end

  private

  # The 404 both actions share. Keeps the API's standard error envelope and adds
  # the two facts that make the failure diagnosable without a shell on the box:
  # which state was observed, and at which path.
  def render_unavailable(archive)
    render_api_error(
      "Not Found",
      archive.unavailable_message,
      status: :not_found,
      state: archive.state,
      archive_path: archive.archive_path.to_s
    )
  end

  # Overridable in tests, and the single seam both actions read through.
  def archive_path
    TranscriptArchiveJob.archive_path
  end

  def metadata_path
    TranscriptArchiveJob.metadata_path
  end

  def archive_status
    @archive_status ||= TranscriptArchiveStatus.new(archive_path: archive_path, metadata_path: metadata_path)
  end
end

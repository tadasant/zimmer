# frozen_string_literal: true

# API controller for downloading pre-built transcript archive zip files.
#
# The archive is built incrementally by TranscriptArchiveJob (runs every 10 minutes).
# This controller serves the pre-built file and provides status metadata.
#
# Endpoints:
#   GET /api/v1/transcript_archive/download - Download the zip file
#   GET /api/v1/transcript_archive/status   - Get archive metadata (JSON)
#
class Api::V1::TranscriptArchivesController < Api::BaseController
  def download
    unless File.exist?(archive_path)
      render json: { error: "Not Found", message: "No transcript archive exists yet. The archive is built every 10 minutes." }, status: :not_found
      return
    end

    metadata = load_metadata

    response.headers["X-Archive-Generated-At"] = metadata["generated_at"] || ""
    response.headers["X-Archive-Session-Count"] = (metadata["session_count"] || 0).to_s

    send_file archive_path,
      type: "application/zip",
      filename: "transcript_archive_#{Time.current.strftime('%Y%m%d_%H%M%S')}.zip",
      disposition: "attachment"
  end

  def status
    unless File.exist?(archive_path)
      render json: { error: "Not Found", message: "No transcript archive exists yet. The archive is built every 10 minutes." }, status: :not_found
      return
    end

    metadata = load_metadata

    render json: {
      generated_at: metadata["generated_at"],
      session_count: metadata["session_count"] || 0,
      file_size_bytes: metadata["file_size_bytes"] || (File.exist?(archive_path) ? File.size(archive_path) : 0)
    }
  end

  private

  def archive_path
    TranscriptArchiveJob::ARCHIVE_PATH
  end

  def metadata_path
    TranscriptArchiveJob::METADATA_PATH
  end

  def load_metadata
    return {} unless File.exist?(metadata_path)

    JSON.parse(File.read(metadata_path))
  rescue JSON::ParserError
    {}
  end
end

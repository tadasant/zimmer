# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors GET /api/v1/transcript_archive/status, and hands back the download
    # URL for GET /api/v1/transcript_archive/download. The archive itself is a
    # pre-built zip produced by TranscriptArchiveJob; the tool never builds it.
    #
    # When there is no archive this reports what was observed on disk — see
    # TranscriptArchiveStatus — rather than promising a rebuild the caller cannot
    # verify. It used to say "the archive is built every 10 minutes", which told
    # every caller to wait ten minutes for a file that (while the writer and this
    # reader were in different containers) could never appear (#714).
    class GetTranscriptArchive < Tool
      DOWNLOAD_PATH = "/api/v1/transcript_archive/download"

      tool_name "get_transcript_archive"

      description <<~DESC
        Get the download URL and curl command for the transcript archive zip file.

        Returns the download URL, a ready-to-use curl command, and archive metadata (generation time, session count, file size, and whether the archive is stale). The archive is rebuilt incrementally by a cron job and contains all session transcripts.

        **Use cases:**
        - Download all session transcripts as a zip archive for backup or analysis
        - Get archive metadata to check when it was last generated and how many sessions it contains

        **Not the way to find a session by something said in it.** The archive is hundreds of megabytes and up to ten minutes stale. Use `quick_search_sessions` with `search_contents: true`, which searches transcript text server-side.
      DESC

      input_schema({
        type: "object",
        properties: {},
        required: []
      })

      def call(_args)
        archive = TranscriptArchiveStatus.new(archive_path: archive_path, metadata_path: metadata_path)
        raise ToolError, archive.unavailable_message unless archive.present?

        url = "#{context.base_url.chomp('/')}#{DOWNLOAD_PATH}"
        staleness = archive.staleness_note
        incompleteness = archive.incompleteness_note

        <<~TEXT.strip
          ## Transcript Archive

          - **Generated At:** #{archive.generated_at&.iso8601 || 'unknown'}
          - **Session Count:** #{archive.session_count}
          - **File Size:** #{format_file_size(archive.file_size_bytes)}
          - **Stale:** #{staleness ? "yes — #{staleness}" : 'no'}
          - **Complete:** #{incompleteness ? "no — #{incompleteness}" : 'yes'}

          ### Download

          **URL:** `#{url}`

          To download, run:
          ```bash
          curl -o /path/to/transcript-archive.zip -H "X-API-Key: $ZIMMER_API_KEY" "#{url}"
          ```
        TEXT
      end

      private

      def archive_path
        TranscriptArchiveJob.archive_path
      end

      def metadata_path
        TranscriptArchiveJob.metadata_path
      end

      def format_file_size(bytes)
        bytes = bytes.to_i
        return "#{bytes} B" if bytes < 1024
        return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024
        return "#{(bytes / (1024.0 * 1024)).round(1)} MB" if bytes < 1024 * 1024 * 1024
        "#{(bytes / (1024.0 * 1024 * 1024)).round(1)} GB"
      end
    end
  end
end

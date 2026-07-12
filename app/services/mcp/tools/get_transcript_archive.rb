# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors GET /api/v1/transcript_archive/status, and hands back the download
    # URL for GET /api/v1/transcript_archive/download. The archive itself is a
    # pre-built zip produced by TranscriptArchiveJob; the tool never builds it.
    class GetTranscriptArchive < Tool
      DOWNLOAD_PATH = "/api/v1/transcript_archive/download"

      tool_name "get_transcript_archive"

      description <<~DESC
        Get the download URL and curl command for the transcript archive zip file.

        Returns the download URL, a ready-to-use curl command, and archive metadata (generation time, session count, file size). The archive is built incrementally every 10 minutes and contains all session transcripts.

        **Use cases:**
        - Download all session transcripts as a zip archive for backup or analysis
        - Get archive metadata to check when it was last generated and how many sessions it contains
      DESC

      input_schema({
        type: "object",
        properties: {},
        required: []
      })

      def call(_args)
        unless File.exist?(archive_path)
          raise ToolError, "No transcript archive exists yet. The archive is built every 10 minutes."
        end

        metadata = load_metadata
        url = "#{context.base_url.chomp('/')}#{DOWNLOAD_PATH}"

        <<~TEXT.strip
          ## Transcript Archive

          - **Generated At:** #{metadata['generated_at']}
          - **Session Count:** #{metadata['session_count'] || 0}
          - **File Size:** #{format_file_size(metadata['file_size_bytes'] || File.size(archive_path))}

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

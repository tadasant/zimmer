# FileStorageService - Storage for non-image session attachments
#
# The SessionAttachmentStorage subclass for text, source code, logs, JSON, CSV,
# PDFs and anything else that is not an image. The lifecycle — durable storage
# root, per-session directory, path-traversal guard, reaping — lives in
# SessionAttachmentStorage; this class adds filename sanitisation and the
# store/copy behaviour that is specific to arbitrary files.
#
# Usage:
#   service = FileStorageService.new(session_id: 123)
#
#   # Store a file from upload
#   result = service.store(uploaded_file: file)
#   result[:path]              # => ".../agent-orchestrator-files/123/abc123-notes.md"
#   result[:original_filename] # => "notes.md"
#   result[:size]              # => 12345
#
#   # List files
#   service.list # => [".../agent-orchestrator-files/123/abc123-notes.md", ...]
#
#   # Clean up session files
#   service.cleanup!
#
# Storage location:
#   <storage_root>/<session_id>/<unique_id>-<sanitized_filename>
#
# Maximum size: 500MB per file
#
# Unlike ImageStorageService, this service does NOT inspect file contents
# (no magic-byte detection). It simply stores arbitrary bytes and lets the
# agent decide how to read them. The original filename is preserved (sanitized
# and prefixed with a unique ID to prevent collisions and traversal).
#
class FileStorageService < SessionAttachmentStorage
  class FileStorageError < StandardError; end
  class InvalidFileError < FileStorageError; end
  class StorageError < FileStorageError; end

  # Maximum file size: 500MB
  MAX_FILE_SIZE = 500.megabytes

  # Subdirectory (under the durable ~/.zimmer root) that holds general files.
  STORAGE_SUBDIR = "agent-orchestrator-files"

  # Maximum length for a sanitized filename component (preserves agent-readability)
  MAX_FILENAME_LENGTH = 120

  def self.storage_env_var = "AGENT_FILES_DIR"
  def self.storage_subdir = STORAGE_SUBDIR
  def self.attachment_noun = "file"

  # Store a file from an uploaded file or raw binary data.
  #
  # @param uploaded_file [ActionDispatch::Http::UploadedFile, nil] Uploaded file object
  # @param data [String, nil] Raw binary content (used when uploaded_file is not present)
  # @param filename [String, nil] Filename to use when storing raw data
  # @return [Hash] { path:, original_filename:, size: }
  def store(uploaded_file: nil, data: nil, filename: nil)
    if uploaded_file.present?
      content = uploaded_file.read
      original_filename = uploaded_file.original_filename
    elsif data.present?
      content = data
      original_filename = filename
    else
      raise InvalidFileError, "No file data provided"
    end

    if original_filename.blank?
      raise InvalidFileError, "Filename is required"
    end

    if content.bytesize > MAX_FILE_SIZE
      raise InvalidFileError, "File exceeds maximum size of #{MAX_FILE_SIZE / 1.megabyte}MB"
    end

    safe_basename = sanitize_filename(original_filename)
    unique_id = SecureRandom.hex(8)
    storage_filename = "#{unique_id}-#{safe_basename}"
    storage_path = File.join(session_dir, storage_filename)

    ensure_directory_exists(session_dir)
    @file_system.binwrite(storage_path, content)

    {
      path: storage_path,
      original_filename: original_filename,
      size: content.bytesize
    }
  end

  # Re-store one file into another session (see SessionAttachmentStorage#copy_entry).
  #
  # Files are copied verbatim; nothing is ever dropped.
  def copy_entry(content:, old_path:, destination:)
    # The old filename is "<unique_id>-<sanitized_original>"; recover the
    # sanitized original portion so the new entry has a clean basename
    # (a fresh unique_id is generated on store).
    original_filename = File.basename(old_path).sub(/\A[a-f0-9]+-/, "")

    destination.store(data: content, filename: original_filename)
  end

  private

  # Sanitize a filename to prevent path traversal and other shenanigans.
  # Strips any directory components, limits to safe characters, and caps length.
  # Preserves the extension where possible so the agent can recognize file types.
  def sanitize_filename(filename)
    # Strip any path components (defense against "../etc/passwd" style names).
    base = File.basename(filename.to_s)

    # Replace anything that isn't alphanumeric, dot, dash, or underscore with "_".
    # This avoids spaces, quotes, shell metacharacters, etc. in stored filenames.
    cleaned = base.gsub(/[^A-Za-z0-9._-]/, "_")

    # Collapse runs of underscores to keep names tidy.
    cleaned = cleaned.gsub(/_+/, "_")

    # Strip leading dots/dashes so we don't create hidden files or files that
    # look like CLI flags.
    cleaned = cleaned.sub(/\A[.\-_]+/, "")

    cleaned = "file" if cleaned.blank?

    # Cap length while preserving the extension.
    if cleaned.length > MAX_FILENAME_LENGTH
      ext = File.extname(cleaned)
      stem = File.basename(cleaned, ext)
      max_stem = MAX_FILENAME_LENGTH - ext.length
      max_stem = 1 if max_stem < 1
      cleaned = "#{stem[0, max_stem]}#{ext}"
    end

    cleaned
  end
end

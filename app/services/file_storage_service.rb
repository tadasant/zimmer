# FileStorageService - Abstraction for temporary general-file storage
#
# Sibling to ImageStorageService for non-image attachments (text, source code,
# logs, JSON, CSV, PDFs, etc.). Stores files on the local /tmp filesystem keyed
# by session, with the same lifecycle (temp_<uuid> → real session migration on
# session create).
#
# Usage:
#   service = FileStorageService.new(session_id: 123)
#
#   # Store a file from upload
#   result = service.store(uploaded_file: file)
#   result[:path]              # => "/tmp/agent-orchestrator-files/123/abc123-notes.md"
#   result[:original_filename] # => "notes.md"
#   result[:size]              # => 12345
#
#   # List files
#   service.list # => ["/tmp/agent-orchestrator-files/123/abc123-notes.md", ...]
#
#   # Clean up session files
#   service.cleanup!
#
# Storage location:
#   /tmp/agent-orchestrator-files/<session_id>/<unique_id>-<sanitized_filename>
#
# Maximum size: 500MB per file
#
# Unlike ImageStorageService, this service does NOT inspect file contents
# (no magic-byte detection). It simply stores arbitrary bytes and lets the
# agent decide how to read them. The original filename is preserved (sanitized
# and prefixed with a unique ID to prevent collisions and traversal).
#
class FileStorageService
  class FileStorageError < StandardError; end
  class InvalidFileError < FileStorageError; end
  class StorageError < FileStorageError; end

  # Maximum file size: 500MB
  MAX_FILE_SIZE = 500.megabytes

  # Base directory for file storage
  BASE_DIR = "/tmp/agent-orchestrator-files".freeze

  # Maximum length for a sanitized filename component (preserves agent-readability)
  MAX_FILENAME_LENGTH = 120

  attr_reader :session_id, :file_system

  def initialize(session_id:, file_system: nil)
    # Validate session_id to prevent path traversal attacks
    # Accept positive integers OR strings matching temp_<uuid> pattern for pre-session uploads
    if session_id.is_a?(Integer) && session_id > 0
      @session_id = session_id.to_s
    elsif session_id.is_a?(String) && session_id.match?(/\Atemp_[a-f0-9\-]+\z/)
      @session_id = session_id
    else
      raise ArgumentError, "session_id must be a positive integer or temp_<uuid> string"
    end
    @file_system = file_system || RealFileSystemAdapter.new
  end

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

  # Check if a file path exists and is within the session directory.
  # Uses File.expand_path to prevent path traversal attacks via ".." sequences.
  def exists?(path)
    return false unless path.present?

    resolved_path = File.expand_path(path)
    resolved_session_dir = File.expand_path(session_dir)

    return false unless resolved_path.start_with?(resolved_session_dir + "/") ||
                        resolved_path == resolved_session_dir

    @file_system.exists?(resolved_path)
  end

  # Clean up all files for this session.
  def cleanup!
    dir = session_dir
    return unless File.directory?(dir)

    FileUtils.rm_rf(dir)
  rescue => e
    Rails.logger.warn("Failed to cleanup files for session #{session_id}: #{e.message}")
  end

  # List all files for this session.
  def list
    dir = session_dir
    return [] unless File.directory?(dir)

    Dir.glob(File.join(dir, "*")).select { |f| File.file?(f) }
  end

  # Copy files from a temporary session to the real session.
  # Used when creating a new session with pre-uploaded files.
  #
  # @param temp_session_id [String] The temporary session ID (temp_<uuid>)
  # @param new_session_id [Integer] The real session ID
  # @return [Array<Hash>] Updated file metadata with new paths
  def self.copy_from_temp(temp_session_id:, new_session_id:)
    temp_service = new(session_id: temp_session_id)
    new_service = new(session_id: new_session_id)

    copied = []

    temp_service.list.each do |old_path|
      begin
        content = File.binread(old_path)
        # The old filename is "<unique_id>-<sanitized_original>"; recover the
        # sanitized original portion so the new entry has a clean basename
        # (a fresh unique_id is generated on store).
        old_basename = File.basename(old_path)
        original_filename = old_basename.sub(/\A[a-f0-9]+-/, "")

        result = new_service.store(data: content, filename: original_filename)
        copied << result
      rescue => e
        Rails.logger.error("Failed to copy file from temp storage #{old_path}: #{e.message}")
        # Continue with other files rather than failing entirely
      end
    end

    temp_service.cleanup!

    copied
  end

  # Root directory under which all session directories live.
  #
  # In production and development this is BASE_DIR verbatim. In the test
  # environment it is namespaced per worker *process* so that parallel test
  # workers cannot delete each other's files.
  #
  # Parallel test workers run in separate processes, each with its own test
  # database. Because `fixtures :all` seeds every worker's database identically,
  # `Session.create!` hands out colliding ids across workers (and the service
  # tests pick random ids from the same range). All workers otherwise share the
  # single BASE_DIR on /tmp, so one worker's teardown `cleanup!` would wipe the
  # session directory another worker is still reading from — producing
  # intermittent ENOENT errors. Keying the root by Process.pid gives each worker
  # an isolated tree. See issues #3455 and #3741.
  def self.base_dir
    return BASE_DIR unless Rails.env.test?

    File.join(BASE_DIR, "test-worker-#{Process.pid}")
  end

  # Get storage directory for this session.
  def session_dir
    File.join(self.class.base_dir, session_id.to_s)
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

  def ensure_directory_exists(dir)
    return if File.directory?(dir)

    FileUtils.mkdir_p(dir, mode: 0o755)
  end
end

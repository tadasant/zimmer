# ImageStorageService - Abstraction for temporary image storage
#
# This service provides a pluggable interface for storing images attached to
# agent session prompts. Stores images on the durable `~/.zimmer` volume, but is
# designed to be easily extended for more persistent storage (S3, etc.).
#
# Usage:
#   service = ImageStorageService.new(session_id: 123)
#
#   # Store an image (from base64 or file upload)
#   result = service.store(
#     data: base64_string,        # OR
#     uploaded_file: file,        # ActionDispatch::Http::UploadedFile
#     filename: "screenshot.png"
#   )
#   result[:path]      # => ".../agent-orchestrator-images/123/abc123.png"
#   result[:media_type] # => "image/png"
#
#   # Retrieve an image as base64 for CLI
#   base64, media_type = service.retrieve_base64(path)
#
#   # Clean up session images
#   service.cleanup!
#
# Storage location:
#   <storage_root>/<session_id>/<uuid>.<ext>
#
# where <storage_root> resolves under the durable `zimmer_data` volume shared by
# the web and worker containers (see .base_dir). Cross-container visibility is
# load-bearing: the web container writes the upload and the worker container's
# agent reads it back to base64-inline it, so the bytes MUST live on a mount both
# roles see.
#
# Supported formats: JPEG, PNG, GIF, WebP
# Maximum size: 10MB per image
#
class ImageStorageService
  class ImageStorageError < StandardError; end
  class InvalidImageError < ImageStorageError; end
  class StorageError < ImageStorageError; end

  # Supported image types and their file extensions
  SUPPORTED_TYPES = {
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/gif" => "gif",
    "image/webp" => "webp"
  }.freeze

  # Maximum image size: 10MB
  MAX_IMAGE_SIZE = 10.megabytes

  # Subdirectory (under the durable ~/.zimmer root) that holds images.
  STORAGE_SUBDIR = "agent-orchestrator-images"

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

  # Store an image from either base64 data or an uploaded file
  #
  # @param data [String, nil] Base64-encoded image data
  # @param uploaded_file [ActionDispatch::Http::UploadedFile, nil] Uploaded file object
  # @param filename [String, nil] Original filename (used for extension detection)
  # @return [Hash] { path: String, media_type: String, size: Integer }
  def store(data: nil, uploaded_file: nil, filename: nil)
    if data.present?
      store_from_base64(data, filename)
    elsif uploaded_file.present?
      store_from_upload(uploaded_file)
    else
      raise InvalidImageError, "No image data provided"
    end
  end

  # Retrieve an image as base64 for passing to CLI
  #
  # @param path [String] Path to the stored image
  # @return [Array<String, String>] [base64_data, media_type]
  def retrieve_base64(path)
    unless @file_system.exists?(path)
      raise StorageError, "Image not found: #{path}"
    end

    content = @file_system.binread(path)
    media_type = detect_media_type_from_content(content)

    [ Base64.strict_encode64(content), media_type ]
  end

  # Check if an image path exists and is valid
  # Uses File.expand_path to prevent path traversal attacks via ".." sequences
  #
  # @param path [String] Path to check
  # @return [Boolean]
  def exists?(path)
    return false unless path.present?

    # Resolve any ".." or "." in the path to prevent traversal attacks
    resolved_path = File.expand_path(path)
    resolved_session_dir = File.expand_path(session_dir)

    # Ensure the resolved path is within our session directory
    return false unless resolved_path.start_with?(resolved_session_dir + "/") ||
                        resolved_path == resolved_session_dir

    @file_system.exists?(resolved_path)
  end

  # Clean up all images for this session
  def cleanup!
    dir = session_dir
    return unless File.directory?(dir)

    FileUtils.rm_rf(dir)
  rescue => e
    Rails.logger.warn("Failed to cleanup images for session #{session_id}: #{e.message}")
  end

  # List all images for this session
  #
  # @return [Array<String>] Paths to stored images
  def list
    dir = session_dir
    return [] unless File.directory?(dir)

    Dir.glob(File.join(dir, "*")).select { |f| File.file?(f) }
  end

  # Copy images from a temporary session to the real session
  # Used when creating a new session with pre-uploaded images
  #
  # @param temp_session_id [String] The temporary session ID (temp_<uuid>)
  # @param new_session_id [Integer] The real session ID
  # @return [Array<Hash>] Updated image metadata with new paths
  def self.copy_from_temp(temp_session_id:, new_session_id:)
    temp_service = new(session_id: temp_session_id)
    new_service = new(session_id: new_session_id)

    copied_images = []

    temp_service.list.each do |old_path|
      begin
        # Read the image content
        content = File.binread(old_path)
        media_type = temp_service.send(:detect_media_type_from_content, content)
        next unless media_type

        # Store in new location
        result = new_service.store(data: Base64.strict_encode64(content), filename: File.basename(old_path))
        copied_images << result
      rescue => e
        Rails.logger.error("Failed to copy image from temp storage #{old_path}: #{e.message}")
        # Continue with other images rather than failing entirely
      end
    end

    # Clean up temp directory
    temp_service.cleanup!

    copied_images
  end

  # Root of the image storage tree, before per-session subdirectories.
  #
  # Resolves under the durable `zimmer_data` volume (~/.zimmer) — a sibling of
  # ClonesDirectory.base, the SAME mount that is bind-mounted into BOTH the web
  # and worker containers in production. This cross-container visibility is the
  # whole point: an upload written by the web role (Puma) has to be readable by
  # the agent running in the worker role (GoodJob :external), which reads the
  # file back to base64-inline it. Per-container `/tmp` is an ephemeral overlay
  # that is NOT shared between the two roles, so files written there never reach
  # the worker (see limitations #74).
  #
  # Override with the AGENT_IMAGES_DIR environment variable. If you point it
  # OUTSIDE the mounted named volume you MUST add a corresponding durable volume
  # mount that both roles share, or the worker will not see uploads. Resolved at
  # call time (never memoized) so tests that stub HOME and ops that set the
  # override are both honored without a process restart.
  def self.storage_root
    configured = ENV["AGENT_IMAGES_DIR"].presence
    return File.expand_path(configured) if configured

    File.join(File.dirname(ClonesDirectory.base), STORAGE_SUBDIR)
  end

  # Root directory under which all session directories live.
  #
  # In production and development this is storage_root verbatim. In the test
  # environment it is namespaced per worker *process* so that parallel test
  # workers cannot delete each other's files.
  #
  # Parallel test workers run in separate processes, each with its own test
  # database. Because `fixtures :all` seeds every worker's database identically,
  # `Session.create!` hands out colliding ids across workers. All workers
  # otherwise share the single storage_root, so one worker's teardown
  # `cleanup!` would wipe the session directory another worker is still reading
  # from — producing intermittent ENOENT errors. Keying the root by Process.pid
  # gives each worker an isolated tree. See issues #3455 and #3741.
  def self.base_dir
    return storage_root unless Rails.env.test?

    File.join(storage_root, "test-worker-#{Process.pid}")
  end

  # Get storage directory for this session
  def session_dir
    File.join(self.class.base_dir, session_id.to_s)
  end

  private

  def store_from_base64(data, filename = nil)
    # Decode base64
    binary_data = Base64.strict_decode64(data)
    validate_and_store(binary_data, filename)
  rescue ArgumentError => e
    raise InvalidImageError, "Invalid base64 data: #{e.message}"
  end

  def store_from_upload(uploaded_file)
    binary_data = uploaded_file.read
    filename = uploaded_file.original_filename
    content_type = uploaded_file.content_type

    # If content_type provided, validate it
    if content_type.present? && !SUPPORTED_TYPES.key?(content_type)
      raise InvalidImageError, "Unsupported image type: #{content_type}"
    end

    validate_and_store(binary_data, filename)
  end

  def validate_and_store(binary_data, filename = nil)
    # Check size
    if binary_data.bytesize > MAX_IMAGE_SIZE
      raise InvalidImageError, "Image exceeds maximum size of #{MAX_IMAGE_SIZE / 1.megabyte}MB"
    end

    # Detect media type from content (magic bytes)
    media_type = detect_media_type_from_content(binary_data)
    unless media_type
      raise InvalidImageError, "Could not detect image type - unsupported format"
    end

    # Generate storage path
    extension = SUPPORTED_TYPES[media_type]
    unique_id = SecureRandom.hex(16)
    storage_path = File.join(session_dir, "#{unique_id}.#{extension}")

    # Ensure directory exists
    ensure_directory_exists(session_dir)

    # Write file as binary (images contain non-UTF8 bytes)
    @file_system.binwrite(storage_path, binary_data)

    {
      path: storage_path,
      media_type: media_type,
      size: binary_data.bytesize,
      filename: filename
    }
  end

  def detect_media_type_from_content(binary_data)
    return nil if binary_data.nil? || binary_data.bytesize < 4

    # Check magic bytes
    bytes = binary_data.bytes

    # PNG: 89 50 4E 47 (0x89 'P' 'N' 'G')
    if bytes[0..3] == [ 0x89, 0x50, 0x4E, 0x47 ]
      return "image/png"
    end

    # JPEG: FF D8 FF
    if bytes[0..2] == [ 0xFF, 0xD8, 0xFF ]
      return "image/jpeg"
    end

    # GIF: 47 49 46 38 ('G' 'I' 'F' '8')
    if bytes[0..3] == [ 0x47, 0x49, 0x46, 0x38 ]
      return "image/gif"
    end

    # WebP: 52 49 46 46 ... 57 45 42 50 ('R' 'I' 'F' 'F' ... 'W' 'E' 'B' 'P')
    if bytes[0..3] == [ 0x52, 0x49, 0x46, 0x46 ] && bytes[8..11] == [ 0x57, 0x45, 0x42, 0x50 ]
      return "image/webp"
    end

    nil
  end

  def ensure_directory_exists(dir)
    return if File.directory?(dir)

    FileUtils.mkdir_p(dir, mode: 0o755)
  end
end

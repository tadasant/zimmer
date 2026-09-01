# ImageStorageService - Storage for image session attachments
#
# The SessionAttachmentStorage subclass for images attached to agent session
# prompts. The lifecycle — durable storage root, per-session directory,
# path-traversal guard, reaping — lives in SessionAttachmentStorage; this class
# adds magic-byte media-type sniffing, size/format validation, and base64
# retrieval for the CLI.
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
# Supported formats: JPEG, PNG, GIF, WebP
# Maximum size: 10MB per image
#
class ImageStorageService < SessionAttachmentStorage
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

  def self.storage_env_var = "AGENT_IMAGES_DIR"
  def self.storage_subdir = STORAGE_SUBDIR
  def self.attachment_noun = "image"

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

  # Re-store one image into another session (see SessionAttachmentStorage#copy_entry).
  #
  # An entry whose media type cannot be sniffed from its bytes is dropped rather
  # than copied — the destination's #store would reject it anyway.
  def copy_entry(content:, old_path:, destination:)
    return nil unless detect_media_type_from_content(content)

    destination.store(data: Base64.strict_encode64(content), filename: File.basename(old_path))
  end

  # Describe one stored image (see SessionAttachmentStorage#describe_entry).
  #
  # The media type is sniffed from the bytes, the same way it was when the image
  # was first stored — so the description is derived from the image rather than
  # from a filename anyone could have chosen. An entry whose type cannot be
  # sniffed is dropped, for the same reason #copy_entry drops it: the CLI has
  # nothing to put in the message's `media_type`.
  def describe_entry(path)
    media_type = detect_media_type_from_content(@file_system.binread(path))
    return nil unless media_type

    { path: path, media_type: media_type }
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
end

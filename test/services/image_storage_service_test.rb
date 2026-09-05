require "test_helper"
require "mocha/minitest"

# Covers what is genuinely ImageStorageService's own: magic-byte sniffing,
# format/size validation, and base64 retrieval. The lifecycle it shares with
# FileStorageService — resolved storage paths, session_id validation, the
# exists? traversal guard, list, cleanup, copy_from_temp — is asserted by
# SessionAttachmentStorageConformance, which runs against both subclasses.
class ImageStorageServiceTest < ActiveSupport::TestCase
  include SessionAttachmentStorageConformance

  def storage_class = ImageStorageService
  def storage_env_var = "AGENT_IMAGES_DIR"
  def expected_storage_subdir = "agent-orchestrator-images"
  def expected_attachment_noun = "image"

  # Conformance hook: store one attachment and return its metadata.
  def store_sample(service, filename: nil)
    service.store(data: Base64.strict_encode64(create_minimal_png), filename: "#{filename || 'sample'}.png")
  end

  def setup
    @service = conformance_service

    # Create a valid PNG image (1x1 pixel, red)
    @valid_png = create_minimal_png
    @valid_png_base64 = Base64.strict_encode64(@valid_png)
  end

  # Helper to create a minimal valid PNG (1x1 red pixel)
  def create_minimal_png
    # PNG signature
    png = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ].pack("C*")

    # IHDR chunk - 1x1 pixels, 8-bit depth, RGB
    ihdr_data = [ 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0 ].pack("C*")
    ihdr_crc = Zlib.crc32("IHDR" + ihdr_data)
    png += [ ihdr_data.length ].pack("N") + "IHDR" + ihdr_data + [ ihdr_crc ].pack("N")

    # IDAT chunk - compressed image data (1 red pixel)
    raw_data = [ 0, 255, 0, 0 ].pack("C*") # filter byte + RGB
    compressed = Zlib::Deflate.deflate(raw_data)
    idat_crc = Zlib.crc32("IDAT" + compressed)
    png += [ compressed.length ].pack("N") + "IDAT" + compressed + [ idat_crc ].pack("N")

    # IEND chunk
    iend_crc = Zlib.crc32("IEND")
    png += [ 0 ].pack("N") + "IEND" + [ iend_crc ].pack("N")

    png
  end

  test "stores image from base64 data" do
    result = @service.store(data: @valid_png_base64, filename: "test.png")

    assert result[:path].present?
    assert result[:path].start_with?(@service.session_dir)
    assert_equal "image/png", result[:media_type]
    assert result[:size] > 0
    assert File.exist?(result[:path])
  end

  test "stores image from uploaded file" do
    # Create a mock uploaded file
    uploaded_file = mock("uploaded_file")
    uploaded_file.stubs(:read).returns(@valid_png)
    uploaded_file.stubs(:original_filename).returns("test.png")
    uploaded_file.stubs(:content_type).returns("image/png")

    result = @service.store(uploaded_file: uploaded_file)

    assert result[:path].present?
    assert_equal "image/png", result[:media_type]
    assert File.exist?(result[:path])
  end

  test "rejects an uploaded file whose declared content type is unsupported" do
    uploaded_file = mock("uploaded_file")
    uploaded_file.stubs(:read).returns(@valid_png)
    uploaded_file.stubs(:original_filename).returns("test.tiff")
    uploaded_file.stubs(:content_type).returns("image/tiff")

    assert_raises(ImageStorageService::InvalidImageError) do
      @service.store(uploaded_file: uploaded_file)
    end
  end

  test "retrieves image as base64" do
    result = @service.store(data: @valid_png_base64)

    base64, media_type = @service.retrieve_base64(result[:path])

    assert_equal @valid_png_base64, base64
    assert_equal "image/png", media_type
  end

  test "rejects images that are too large" do
    large_data = "x" * (ImageStorageService::MAX_IMAGE_SIZE + 1)
    large_base64 = Base64.strict_encode64(large_data)

    assert_raises(ImageStorageService::InvalidImageError) do
      @service.store(data: large_base64)
    end
  end

  test "rejects invalid base64 data" do
    assert_raises(ImageStorageService::InvalidImageError) do
      @service.store(data: "not valid base64!!!")
    end
  end

  test "rejects unsupported image formats" do
    # Create some random bytes that don't match any image format
    random_bytes = SecureRandom.random_bytes(100)
    random_base64 = Base64.strict_encode64(random_bytes)

    assert_raises(ImageStorageService::InvalidImageError) do
      @service.store(data: random_base64)
    end
  end

  test "raises error when no data provided" do
    assert_raises(ImageStorageService::InvalidImageError) do
      @service.store
    end
  end

  test "raises error when retrieving nonexistent image" do
    assert_raises(ImageStorageService::StorageError) do
      @service.retrieve_base64("/nonexistent/path.png")
    end
  end

  test "detects PNG images" do
    result = @service.store(data: @valid_png_base64)
    assert_equal "image/png", result[:media_type]
  end

  test "detects JPEG images" do
    # JPEG magic bytes: FF D8 FF followed by some data
    jpeg_bytes = [ 0xFF, 0xD8, 0xFF, 0xE0 ].pack("C*") + ("x" * 100)
    jpeg_base64 = Base64.strict_encode64(jpeg_bytes)

    result = @service.store(data: jpeg_base64)
    assert_equal "image/jpeg", result[:media_type]
  end

  test "detects GIF images" do
    # GIF magic bytes: GIF89a
    gif_bytes = "GIF89a" + ("x" * 100)
    gif_base64 = Base64.strict_encode64(gif_bytes)

    result = @service.store(data: gif_base64)
    assert_equal "image/gif", result[:media_type]
  end

  test "detects WebP images" do
    # WebP magic bytes: RIFF....WEBP
    webp_bytes = "RIFF" + [ 100 ].pack("V") + "WEBP" + ("x" * 100)
    webp_base64 = Base64.strict_encode64(webp_bytes)

    result = @service.store(data: webp_base64)
    assert_equal "image/webp", result[:media_type]
  end

  test "copy_from_temp drops an entry whose media type cannot be sniffed" do
    temp_id = "temp_#{SecureRandom.uuid}"
    temp_service = ImageStorageService.new(session_id: temp_id)
    temp_service.store(data: @valid_png_base64)
    # A file in the tree that is not a recognizable image: sniffing fails, so
    # the entry is skipped rather than copied or fatal to the whole batch.
    File.binwrite(File.join(temp_service.session_dir, "junk.png"), SecureRandom.random_bytes(64))

    real_service = conformance_other_service
    copied = ImageStorageService.copy_from_temp(
      temp_session_id: temp_id,
      new_session_id: real_service.session_id.to_i
    )

    assert_equal 1, copied.length
    assert_equal "image/png", copied.first[:media_type]
    assert_equal 1, real_service.list.length
  ensure
    temp_service&.cleanup!
  end

  test "copy_from_temp re-sniffs the media type of every copied entry" do
    temp_id = "temp_#{SecureRandom.uuid}"
    temp_service = ImageStorageService.new(session_id: temp_id)
    temp_service.store(data: Base64.strict_encode64("GIF89a" + ("x" * 100)))

    real_service = conformance_other_service
    copied = ImageStorageService.copy_from_temp(
      temp_session_id: temp_id,
      new_session_id: real_service.session_id.to_i
    )

    assert_equal [ "image/gif" ], copied.map { |c| c[:media_type] }
    assert copied.first[:path].end_with?(".gif")
  ensure
    temp_service&.cleanup!
  end
end

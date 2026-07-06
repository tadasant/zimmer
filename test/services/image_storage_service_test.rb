require "test_helper"

class ImageStorageServiceTest < ActiveSupport::TestCase
  def setup
    # Use a unique session_id per test to avoid conflicts in parallel test runs
    @session_id = rand(100_000_000..999_999_999)
    @service = ImageStorageService.new(session_id: @session_id)

    # Create a valid PNG image (1x1 pixel, red)
    @valid_png = create_minimal_png
    @valid_png_base64 = Base64.strict_encode64(@valid_png)

    # Cleanup any leftover test files
    FileUtils.rm_rf(@service.session_dir)
  end

  def teardown
    FileUtils.rm_rf(@service.session_dir)
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

  test "retrieves image as base64" do
    result = @service.store(data: @valid_png_base64)

    base64, media_type = @service.retrieve_base64(result[:path])

    assert_equal @valid_png_base64, base64
    assert_equal "image/png", media_type
  end

  test "validates image exists" do
    result = @service.store(data: @valid_png_base64)

    assert @service.exists?(result[:path])
    refute @service.exists?("/nonexistent/path.png")
    refute @service.exists?(nil)
  end

  test "validates path is within session directory" do
    refute @service.exists?("/etc/passwd")
    refute @service.exists?("/tmp/other-session/image.png")
  end

  test "prevents path traversal attacks via dot-dot sequences" do
    # Store a real image first
    result = @service.store(data: @valid_png_base64)
    assert @service.exists?(result[:path])

    # These should all fail - attempting to escape the session directory
    refute @service.exists?(@service.session_dir + "/../../../etc/passwd")
    refute @service.exists?(@service.session_dir + "/../../other/file")
    refute @service.exists?("/tmp/agent-orchestrator-images/#{@session_id}/../12346/image.png")
    refute @service.exists?("#{@service.session_dir}/subdir/../../../etc/passwd")
  end

  test "rejects invalid session_id types" do
    assert_raises(ArgumentError) { ImageStorageService.new(session_id: "123") }
    assert_raises(ArgumentError) { ImageStorageService.new(session_id: nil) }
    assert_raises(ArgumentError) { ImageStorageService.new(session_id: -1) }
    assert_raises(ArgumentError) { ImageStorageService.new(session_id: 0) }
    assert_raises(ArgumentError) { ImageStorageService.new(session_id: "../123") }
  end

  test "lists images for session" do
    @service.store(data: @valid_png_base64, filename: "image1.png")
    @service.store(data: @valid_png_base64, filename: "image2.png")

    images = @service.list

    assert_equal 2, images.length
    images.each { |path| assert File.exist?(path) }
  end

  test "cleans up session images" do
    result = @service.store(data: @valid_png_base64)
    assert File.exist?(result[:path])

    @service.cleanup!

    refute File.exist?(result[:path])
    refute File.directory?(@service.session_dir)
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

  test "creates unique paths for each stored image" do
    result1 = @service.store(data: @valid_png_base64)
    result2 = @service.store(data: @valid_png_base64)

    refute_equal result1[:path], result2[:path]
  end
end

# frozen_string_literal: true

# Real attachment bytes, for tests that store one and read it back.
#
# ImageStorageService sniffs an image's media type from its magic bytes and
# refuses anything it cannot recognize, so a test that wants a stored image needs
# a genuinely well-formed one rather than a string of filler. Building it once
# here keeps the several suites that need one (Sessions::StartNow,
# StalledSessionStart, the storage suites) from each carrying their own copy and
# drifting apart.
module AttachmentFixtures
  # A minimal valid 1x1 red PNG.
  def minimal_png
    png = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ].pack("C*")
    ihdr = [ 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0 ].pack("C*")
    png += [ ihdr.length ].pack("N") + "IHDR" + ihdr + [ Zlib.crc32("IHDR" + ihdr) ].pack("N")
    idat = Zlib::Deflate.deflate([ 0, 255, 0, 0 ].pack("C*"))
    png += [ idat.length ].pack("N") + "IDAT" + idat + [ Zlib.crc32("IDAT" + idat) ].pack("N")
    png + [ 0 ].pack("N") + "IEND" + [ Zlib.crc32("IEND") ].pack("N")
  end

  # Store one attachment through the same service the upload paths use — the
  # point of the fix these suites cover is that what is on disk is enough to
  # rebuild a turn. Each service is remembered so a teardown can reap the tree.
  def store_image_for(session, filename: "shot.png")
    remember_storage(ImageStorageService.new(session_id: session.id))
      .store(data: Base64.strict_encode64(minimal_png), filename: filename)
  end

  def store_file_for(session, filename:, content:)
    remember_storage(FileStorageService.new(session_id: session.id))
      .store(data: content, filename: filename)
  end

  # Durable storage survives the test that wrote it, so every suite that stores
  # an attachment has to reap it explicitly.
  def cleanup_stored_attachments!
    @attachment_storages&.each(&:cleanup!)
  end

  private

  def remember_storage(service)
    (@attachment_storages ||= []) << service
    service
  end
end

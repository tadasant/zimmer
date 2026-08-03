# frozen_string_literal: true

require "test_helper"

# Destroying a session row destroys the bytes it owned (#340).
#
# `dependent: :destroy` covers the DB associations; scratch and the two
# prompt-attachment trees are keyed on the session id, so nothing can find them
# again once the row is gone.
class SessionDestroyCleanupTest < ActiveSupport::TestCase
  ENV_KEYS = %w[AGENT_SCRATCH_DIR AGENT_FILES_DIR AGENT_IMAGES_DIR].freeze

  setup do
    @scratch_base = Dir.mktmpdir("destroy-scratch")
    @files_base = Dir.mktmpdir("destroy-files")
    @images_base = Dir.mktmpdir("destroy-images")

    @env_backup = ENV_KEYS.index_with { |key| ENV[key] }
    ENV["AGENT_SCRATCH_DIR"] = @scratch_base
    ENV["AGENT_FILES_DIR"] = @files_base
    ENV["AGENT_IMAGES_DIR"] = @images_base
  end

  teardown do
    @env_backup.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    [ @scratch_base, @files_base, @images_base ].each { |dir| FileUtils.rm_rf(dir) }
  end

  test "destroying a session reclaims its scratch dir and both prompt-attachment dirs" do
    session = sessions(:running)
    scratch, files, images = seed_all_roots(session.id)

    assert Dir.exist?(scratch)
    assert Dir.exist?(files)
    assert Dir.exist?(images)

    session.destroy!

    assert_not Dir.exist?(scratch), "scratch dir should be reclaimed with the row"
    assert_not Dir.exist?(files), "prompt files should be reclaimed with the row"
    assert_not Dir.exist?(images), "prompt images should be reclaimed with the row"
  end

  test "a destroy that rolls back keeps the session's directories" do
    session = sessions(:running)
    scratch, files, images = seed_all_roots(session.id)

    Session.transaction do
      session.destroy!
      raise ActiveRecord::Rollback
    end

    assert Session.exists?(session.id), "the rollback should have kept the row"
    assert Dir.exist?(scratch), "a rolled-back destroy must not take the scratch dir with it"
    assert Dir.exist?(files)
    assert Dir.exist?(images)
  end

  test "destroying one session leaves another session's directories alone" do
    doomed = sessions(:running)
    bystander = sessions(:waiting)
    doomed_scratch, = seed_all_roots(doomed.id)
    bystander_scratch, bystander_files, bystander_images = seed_all_roots(bystander.id)

    doomed.destroy!

    assert_not Dir.exist?(doomed_scratch)
    assert Dir.exist?(bystander_scratch)
    assert Dir.exist?(bystander_files)
    assert Dir.exist?(bystander_images)
  end

  test "a destroy still succeeds when the directories are already gone" do
    session = sessions(:running)

    assert_difference("Session.count", -1) do
      session.destroy!
    end
  end

  private

  def seed_all_roots(session_id)
    scratch = SessionScratchDirectory.ensure_for(session_id)
    File.write(File.join(scratch, "state.txt"), "state")

    file_service = FileStorageService.new(session_id: session_id)
    file_service.store(data: "notes", filename: "notes.md")

    image_service = ImageStorageService.new(session_id: session_id)
    png = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ].pack("C*") + ("x" * 32)
    image_service.store(data: Base64.strict_encode64(png), filename: "shot.png")

    [ scratch, file_service.session_dir, image_service.session_dir ]
  end
end

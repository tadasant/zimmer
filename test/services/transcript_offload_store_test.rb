# frozen_string_literal: true

require "test_helper"

class TranscriptOffloadStoreTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("transcript_offload_store_test")
    @previous_dir = ENV[TranscriptOffloadStore::DIR_ENV]
    ENV[TranscriptOffloadStore::DIR_ENV] = @root
    @content = "{\"type\":\"user\",\"text\":\"héllo\"}\n" * 500
    @digest = Digest::SHA256.hexdigest(@content)
  end

  teardown do
    ENV[TranscriptOffloadStore::DIR_ENV] = @previous_dir
    FileUtils.rm_rf(@root)
  end

  test "resolves beside the clones on the shared volume by default" do
    ENV.delete(TranscriptOffloadStore::DIR_ENV)
    expected = File.join(File.dirname(ClonesDirectory.base), "transcript_offload")

    assert TranscriptOffloadStore.root.start_with?(expected)
  end

  test "writes compressed, sharded by id, and reads back byte for byte" do
    size = TranscriptOffloadStore.write(12_345, @content, digest: @digest)

    path = TranscriptOffloadStore.path_for(12_345)
    assert path.end_with?("/345/12345.jsonl.gz")
    assert_equal File.size(path), size
    assert_operator size, :<, @content.bytesize
    assert_equal @content, TranscriptOffloadStore.read(12_345, digest: @digest)
    assert_equal Encoding::UTF_8, TranscriptOffloadStore.read(12_345, digest: @digest).encoding
  end

  test "refuses to write a copy that does not match the digest, and leaves no file" do
    assert_raises(TranscriptOffloadStore::Corrupt) do
      TranscriptOffloadStore.write(7, @content, digest: Digest::SHA256.hexdigest("something else"))
    end

    assert_not TranscriptOffloadStore.exist?(7)
    assert_empty Dir.glob(File.join(TranscriptOffloadStore.root, "**", "*.tmp-*"))
  end

  test "a failed rewrite keeps the previous verified copy" do
    TranscriptOffloadStore.write(8, @content, digest: @digest)

    assert_raises(TranscriptOffloadStore::Corrupt) { TranscriptOffloadStore.write(8, "other\n", digest: @digest) }
    assert_equal @content, TranscriptOffloadStore.read(8, digest: @digest)
  end

  test "read raises Missing for an absent file and Corrupt for a mismatched or damaged one" do
    assert_raises(TranscriptOffloadStore::Missing) { TranscriptOffloadStore.read(9, digest: @digest) }

    TranscriptOffloadStore.write(9, @content, digest: @digest)
    assert_raises(TranscriptOffloadStore::Corrupt) { TranscriptOffloadStore.read(9, digest: "0" * 64) }

    File.binwrite(TranscriptOffloadStore.path_for(9), "not gzip")
    assert_raises(TranscriptOffloadStore::Corrupt) { TranscriptOffloadStore.read(9, digest: @digest) }
  end
end

# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

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

    assert_equal expected, TranscriptOffloadStore.base
  ensure
    ENV[TranscriptOffloadStore::DIR_ENV] = @root
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
    assert_empty Dir.glob(File.join(TranscriptOffloadStore.base, "**", "*.tmp-*"))
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

  # --- whose files: another database, a copy of this one, the wrong environment ---

  # What this process looks like from a different database: other metadata, same volume.
  def as_another_database
    metadata = ActiveRecord::Base.connection_pool.internal_metadata
    mine = metadata[TranscriptOffloadStore::STORE_ID_KEY]
    metadata[TranscriptOffloadStore::STORE_ID_KEY] = SecureRandom.uuid
    yield
  ensure
    metadata[TranscriptOffloadStore::STORE_ID_KEY] = mine
  end

  # The same metadata reached at another host: what a restored or copied database is.
  def as_a_copy(host: "copy.example")
    config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(host: host)
    ActiveRecord::Base.stubs(:connection_db_config).returns(stub(configuration_hash: config))
    yield
  ensure
    ActiveRecord::Base.unstub(:connection_db_config)
  end

  def as_environment(name)
    metadata = ActiveRecord::Base.connection_pool.internal_metadata
    recorded = metadata[:environment]
    metadata[:environment] = name
    yield
  ensure
    metadata[:environment] = recorded
  end

  test "another database on the same volume cannot read, overwrite, delete or sweep these files" do
    TranscriptOffloadStore.write(1, @content, digest: @digest)
    path = TranscriptOffloadStore.path_for(1)
    temp = "#{path}.tmp-abc123"
    File.write(temp, "x")
    File.utime(2.hours.ago.to_time, 2.hours.ago.to_time, temp)

    as_another_database do
      assert_not TranscriptOffloadStore.exist?(1)
      assert_raises(TranscriptOffloadStore::Missing) { TranscriptOffloadStore.read(1, digest: @digest) }
      TranscriptOffloadStore.delete(1)
      TranscriptOffloadStore.write(1, "other\n", digest: Digest::SHA256.hexdigest("other\n"))
      assert_not_equal path, TranscriptOffloadStore.path_for(1)
      assert_equal 0, TranscriptOffloadStore.sweep_orphaned_temps
      TranscriptOffloadStore.delete(1)
    end

    assert_equal @content, TranscriptOffloadStore.read(1, digest: @digest)
    assert File.exist?(temp)
  end

  test "a copy of this database reads the identical transcript but writes and deletes elsewhere" do
    TranscriptOffloadStore.write(2, @content, digest: @digest)
    other = "other\n"

    as_a_copy do
      assert_equal @content, TranscriptOffloadStore.read(2, digest: @digest)
      TranscriptOffloadStore.delete(2)
      TranscriptOffloadStore.write(2, other, digest: Digest::SHA256.hexdigest(other))
      assert_equal other, TranscriptOffloadStore.read(2, digest: Digest::SHA256.hexdigest(other))
      TranscriptOffloadStore.delete(2)
    end

    assert_equal @content, TranscriptOffloadStore.read(2, digest: @digest)
  end

  test "a stale file at this location does not hide the verified one at another" do
    other = "newer\n"
    TranscriptOffloadStore.write(3, @content, digest: @digest)
    as_a_copy { TranscriptOffloadStore.write(3, other, digest: Digest::SHA256.hexdigest(other)) }

    assert_equal other, TranscriptOffloadStore.read(3, digest: Digest::SHA256.hexdigest(other))
  end

  test "a process in another environment than the database's writes and deletes nothing" do
    TranscriptOffloadStore.write(4, @content, digest: @digest)
    other = "other\n"

    [ "production", nil ].each do |recorded|
      as_environment(recorded) do
        assert_raises(TranscriptOffloadStore::Refused) do
          TranscriptOffloadStore.write(4, other, digest: Digest::SHA256.hexdigest(other))
        end
        assert_raises(TranscriptOffloadStore::Refused) { TranscriptOffloadStore.delete(4) }
        assert_equal @content, TranscriptOffloadStore.read(4, digest: @digest)
      end
    end
  end

  test "the store id is created once, only by a write, and never used as a path unvalidated" do
    metadata = ActiveRecord::Base.connection_pool.internal_metadata
    metadata[TranscriptOffloadStore::STORE_ID_KEY] = nil
    ActiveRecord::Base.connection.execute("DELETE FROM #{metadata.table_name} WHERE key = '#{TranscriptOffloadStore::STORE_ID_KEY}'")

    assert_nil TranscriptOffloadStore.root
    assert_not TranscriptOffloadStore.exist?(5)
    assert_nil TranscriptOffloadStore.delete(5)
    assert_equal 0, TranscriptOffloadStore.sweep_orphaned_temps
    assert_nil metadata[TranscriptOffloadStore::STORE_ID_KEY]

    first = TranscriptOffloadStore.prepare!
    assert_equal first, TranscriptOffloadStore.prepare!

    metadata[TranscriptOffloadStore::STORE_ID_KEY] = "../../clones"
    assert_raises(TranscriptOffloadStore::Refused) { TranscriptOffloadStore.root }
  end
end

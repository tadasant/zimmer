require "test_helper"

# The base class on its own declares a contract and refuses to guess at it. A
# subclass that skips a declaration must fail loudly at the first call rather
# than resolving somewhere plausible — a storage_root that quietly resolves is
# how attachments end up orphaned on the durable volume.
class SessionAttachmentStorageTest < ActiveSupport::TestCase
  test "the class-level declarations are abstract" do
    assert_raises(NotImplementedError) { SessionAttachmentStorage.storage_env_var }
    assert_raises(NotImplementedError) { SessionAttachmentStorage.storage_subdir }
    assert_raises(NotImplementedError) { SessionAttachmentStorage.attachment_noun }
  end

  test "storage_root and base_dir refuse to resolve without a declared env var" do
    assert_raises(NotImplementedError) { SessionAttachmentStorage.storage_root }
    assert_raises(NotImplementedError) { SessionAttachmentStorage.base_dir }
  end

  test "store and copy_entry are abstract" do
    service = SessionAttachmentStorage.new(session_id: 42)

    assert_raises(NotImplementedError) { service.store(data: "x") }
    assert_raises(NotImplementedError) do
      service.copy_entry(content: "x", old_path: "/tmp/x", destination: service)
    end
  end

  test "session_id validation lives in the base class" do
    assert_equal "42", SessionAttachmentStorage.new(session_id: 42).session_id
    assert_raises(ArgumentError) { SessionAttachmentStorage.new(session_id: "42") }
    assert_raises(ArgumentError) { SessionAttachmentStorage.new(session_id: 0) }
  end
end

# frozen_string_literal: true

require "test_helper"

class FileSystemAdapterTest < ActiveSupport::TestCase
  test "base class raises NotImplementedError for all methods" do
    adapter = FileSystemAdapter.new

    assert_raises(NotImplementedError) { adapter.read("/path") }
    assert_raises(NotImplementedError) { adapter.write("/path", "content") }
    assert_raises(NotImplementedError) { adapter.exists?("/path") }
    assert_raises(NotImplementedError) { adapter.directory?("/path") }
    assert_raises(NotImplementedError) { adapter.glob("*.txt") }
    assert_raises(NotImplementedError) { adapter.mtime("/path") }
    assert_raises(NotImplementedError) { adapter.mkdir_p("/path") }
    assert_raises(NotImplementedError) { adapter.rm_rf("/path") }
    assert_raises(NotImplementedError) { adapter.chmod(0o755, "/path") }
  end
end

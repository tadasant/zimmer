# frozen_string_literal: true

require "test_helper"

class NpxPrefixRewriterTest < ActiveSupport::TestCase
  test "inserts --prefix /tmp after -y" do
    entry = { "command" => "npx", "args" => [ "-y", "some-package" ] }
    NpxPrefixRewriter.rewrite!(entry)
    assert_equal [ "-y", "--prefix", "/tmp", "some-package" ], entry["args"]
  end

  test "inserts --prefix /tmp at the front when -y is absent" do
    entry = { "command" => "npx", "args" => [ "some-package" ] }
    NpxPrefixRewriter.rewrite!(entry)
    assert_equal [ "--prefix", "/tmp", "some-package" ], entry["args"]
  end

  test "is idempotent when --prefix is already present" do
    entry = { "command" => "npx", "args" => [ "-y", "--prefix", "/tmp", "some-package" ] }
    NpxPrefixRewriter.rewrite!(entry)
    assert_equal [ "-y", "--prefix", "/tmp", "some-package" ], entry["args"]
  end

  test "is a no-op for non-npx commands" do
    entry = { "command" => "node", "args" => [ "server.js" ] }
    NpxPrefixRewriter.rewrite!(entry)
    assert_equal [ "server.js" ], entry["args"]
  end

  test "is a no-op when args is missing or not an array" do
    entry = { "command" => "npx" }
    assert_nil NpxPrefixRewriter.rewrite!(entry)
    assert_nil entry["args"]

    entry2 = { "command" => "npx", "args" => "not-an-array" }
    NpxPrefixRewriter.rewrite!(entry2)
    assert_equal "not-an-array", entry2["args"]
  end
end

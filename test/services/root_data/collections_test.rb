# frozen_string_literal: true

require "test_helper"

class RootData::CollectionsTest < ActiveSupport::TestCase
  include RootDataHelpers

  test "reads the documented shape" do
    declared = RootData::Collections.declared(root_data_root("r", data_collections: default_root_data_collections))

    assert_equal %w[notes runs], declared.keys
    assert_equal 30, declared["notes"].retention_days
    assert_equal "Notes", declared["notes"].description
    assert_nil declared["runs"].schema
  end

  test "tolerates older and malformed shapes instead of raising" do
    assert_equal %w[a b], RootData::Collections.declared(root_data_root("r", data_collections: [ "a", "b", 3, "Bad Name" ])).keys
    assert_empty RootData::Collections.declared(root_data_root("r", data_collections: "notes"))
    assert_empty RootData::Collections.declared(root_data_root("r"))

    declared = RootData::Collections.declared(root_data_root("r", data_collections: {
      "x" => "not an object", "y" => { "schema" => [], "retention_days" => "soon" }, "z" => { "retention_days" => 999_999 }
    }))
    assert_equal %w[x y z], declared.keys
    assert_nil declared["y"].schema
    assert_nil declared["y"].retention_days
    assert_equal RootData::Limits::MAX_RETENTION_DAYS, declared["z"].retention_days
  end
end

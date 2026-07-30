# frozen_string_literal: true

require "test_helper"

module ParameterStore
  class NamespaceTest < ActiveSupport::TestCase
    test "builds the canonical path for a variable" do
      assert_equal "/zimmer/production/mcp/static/", Namespace.static_namespace("production")
      assert_equal "/zimmer/production/mcp/static/STRAD_API_KEY",
        Namespace.parameter_path("STRAD_API_KEY", "production")
    end

    test "variable_of reads back the trailing name" do
      assert_equal "STRAD_API_KEY", Namespace.variable_of("/zimmer/production/mcp/static/STRAD_API_KEY")
    end

    test "parameter_id folds a path into a legal GCP resource id" do
      assert_equal "zimmer-production-mcp-static-strad-api-key",
        Namespace.parameter_id("/zimmer/production/mcp/static/STRAD_API_KEY")
    end

    test "parameter_id stays within GCP's 63-character limit, hashing the full path" do
      long = Namespace.parameter_path("A_VERY_LONG_VARIABLE_NAME_#{'X' * 80}", "production")
      id = Namespace.parameter_id(long)

      assert_operator id.length, :<=, Namespace::MAX_ID_LENGTH
      assert_match(/\A[a-z][a-z0-9-]*\z/, id)
    end

    test "two long paths sharing a prefix still get different ids" do
      a = Namespace.parameter_id("/zimmer/production/mcp/static/#{'A' * 60}_ONE")
      b = Namespace.parameter_id("/zimmer/production/mcp/static/#{'A' * 60}_TWO")

      assert_not_equal a, b
    end

    test "the fold is lossy, which is why the envelope carries the path" do
      # Documented here so the collision guard in GcpClient is never "simplified"
      # away on the assumption that an id round-trips.
      assert_equal Namespace.parameter_id("/zimmer/production/mcp/static/A_B"),
        Namespace.parameter_id("/zimmer/production/mcp/static/a-b")
    end

    test "validates variable names as environment variable names" do
      assert Namespace.valid_variable_name?("STRAD_API_KEY")
      assert Namespace.valid_variable_name?("_private")
      assert_not Namespace.valid_variable_name?("1STARTS_WITH_DIGIT")
      assert_not Namespace.valid_variable_name?("has-a-dash")
      assert_not Namespace.valid_variable_name?("")
    end

    test "refuses a namespace of / because it would cover the whole project" do
      assert Namespace.valid_namespace?("/zimmer/production/mcp/static/")
      assert_not Namespace.valid_namespace?("/")
      assert_not Namespace.valid_namespace?("zimmer/production")
      assert_not Namespace.valid_namespace?("/Zimmer/Production/"),
        "uppercase names a path no resolver reads while colliding with one it does"
    end
  end
end

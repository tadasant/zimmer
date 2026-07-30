# frozen_string_literal: true

require "test_helper"
require "support/fake_parameter_store"

module ParameterStore
  class GcpClientTest < ActiveSupport::TestCase
    setup do
      @fake = FakeParameterStore.new
      @client = @fake.client
      @namespace = Namespace.static_namespace
    end

    test "resolves a secret parameter by dereferencing its Secret Manager pointer" do
      @fake.seed_secret("STRAD_API_KEY", "sk-live-value")

      assert_equal({ "STRAD_API_KEY" => "sk-live-value" }, @client.resolve(@namespace))
    end

    test "resolves a non-secret parameter straight from its envelope" do
      @fake.seed_plain("MCP_REGION", "us-east1")

      assert_equal({ "MCP_REGION" => "us-east1" }, @client.resolve(@namespace))
    end

    test "the secret value never touches a Parameter Manager payload" do
      @fake.seed_secret("STRAD_API_KEY", "sk-live-value")

      assert_equal "sk-live-value", @client.resolve(@namespace).fetch("STRAD_API_KEY")
      @fake.parameter_payloads.each do |payload|
        assert_no_match(/sk-live-value/, payload,
          "the parameter must hold a __REF__ pointer, never the secret itself")
      end
    end

    test "reads the newest version of a rotated secret" do
      @fake.seed_secret("STRAD_API_KEY", "old")
      @fake.secrets[Namespace.parameter_id(Namespace.parameter_path("STRAD_API_KEY"))] << "new"

      assert_equal "new", @client.resolve(@namespace).fetch("STRAD_API_KEY")
    end

    test "ignores a parameter in the project that Zimmer does not manage" do
      @fake.seed_unmanaged("someone-elses-parameter", {
        "path" => "#{Namespace.static_namespace}NOT_OURS", "secret" => false, "value" => "x"
      })

      assert_empty @client.resolve(@namespace)
    end

    test "ignores a managed parameter whose envelope path is outside the namespace" do
      @fake.seed_plain("OTHER", "x", path: "/zimmer/somewhere-else/mcp/static/OTHER")

      assert_empty @client.resolve(@namespace)
    end

    test "a parameter whose id collides with another path is not returned for it" do
      # `parameter_id` lowercases and folds punctuation, so these two paths share
      # one resource id. The envelope's own path is what tells them apart.
      colliding = "#{Namespace.static_namespace}other_name"
      assert_equal Namespace.parameter_id("#{Namespace.static_namespace}OTHER_NAME"),
        Namespace.parameter_id(colliding)

      @fake.seed_plain("ignored", "value", path: "/zimmer/other/mcp/static/OTHER_NAME")

      assert_empty @client.resolve(@namespace)
    end

    test "raises rather than returning an empty map when the store is unreachable" do
      @fake.seed_secret("STRAD_API_KEY", "sk-live-value")
      @fake.fail_with!(503)

      error = assert_raises(StoreError) { @client.resolve(@namespace) }
      assert_equal 503, error.status
    end

    test "a store error names the resource but never the response body" do
      @fake.fail_with!(403)

      error = assert_raises(StoreError) { @client.resolve(@namespace) }
      assert_match "/parameters", error.message
      assert_no_match(/error/, error.message, "the response body must not be echoed")
    end

    test "held_permissions reports the subset Google says the credential holds" do
      @fake.held_permissions = [ Capabilities::READ_SECRET_VALUE ]

      assert_equal [ Capabilities::READ_SECRET_VALUE ],
        @client.held_permissions(Capabilities::PROBED_PERMISSIONS)
    end
  end
end

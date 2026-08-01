# frozen_string_literal: true

require "test_helper"

module ParameterStore
  # What the resolver credential is REPORTED to be able to do has to match what
  # it can actually do. The expensive lie is the optimistic one: a green
  # least-privilege banner over a credential from which nothing resolves.
  class CapabilitiesTest < ActiveSupport::TestCase
    def capabilities(*held, probed: true)
      Capabilities.new(held: held, probed: probed)
    end

    # Issue #233. GcpClient reads through `parameterVersions.render` and nothing
    # else — it never calls Secret Manager directly — so `versions.access` on its
    # own resolves exactly nothing. ORing the two reported this credential as the
    # intended shape while every ${VAR} came back empty.
    test "access without render cannot read, and is not least privilege" do
      caps = capabilities(Capabilities::READ_SECRET_VALUE)

      assert_not caps.read_secret_values?
      assert_not caps.least_privilege?, "nothing resolves through this credential"
      assert_not caps.writes?
    end

    # Render alone is enough: it dereferences a __REF__ as the parameter's own
    # principal, so the caller can come back with a value it holds no access on.
    test "render alone can read" do
      caps = capabilities(Capabilities::RENDER_PARAMETER)

      assert caps.read_secret_values?
      assert caps.least_privilege?
    end

    test "the intended pair is least privilege" do
      caps = capabilities(Capabilities::READ_SECRET_VALUE, Capabilities::RENDER_PARAMETER)

      assert caps.read_secret_values?
      assert caps.least_privilege?
      assert_empty caps.write_permissions
    end

    test "a credential that can also write is not least privilege" do
      caps = capabilities(Capabilities::READ_SECRET_VALUE, Capabilities::RENDER_PARAMETER,
        Capabilities::WRITE_SECRET_VALUE)

      assert caps.read_secret_values?
      assert caps.writes?
      assert_equal [ Capabilities::WRITE_SECRET_VALUE ], caps.write_permissions
      assert_not caps.least_privilege?
    end

    test "holding nothing reads as broken rather than least privilege" do
      caps = capabilities

      assert_not caps.read_secret_values?
      assert_not caps.least_privilege?
    end

    # "I could not find out" is not "the store denied this" — an unprobed
    # credential claims no capability at all, whatever it might hold.
    test "an unprobed credential claims nothing" do
      caps = Capabilities.unprobed("the API is not enabled")

      assert_not caps.probed?
      assert_not caps.least_privilege?
      assert_empty caps.held
      assert_equal "the API is not enabled", caps.reason
    end

    test "a probe that holds the right permissions but never ran is not least privilege" do
      caps = capabilities(Capabilities::RENDER_PARAMETER, probed: false)

      assert caps.read_secret_values?
      assert_not caps.least_privilege?, "least privilege is a claim only a completed probe can make"
    end
  end
end

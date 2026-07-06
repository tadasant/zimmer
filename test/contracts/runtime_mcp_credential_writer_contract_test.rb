# frozen_string_literal: true

require "test_helper"

# Shared contract test for the RuntimeMcpCredentialWriter interface.
#
# Every runtime MCP credential writer (ClaudeMcpCredentialWriter today;
# CodexMcpCredentialWriter in #3782) must satisfy the same contract so
# McpOauthCredentialInjector can depend on the interface rather than a concrete
# runtime sink.
#
# The suite is parameterized by writer class so a new runtime gets coverage by
# adding one entry to WRITERS.
class RuntimeMcpCredentialWriterContractTest < ActiveSupport::TestCase
  # Writers under contract. Add new runtime writers here.
  WRITERS = [ ClaudeMcpCredentialWriter, CodexMcpCredentialWriter ].freeze

  # Keyword arguments every writer's #write! must accept.
  WRITE_KEYWORDS = %i[working_directory credentials].freeze

  WRITERS.each do |klass|
    test "#{klass} includes the RuntimeMcpCredentialWriter module" do
      assert klass.include?(RuntimeMcpCredentialWriter),
        "#{klass} must include RuntimeMcpCredentialWriter so it is recognizable as a runtime credential writer"
    end

    test "#{klass} instances respond to the full writer contract" do
      writer = klass.new
      assert_respond_to writer, :write!
      assert_respond_to writer, :credential_key_for
    end

    test "#{klass}#write! accepts the required keyword arguments" do
      required = klass.instance_method(:write!).parameters.filter_map { |type, name| name if %i[keyreq key].include?(type) }
      WRITE_KEYWORDS.each do |kw|
        assert_includes required, kw, "#{klass}#write! must accept keyword argument #{kw}"
      end
    end

    test "#{klass}#credential_key_for returns a String" do
      server_config = { type: "streamable-http", url: "https://example.com/mcp", headers: {} }
      assert_kind_of String, klass.new.credential_key_for("example", server_config)
    end
  end
end

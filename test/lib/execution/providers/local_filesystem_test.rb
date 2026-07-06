# frozen_string_literal: true

require "test_helper"

module Execution
  module Providers
    class LocalFilesystemTest < ActiveSupport::TestCase
      test "provider_type returns local_filesystem" do
        session = sessions(:active_session)
        context = Context.new(session: session)
        provider = LocalFilesystem.new(context)

        assert_equal :local_filesystem, provider.provider_type
      end

      test "provider responds to required interface methods" do
        session = sessions(:active_session)
        context = Context.new(session: session)
        provider = LocalFilesystem.new(context)

        # Test interface methods
        assert_respond_to provider, :setup
        assert_respond_to provider, :execute
        assert_respond_to provider, :cleanup
        assert_respond_to provider, :status
        assert_respond_to provider, :provider_type
        assert_respond_to provider, :transcript_directory
      end

      test "status returns expected structure" do
        session = sessions(:active_session)
        context = Context.new(session: session)
        provider = LocalFilesystem.new(context)

        status = provider.status

        assert_kind_of Hash, status
        assert status.key?(:ready)
        assert status.key?(:provider)
        assert_equal :local_filesystem, status[:provider]
      end

      test "transcript_directory returns nil before setup" do
        session = sessions(:active_session)
        context = Context.new(session: session)
        provider = LocalFilesystem.new(context)

        assert_nil provider.transcript_directory
      end

      test "transcript_directory returns path after clone_path is set" do
        session = sessions(:active_session)
        context = Context.new(session: session)
        provider = LocalFilesystem.new(context)

        # Set clone_path directly
        provider.instance_variable_set(:@clone_path, Pathname.new("/tmp/test-clone"))

        transcript_dir = provider.transcript_directory
        assert transcript_dir
        assert_includes transcript_dir, ".claude/projects/"
        assert_includes transcript_dir, "-tmp-test-clone"
      end

      test "provider accepts context with all optional parameters" do
        session = sessions(:active_session)
        context = Context.new(
          session: session,
          working_dir: "/custom/dir",
          branch: "feature-branch",
          options: { timeout: 600, model: "claude-sonnet" }
        )
        provider = LocalFilesystem.new(context)

        assert_equal context, provider.context
        assert_equal "/custom/dir", provider.context.working_dir
        assert_equal "feature-branch", provider.context.branch
        assert_equal 600, provider.context.options[:timeout]
      end

      test "provider inherits from Base" do
        assert LocalFilesystem < Base
      end

      test "provider uses correct logger" do
        session = sessions(:active_session)
        context = Context.new(session: session)
        custom_logger = Logger.new($stdout)

        provider = LocalFilesystem.new(context, logger: custom_logger)

        assert_equal custom_logger, provider.logger
      end
    end
  end
end

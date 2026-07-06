# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Execution
  class SessionExecutorTest < ActiveSupport::TestCase
    setup do
      @session = sessions(:active_session)
      @executor = SessionExecutor.new(@session)
    end

    test "initializes with session and creates context" do
      assert_equal @session, @executor.session
      assert_kind_of Context, @executor.context
      assert_equal @session.id, @executor.context.session.id
    end

    test "initializes with options" do
      options = { working_dir: "/custom/dir", timeout: 300, model: "claude-sonnet" }
      executor = SessionExecutor.new(@session, options: options)

      assert_equal "/custom/dir", executor.context.working_dir
      assert_equal 300, executor.context.options[:timeout]
      assert_equal "claude-sonnet", executor.context.options[:model]
    end

    test "creates correct provider based on context" do
      # Local filesystem provider
      @session.execution_provider = "local_filesystem"
      executor = SessionExecutor.new(@session)
      assert_kind_of Providers::LocalFilesystem, executor.provider

      # Remote sandbox provider
      @session.execution_provider = "remote_sandbox"
      executor = SessionExecutor.new(@session)
      assert_kind_of Providers::RemoteSandbox, executor.provider
    end

    test "raises error for unknown provider type" do
      @session.execution_provider = "unknown_provider"

      assert_raises(SessionExecutor::ProviderNotFoundError) do
        SessionExecutor.new(@session)
      end
    end

    test "execute! runs full lifecycle: setup -> execute -> cleanup" do
      # Configure mock to track method calls
      call_order = []

      mock_provider = Minitest::Mock.new
      mock_provider.expect :setup, Result.success(output: "setup done", provider_type: :local_filesystem), []
      mock_provider.expect :execute, Result.success(output: "execute done", provider_type: :local_filesystem), []
      mock_provider.expect :cleanup, Result.success(output: "cleanup done", provider_type: :local_filesystem), []

      @executor.instance_variable_set(:@provider, mock_provider)

      result = @executor.execute!

      assert result.success?
      assert_equal "execute done", result.output
      mock_provider.verify
    end

    test "execute! updates session status during execution" do
      # Configure mocks for successful execution
      mock_provider = Minitest::Mock.new
      mock_provider.expect :setup, Result.success(provider_type: :local_filesystem), []
      mock_provider.expect :execute, Result.success(provider_type: :local_filesystem), []
      mock_provider.expect :cleanup, Result.success(provider_type: :local_filesystem), []

      @executor.instance_variable_set(:@provider, mock_provider)

      # Session should start in its initial state
      initial_status = @session.status

      @executor.execute!
      @session.reload

      # After successful execution, session should be archived
      assert_equal "archived", @session.status
    end

    test "execute! handles setup failure and does not proceed to execute" do
      mock_provider = Minitest::Mock.new
      mock_provider.expect :setup, Result.failure(error: "Setup failed", provider_type: :local_filesystem), []

      @executor.instance_variable_set(:@provider, mock_provider)

      result = @executor.execute!

      refute result.success?
      assert_equal "Setup failed", result.error
      @session.reload
      assert_equal "failed", @session.status
      mock_provider.verify
    end

    test "execute! runs cleanup even if execute fails" do
      mock_provider = Minitest::Mock.new
      mock_provider.expect :setup, Result.success(provider_type: :local_filesystem), []
      mock_provider.expect :execute, Result.failure(error: "Execute failed", provider_type: :local_filesystem), []
      mock_provider.expect :cleanup, Result.success(provider_type: :local_filesystem), []

      @executor.instance_variable_set(:@provider, mock_provider)

      result = @executor.execute!

      refute result.success?
      assert_equal "Execute failed", result.error
      @session.reload
      assert_equal "failed", @session.status
      mock_provider.verify
    end

    test "execute! handles exceptions and attempts cleanup" do
      mock_provider = Minitest::Mock.new
      def mock_provider.setup
        raise StandardError, "Unexpected error"
      end
      def mock_provider.cleanup
        Result.success(provider_type: :local_filesystem)
      end
      def mock_provider.provider_type
        :local_filesystem
      end

      @executor.instance_variable_set(:@provider, mock_provider)

      result = @executor.execute!

      refute result.success?
      assert_includes result.error, "Unexpected error"
      assert_equal :local_filesystem, result.provider_type
      @session.reload
      assert_equal "failed", @session.status
      mock_provider.verify
    end

    test "execute! handles cleanup failure after exception" do
      mock_provider = Minitest::Mock.new
      def mock_provider.setup
        raise StandardError, "Setup explosion"
      end
      def mock_provider.cleanup
        raise StandardError, "Cleanup explosion"
      end
      def mock_provider.provider_type
        :local_filesystem
      end

      @executor.instance_variable_set(:@provider, mock_provider)

      result = @executor.execute!

      refute result.success?
      assert_includes result.error, "Setup explosion"
      @session.reload
      assert_equal "failed", @session.status
      mock_provider.verify
    end

    test "setup runs provider setup and logs result" do
      mock_provider = Minitest::Mock.new
      mock_provider.expect :setup, Result.success(output: "Setup complete"), []

      @executor.instance_variable_set(:@provider, mock_provider)

      result = @executor.setup

      assert result.success?
      assert_equal "Setup complete", result.output

      # Check that log was created with JSON content
      log = @session.logs.last
      assert_equal "info", log.level
      log_data = JSON.parse(log.content)
      assert_includes log_data["message"], "Setup succeeded"
      assert_equal "setup", log_data["step"]
      assert_equal true, log_data["success"]
      mock_provider.verify
    end

    test "execute_only runs provider execute and logs result" do
      mock_provider = Minitest::Mock.new
      mock_provider.expect :execute, Result.success(output: "Execution complete"), []

      @executor.instance_variable_set(:@provider, mock_provider)

      result = @executor.execute_only

      assert result.success?
      assert_equal "Execution complete", result.output

      # Check that log was created with JSON content
      log = @session.logs.last
      assert_equal "info", log.level
      log_data = JSON.parse(log.content)
      assert_includes log_data["message"], "Execute succeeded"
      mock_provider.verify
    end

    test "cleanup runs provider cleanup and logs result" do
      mock_provider = Minitest::Mock.new
      mock_provider.expect :cleanup, Result.success(output: "Cleanup complete"), []

      @executor.instance_variable_set(:@provider, mock_provider)

      result = @executor.cleanup

      assert result.success?
      assert_equal "Cleanup complete", result.output

      # Check that log was created with JSON content
      log = @session.logs.last
      assert_equal "info", log.level
      log_data = JSON.parse(log.content)
      assert_includes log_data["message"], "Cleanup succeeded"
      mock_provider.verify
    end

    test "logs error level when step fails" do
      mock_provider = Minitest::Mock.new
      mock_provider.expect :setup, Result.failure(error: "Setup error"), []

      @executor.instance_variable_set(:@provider, mock_provider)

      @executor.setup

      log = @session.logs.last
      assert_equal "error", log.level
      log_data = JSON.parse(log.content)
      assert_includes log_data["message"], "Setup failed"
      assert_equal "Setup error", log_data["error"]
    end

    test "status delegates to provider" do
      mock_provider = Minitest::Mock.new
      mock_provider.expect :status, { ready: true, provider: :local_filesystem }, []

      @executor.instance_variable_set(:@provider, mock_provider)

      status = @executor.status

      assert_equal({ ready: true, provider: :local_filesystem }, status)
      mock_provider.verify
    end

    test "info returns execution information" do
      mock_provider = Minitest::Mock.new
      mock_provider.expect :provider_type, :local_filesystem, []
      mock_provider.expect :status, { ready: true }, []

      @executor.instance_variable_set(:@provider, mock_provider)

      info = @executor.info

      assert_equal @session.id, info[:session_id]
      assert_equal :local_filesystem, info[:provider_type]
      assert_kind_of Hash, info[:context]
      assert_equal @session.id, info[:context][:session_id]
      assert_equal({ ready: true }, info[:status])
      mock_provider.verify
    end

    test "creates execution logs with detailed data" do
      mock_provider = Minitest::Mock.new
      mock_provider.expect :setup, Result.success(
        output: "Setup output",
        metadata: { working_dir: "/tmp/clone" },
        provider_type: :local_filesystem
      ), []

      @executor.instance_variable_set(:@provider, mock_provider)

      @executor.setup

      log = @session.logs.last
      log_data = JSON.parse(log.content)
      assert_includes log_data["message"], "[Execution]"
      assert_includes log_data["message"], "Setup succeeded"
    end
  end
end

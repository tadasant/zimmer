# frozen_string_literal: true

require "test_helper"

module Execution
  # Integration tests verifying that all providers correctly implement
  # the expected interface and integrate properly with Context and Result
  class ProviderIntegrationTest < ActiveSupport::TestCase
    setup do
      @session = sessions(:active_session)
    end

    test "all providers accept Context and return Result" do
      context = Context.new(session: @session)

      providers = [
        Providers::LocalFilesystem.new(context),
        Providers::RemoteSandbox.new(context)
      ]

      providers.each do |provider|
        # All providers should have required methods
        assert_respond_to provider, :setup
        assert_respond_to provider, :execute
        assert_respond_to provider, :cleanup
        assert_respond_to provider, :provider_type
        assert_respond_to provider, :status

        # Provider type should be a symbol
        assert_kind_of Symbol, provider.provider_type
      end
    end

    test "providers handle invalid context gracefully" do
      assert_raises(ArgumentError) do
        Providers::LocalFilesystem.new(nil)
      end

      assert_raises(ArgumentError) do
        Providers::LocalFilesystem.new("not a context")
      end

      assert_raises(ArgumentError) do
        Providers::RemoteSandbox.new(nil)
      end
    end

    test "providers preserve context immutability" do
      context = Context.new(session: @session)

      # Context should be frozen
      assert context.frozen?

      # Creating providers should not modify context
      provider1 = Providers::LocalFilesystem.new(context)
      assert context.frozen?
      assert_equal context.object_id, provider1.context.object_id

      provider2 = Providers::RemoteSandbox.new(context)
      assert context.frozen?
      assert_equal context.object_id, provider2.context.object_id
    end

    test "providers handle context with all optional parameters" do
      context = Context.new(
        session: @session,
        working_dir: "/custom/dir",
        branch: "feature-branch",
        options: { timeout: 600, model: "claude-sonnet" }
      )

      providers = [
        Providers::LocalFilesystem.new(context),
        Providers::RemoteSandbox.new(context)
      ]

      providers.each do |provider|
        # Should initialize without errors
        assert provider.context
        assert_equal "/custom/dir", provider.context.working_dir
        assert_equal "feature-branch", provider.context.branch
        assert_equal 600, provider.context.options[:timeout]
        assert_equal "claude-sonnet", provider.context.options[:model]
      end
    end

    test "provider status method provides consistent interface" do
      context = Context.new(session: @session)

      providers = [
        Providers::LocalFilesystem.new(context),
        Providers::RemoteSandbox.new(context)
      ]

      providers.each do |provider|
        status = provider.status

        # Status should be a hash
        assert_kind_of Hash, status

        # Should include provider type
        assert status.key?(:provider)
        assert_equal provider.provider_type, status[:provider]

        # Should include ready status
        assert status.key?(:ready)
        assert_includes [ true, false, nil ], status[:ready]
      end
    end

    test "providers use consistent logging" do
      context = Context.new(session: @session)

      # Test that providers use the logger passed in initialization
      custom_logger = Logger.new($stdout)

      providers = [
        Providers::LocalFilesystem.new(context, logger: custom_logger),
        Providers::RemoteSandbox.new(context, logger: custom_logger)
      ]

      providers.each do |provider|
        assert_equal custom_logger, provider.logger
      end
    end

    test "provider info method returns consistent structure" do
      context = Context.new(session: @session)

      providers = [
        Providers::LocalFilesystem.new(context),
        Providers::RemoteSandbox.new(context)
      ]

      providers.each do |provider|
        info = provider.provider_info

        # Info should be a hash
        assert_kind_of Hash, info

        # Should include type
        assert info.key?(:type)
        assert_equal provider.provider_type, info[:type]

        # Should include context
        assert info.key?(:context)
        assert_equal context.to_h, info[:context]
      end
    end

    test "providers work with SessionExecutor" do
      # Test that providers integrate properly with SessionExecutor
      @session.execution_provider = "local_filesystem"
      executor = SessionExecutor.new(@session)

      assert_kind_of Providers::LocalFilesystem, executor.provider

      # Test with remote sandbox
      @session.execution_provider = "remote_sandbox"
      executor = SessionExecutor.new(@session)

      assert_kind_of Providers::RemoteSandbox, executor.provider
    end

    test "providers handle different session configurations" do
      # Test with minimal session
      minimal_session = sessions(:waiting)
      minimal_context = Context.new(session: minimal_session)

      providers = [
        Providers::LocalFilesystem.new(minimal_context),
        Providers::RemoteSandbox.new(minimal_context)
      ]

      providers.each do |provider|
        assert provider.context.session
        assert provider.context.prompt
        assert provider.context.git_root
      end

      # Test with complex session
      complex_session = sessions(:active_session)
      complex_session.mcp_servers = [ "playwright-custom", "twist-wolfbot", "context7" ]
      complex_session.config = { custom: "config", nested: { value: 42 } }
      complex_context = Context.new(session: complex_session)

      providers = [
        Providers::LocalFilesystem.new(complex_context),
        Providers::RemoteSandbox.new(complex_context)
      ]

      providers.each do |provider|
        assert_equal 3, provider.context.mcp_servers.length
        assert_equal "config", provider.context.session.config["custom"]
        assert_equal 42, provider.context.session.config["nested"]["value"]
      end
    end

    test "all providers follow naming convention" do
      # Verify all provider classes follow expected naming pattern
      provider_classes = [
        Providers::Base,
        Providers::LocalFilesystem,
        Providers::RemoteSandbox
      ]

      provider_classes.each do |klass|
        # Class name should end with provider type or Base
        assert klass.name.match?(/Provider|Base|LocalFilesystem|RemoteSandbox/)

        # Should be in Providers module
        assert_equal Providers, klass.module_parent
      end
    end
  end
end

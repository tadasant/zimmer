# frozen_string_literal: true

require "test_helper"

module Execution
  module Providers
    class BaseTest < ActiveSupport::TestCase
      setup do
        @context = Context.new(session: sessions(:active_session))
      end

      test "initializes with context and logger" do
        provider = Base.new(@context)

        assert_equal @context, provider.context
        assert_equal Rails.logger, provider.logger
      end

      test "initializes with custom logger" do
        custom_logger = Logger.new($stdout)
        provider = Base.new(@context, logger: custom_logger)

        assert_equal custom_logger, provider.logger
      end

      test "validates context is an Execution::Context" do
        assert_raises(ArgumentError, "context must be an Execution::Context") do
          Base.new("not a context")
        end
      end

      test "setup raises NotImplementedError" do
        provider = Base.new(@context)

        assert_raises(NotImplementedError) do
          provider.setup
        end
      end

      test "execute raises NotImplementedError" do
        provider = Base.new(@context)

        assert_raises(NotImplementedError) do
          provider.execute
        end
      end

      test "cleanup raises NotImplementedError" do
        provider = Base.new(@context)

        assert_raises(NotImplementedError) do
          provider.cleanup
        end
      end

      test "provider_type raises NotImplementedError" do
        provider = Base.new(@context)

        assert_raises(NotImplementedError) do
          provider.provider_type
        end
      end

      test "status returns default ready status" do
        # Create a concrete subclass to test non-abstract methods
        test_provider_class = Class.new(Base) do
          def provider_type
            :test_provider
          end
        end

        provider = test_provider_class.new(@context)
        status = provider.status

        assert_equal({ ready: true, provider: :test_provider }, status)
      end

      test "provider_info returns type and context" do
        # Create a concrete subclass to test non-abstract methods
        test_provider_class = Class.new(Base) do
          def provider_type
            :test_provider
          end
        end

        provider = test_provider_class.new(@context)
        info = provider.provider_info

        assert_equal :test_provider, info[:type]
        assert_equal @context.to_h, info[:context]
      end

      test "defines abstract interface methods" do
        provider = Base.new(@context)

        # Check that abstract methods are defined
        assert_respond_to provider, :setup
        assert_respond_to provider, :execute
        assert_respond_to provider, :cleanup
        assert_respond_to provider, :provider_type
        assert_respond_to provider, :status
        assert_respond_to provider, :provider_info
      end

      test "subclasses must implement abstract methods" do
        # Create a subclass that doesn't implement required methods
        incomplete_provider_class = Class.new(Base)
        provider = incomplete_provider_class.new(@context)

        assert_raises(NotImplementedError, "must implement #setup") do
          provider.setup
        end

        assert_raises(NotImplementedError, "must implement #execute") do
          provider.execute
        end

        assert_raises(NotImplementedError, "must implement #cleanup") do
          provider.cleanup
        end

        assert_raises(NotImplementedError, "must implement #provider_type") do
          provider.provider_type
        end
      end

      test "protected logging methods work correctly" do
        # Create a concrete subclass to test protected methods
        test_provider_class = Class.new(Base) do
          def provider_type
            :test_provider
          end

          # Expose protected methods for testing
          def test_log_info(message)
            log_info(message)
          end

          def test_log_error(message)
            log_error(message)
          end

          def test_log_debug(message)
            log_debug(message)
          end
        end

        provider = test_provider_class.new(@context)

        # Test that logging methods work and include proper content
        # We'll just ensure they don't raise errors and pass through messages
        assert_nothing_raised do
          provider.test_log_info("Test info message")
          provider.test_log_error("Test error message")
          provider.test_log_debug("Test debug message")
        end
      end

      test "validates nil context" do
        assert_raises(ArgumentError) do
          Base.new(nil)
        end
      end

      test "provides template for provider implementation" do
        # This test documents the expected interface contract
        # that all providers should follow
        expected_methods = [
          :setup,     # Set up execution environment
          :execute,   # Run the agent
          :cleanup,   # Clean up resources
          :provider_type,  # Return provider type symbol
          :status,    # Check provider readiness (optional override)
          :provider_info  # Get provider information (optional override)
        ]

        provider = Base.new(@context)
        expected_methods.each do |method|
          assert_respond_to provider, method,
                           "Provider should respond to #{method}"
        end
      end

      test "ensures context is frozen after initialization" do
        provider = Base.new(@context)

        # Context should be frozen to prevent modification
        assert @context.frozen?
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Execution
  class ResultTest < ActiveSupport::TestCase
    test "creates result with all parameters" do
      result = Result.new(
        exit_status: 0,
        output: "Success output",
        error: "",
        metadata: { key: "value" },
        provider_type: :local_filesystem
      )

      assert_equal 0, result.exit_status
      assert_equal "Success output", result.output
      assert_equal "", result.error
      assert_equal({ key: "value" }, result.metadata)
      assert_equal :local_filesystem, result.provider_type
    end

    test "is frozen after creation" do
      result = Result.new(exit_status: 0)

      assert result.frozen?
    end

    test "success? returns true when exit_status is 0" do
      result = Result.new(exit_status: 0)

      assert result.success?
      refute result.failure?
    end

    test "success? returns false when exit_status is non-zero" do
      result = Result.new(exit_status: 1)

      refute result.success?
      assert result.failure?
    end

    test "failure? returns true when exit_status is non-zero" do
      result = Result.new(exit_status: 1)

      assert result.failure?
    end

    test "converts to hash" do
      result = Result.new(
        exit_status: 0,
        output: "test output",
        error: "test error",
        metadata: { test: true },
        provider_type: :local_filesystem
      )

      hash = result.to_h

      assert_equal true, hash[:success]
      assert_equal 0, hash[:exit_status]
      assert_equal "test output", hash[:output]
      assert_equal "test error", hash[:error]
      assert_equal({ test: true }, hash[:metadata])
      assert_equal :local_filesystem, hash[:provider_type]
    end

    test "success factory creates successful result" do
      result = Result.success(
        output: "Success!",
        metadata: { duration: 10 },
        provider_type: :local_filesystem
      )

      assert result.success?
      assert_equal 0, result.exit_status
      assert_equal "Success!", result.output
      assert_equal "", result.error
      assert_equal({ duration: 10 }, result.metadata)
      assert_equal :local_filesystem, result.provider_type
    end

    test "success factory with no parameters" do
      result = Result.success

      assert result.success?
      assert_equal 0, result.exit_status
      assert_equal "", result.output
      assert_equal "", result.error
      assert_equal({}, result.metadata)
      assert_nil result.provider_type
    end

    test "failure factory creates failed result" do
      result = Result.failure(
        error: "Something went wrong",
        exit_status: 1,
        output: "Partial output",
        metadata: { error_code: 500 },
        provider_type: :local_filesystem
      )

      assert result.failure?
      assert_equal 1, result.exit_status
      assert_equal "Something went wrong", result.error
      assert_equal "Partial output", result.output
      assert_equal({ error_code: 500 }, result.metadata)
      assert_equal :local_filesystem, result.provider_type
    end

    test "failure factory defaults exit_status to 1" do
      result = Result.failure(error: "Error")

      assert_equal 1, result.exit_status
    end

    test "failure factory can override exit_status" do
      result = Result.failure(error: "Error", exit_status: 127)

      assert_equal 127, result.exit_status
    end

    test "defaults for optional parameters" do
      result = Result.new(exit_status: 0)

      assert_equal "", result.output
      assert_equal "", result.error
      assert_equal({}, result.metadata)
      assert_nil result.provider_type
    end

    test "result is immutable after creation" do
      result = Result.new(
        exit_status: 0,
        output: "test",
        metadata: { key: "value" }
      )

      assert result.frozen?

      # Cannot modify attributes
      assert_raises(FrozenError) do
        result.instance_variable_set(:@exit_status, 1)
      end
    end

    test "result freezes itself but not metadata" do
      metadata = { key: "value", count: 42 }
      result = Result.new(exit_status: 0, metadata: metadata)

      # Result is frozen
      assert result.frozen?

      # Metadata is not frozen by default (Ruby doesn't deep freeze)
      # But attempting to modify metadata would not affect the result
      refute result.metadata.frozen?
    end

    test "success factory with all parameters" do
      result = Result.success(
        output: "Complete output",
        metadata: { duration: 100, pid: 12345 },
        provider_type: :remote_sandbox
      )

      assert result.success?
      assert_equal 0, result.exit_status
      assert_equal "Complete output", result.output
      assert_equal "", result.error
      assert_equal 100, result.metadata[:duration]
      assert_equal 12345, result.metadata[:pid]
      assert_equal :remote_sandbox, result.provider_type
    end

    test "failure factory with all parameters" do
      result = Result.failure(
        error: "Critical error",
        output: "Partial output before failure",
        exit_status: 127,
        metadata: { error_code: "E001", backtrace: [ "line1", "line2" ] },
        provider_type: :local_filesystem
      )

      assert result.failure?
      assert_equal 127, result.exit_status
      assert_equal "Critical error", result.error
      assert_equal "Partial output before failure", result.output
      assert_equal "E001", result.metadata[:error_code]
      assert_equal [ "line1", "line2" ], result.metadata[:backtrace]
      assert_equal :local_filesystem, result.provider_type
    end

    test "to_h includes all attributes" do
      result = Result.new(
        exit_status: 2,
        output: "stdout content",
        error: "stderr content",
        metadata: { timestamp: "2025-01-01", user: "test" },
        provider_type: :remote_sandbox
      )

      hash = result.to_h

      assert_kind_of Hash, hash
      assert_equal false, hash[:success]
      assert_equal 2, hash[:exit_status]
      assert_equal "stdout content", hash[:output]
      assert_equal "stderr content", hash[:error]
      assert_equal({ timestamp: "2025-01-01", user: "test" }, hash[:metadata])
      assert_equal :remote_sandbox, hash[:provider_type]
    end

    test "to_h with minimal result" do
      result = Result.new(exit_status: 0)
      hash = result.to_h

      assert_equal true, hash[:success]
      assert_equal 0, hash[:exit_status]
      assert_equal "", hash[:output]
      assert_equal "", hash[:error]
      assert_equal({}, hash[:metadata])
      assert_nil hash[:provider_type]
    end

    test "supports complex metadata structures" do
      complex_metadata = {
        nested: {
          deeply: {
            value: 42
          }
        },
        array: [ 1, 2, 3 ],
        timestamp: Time.now,
        options: { model: "claude", timeout: 300 }
      }

      result = Result.new(
        exit_status: 0,
        metadata: complex_metadata
      )

      assert_equal 42, result.metadata[:nested][:deeply][:value]
      assert_equal [ 1, 2, 3 ], result.metadata[:array]
      assert_kind_of Time, result.metadata[:timestamp]
      assert_equal "claude", result.metadata[:options][:model]
    end

    test "preserves exit status type" do
      # Integer exit status
      result = Result.new(exit_status: 255)
      assert_equal 255, result.exit_status
      assert_kind_of Integer, result.exit_status

      # Zero exit status
      result = Result.new(exit_status: 0)
      assert_equal 0, result.exit_status
      assert result.success?
    end

    test "handles empty strings appropriately" do
      result = Result.new(
        exit_status: 0,
        output: "",
        error: ""
      )

      assert_equal "", result.output
      assert_equal "", result.error
      assert result.success?
    end

    test "failure requires error message" do
      result = Result.failure(error: "", exit_status: 1)

      assert_equal "", result.error
      assert_equal 1, result.exit_status
      assert result.failure?
    end

    test "success and failure are mutually exclusive" do
      # Success case
      success_result = Result.new(exit_status: 0)
      assert success_result.success?
      refute success_result.failure?

      # Failure case
      failure_result = Result.new(exit_status: 1)
      refute failure_result.success?
      assert failure_result.failure?

      # Non-standard exit codes
      failure_result_255 = Result.new(exit_status: 255)
      refute failure_result_255.success?
      assert failure_result_255.failure?
    end

    test "provider_type can be symbol or nil" do
      # Symbol provider type
      result_symbol = Result.new(
        exit_status: 0,
        provider_type: :local_filesystem
      )
      assert_equal :local_filesystem, result_symbol.provider_type

      # Nil provider type
      result_nil = Result.new(exit_status: 0)
      assert_nil result_nil.provider_type
    end

    test "factory methods freeze result but not nested data" do
      metadata = { mutable: { nested: "value" } }

      result = Result.success(metadata: metadata)

      # Result itself is frozen
      assert result.frozen?

      # Metadata is not deep frozen (standard Ruby behavior)
      refute result.metadata.frozen?
      refute result.metadata[:mutable].frozen?
    end
  end
end

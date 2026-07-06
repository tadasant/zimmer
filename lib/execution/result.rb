# frozen_string_literal: true

module Execution
  # Standardized result object returned by execution providers.
  # Encapsulates success/failure status, output, errors, and metadata.
  class Result
    attr_reader :exit_status, :output, :error, :metadata, :provider_type

    def initialize(exit_status:, output: "", error: "", metadata: {}, provider_type: nil)
      @exit_status = exit_status
      @output = output
      @error = error
      @metadata = metadata
      @provider_type = provider_type
      freeze
    end

    def success?
      exit_status.zero?
    end

    def failure?
      !success?
    end

    def to_h
      {
        success: success?,
        exit_status: exit_status,
        output: output,
        error: error,
        metadata: metadata,
        provider_type: provider_type
      }
    end

    # Factory methods for common result types
    def self.success(output: "", metadata: {}, provider_type: nil)
      new(exit_status: 0, output: output, metadata: metadata, provider_type: provider_type)
    end

    def self.failure(error:, exit_status: 1, output: "", metadata: {}, provider_type: nil)
      new(exit_status: exit_status, output: output, error: error, metadata: metadata, provider_type: provider_type)
    end
  end
end

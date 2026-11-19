# frozen_string_literal: true

# SecurityTelemetry counts in Rails.cache, which is a :null_store in the test
# env and records nothing. Wrap the requests under test in
# `with_security_telemetry` to count them in a real MemoryStore, then read the
# report it returns.
module SecurityTelemetryTestHelpers
  # @return [Hash] SecurityTelemetry.report taken inside the block's store
  def with_security_telemetry
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
    SecurityTelemetry.report
  ensure
    Rails.cache = original
  end
end
